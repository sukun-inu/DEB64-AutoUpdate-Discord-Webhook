#!/bin/bash
# APT 自動メンテナンス + Discord 通知
#
#   apt-maintenance.sh               更新を実行して結果を通知（apt-maintenance.timer から起動）
#   apt-maintenance.sh boot-notify   起動完了を通知（apt-boot-notify.service から起動）
#
# このファイルが唯一の正。install.sh 内の写しはこのファイルと同一に保つこと。
set -Eeuo pipefail

CONF="/etc/apt-discord.conf"
LOG="/var/log/apt-maintenance.log"
DPKG_LOG="/var/log/dpkg.log"
STATE_DIR="/var/lib/apt-maintenance"
REBOOT_MARKER="$STATE_DIR/reboot-scheduled"
REBOOT_UNIT="apt-delayed-reboot"

COLOR_OK=3066993        # 緑
COLOR_REBOOT=15844367   # 黄
COLOR_FAIL=15158332     # 赤
COLOR_INFO=3447003      # 青

# shellcheck source=/dev/null
source "$CONF"
[ -z "${WEBHOOK_URL:-}" ] && exit 0
REBOOT_TIME="${REBOOT_TIME:-03:00}"

HOST=$(hostname)
CLUSTER=$(hostname -d 2>/dev/null || true)
if [ -z "$CLUSTER" ]; then CLUSTER="-"; fi

log() { echo "$*" >> "$LOG"; }

# ログ末尾を Discord に貼れる長さで返す
log_tail() {
  local s
  s=$(tail -n 20 "$LOG" 2>/dev/null | cut -c1-200 || true)
  if [ "${#s}" -gt 1500 ]; then s="${s: -1500}"; fi
  printf '%s' "$s"
}

# send_discord <タイトル> <色> <本文>
# 失敗しても最大 6 回（約 1 分）再送する。通知失敗でスクリプトは止めない。
send_discord() {
  local payload code="000" i
  payload=$(jq -n \
    --arg title "$1" --argjson color "$2" --arg desc "$3" \
    --arg host "$HOST" --arg cluster "$CLUSTER" \
    '{embeds:[{title:$title, color:$color, description:$desc,
      fields:[{name:"ホスト",   value:$host,    inline:true},
              {name:"クラスタ", value:$cluster, inline:true}],
      timestamp:(now|todate)}]}') || { log "Discord: payload 作成失敗"; return 0; }

  for i in 1 2 3 4 5 6; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
      -H "Content-Type: application/json" -X POST -d "$payload" "$WEBHOOK_URL" || true)
    case "$code" in 2??) break ;; esac
    if [ "$i" -lt 6 ]; then sleep 10; fi
  done
  log "Discord HTTP: $code (試行 $i 回)"
}

on_error() {
  local code=$1 line=$2
  trap - ERR
  log "ERROR: ${line} 行目で異常終了 (exit ${code})"
  send_discord "APT自動メンテナンス: スクリプトエラー" "$COLOR_FAIL" \
"スクリプトが ${line} 行目で異常終了しました（終了コード ${code}）。
更新や再起動予約が完了していない可能性があります。

直近のログ:
\`\`\`
$(log_tail)
\`\`\`"
  exit "$code"
}
trap 'on_error $? $LINENO' ERR

mkdir -p "$STATE_DIR"

# ------------------------------------------------------------
# 起動通知
# ------------------------------------------------------------
if [ "${1:-}" = "boot-notify" ]; then
  KERNEL_NOW=$(uname -r)
  BOOT_AT=$(uptime -s 2>/dev/null || echo "不明")

  if [ -f "$REBOOT_MARKER" ]; then
    SCHEDULED_AT=""; KERNEL_BEFORE=""; REASON=""
    # shellcheck source=/dev/null
    source "$REBOOT_MARKER"
    rm -f "$REBOOT_MARKER"
    if [ -n "$KERNEL_BEFORE" ] && [ "$KERNEL_BEFORE" != "$KERNEL_NOW" ]; then
      KERNEL_LINE="${KERNEL_BEFORE} → **${KERNEL_NOW}**"
    else
      KERNEL_LINE="${KERNEL_NOW}（変化なし）"
    fi
    BOOT_TS=$(date -d "$BOOT_AT" +%s 2>/dev/null || echo 0)
    SCHED_TS=$(date -d "${SCHEDULED_AT:-}" +%s 2>/dev/null || echo 0)
    if [ "$BOOT_TS" -gt 0 ] && [ "$SCHED_TS" -gt 0 ] && [ "$BOOT_TS" -lt "$((SCHED_TS - 120))" ]; then
      TITLE="再起動完了（予約時刻より前に再起動）"
      HEAD="予約時刻より前に再起動されました（手動再起動・停電など）。更新の反映は完了しています。"
    else
      TITLE="再起動完了（予約どおり）"
      HEAD="予約されていた再起動が完了しました。"
    fi
    DESC="${HEAD}

起動時刻: ${BOOT_AT}
予約時刻: ${SCHEDULED_AT:-不明}
カーネル: ${KERNEL_LINE}
再起動の理由: ${REASON:-不明}"
  else
    TITLE="サーバーが起動しました（予約外）"
    DESC="自動メンテナンスが予約したものではない起動です（手動再起動・停電など）。

起動時刻: ${BOOT_AT}
カーネル: ${KERNEL_NOW}"
  fi

  log "===== $(date '+%F %T %Z') boot-notify ====="
  send_discord "$TITLE" "$COLOR_INFO" "$DESC"
  exit 0
fi

# ------------------------------------------------------------
# メンテナンス本体
# ------------------------------------------------------------

# 二重実行防止（手動実行とタイマーが重なった場合など）
exec 9>/run/apt-maintenance.lock
if ! flock -n 9; then
  echo "別の apt-maintenance が実行中のため終了します。" >&2
  exit 0
fi

log "===== $(date '+%F %T %Z') ====="

RESULT="成功"
COLOR=$COLOR_OK
FAIL_NOTE=""

# 今回の実行で dpkg.log に追記された分だけを見るため、開始時点のサイズを控える
START_BYTES=$(stat -c %s "$DPKG_LOG" 2>/dev/null || echo 0)

log "--- apt-get update ---"
if ! apt-get -o DPkg::Lock::Timeout=600 update >> "$LOG" 2>&1; then
  RESULT="失敗"; COLOR=$COLOR_FAIL
  FAIL_NOTE="パッケージリストの更新 (apt-get update) に失敗しました。"
fi

log "--- unattended-upgrade ---"
if ! unattended-upgrade -v >> "$LOG" 2>&1; then
  RESULT="失敗"; COLOR=$COLOR_FAIL
  FAIL_NOTE="${FAIL_NOTE:+$FAIL_NOTE
}unattended-upgrade が失敗しました。"
fi

# 今回追記された dpkg.log の行（途中でローテートされていたら全体を読む）
END_BYTES=$(stat -c %s "$DPKG_LOG" 2>/dev/null || echo 0)
if [ "$END_BYTES" -lt "$START_BYTES" ]; then START_BYTES=0; fi
NEW_DPKG=$(tail -c +"$((START_BYTES + 1))" "$DPKG_LOG" 2>/dev/null || true)

# 「パッケージ名 旧版 → 新版」の一覧。新規インストール（新しいカーネル等）も含める
UPDATED=$(printf '%s\n' "$NEW_DPKG" | awk '
  $3=="upgrade" { split($4,p,":"); print p[1] "  " $5 " → " $6 }
  $3=="install" { split($4,p,":"); print p[1] "  (新規) " $6 }' | sort -u || true)
COUNT=$(printf '%s' "$UPDATED" | grep -c . || true)

CRITICAL_REGEX='^(linux-image|linux-headers|proxmox-kernel|pve-kernel|openssl|libssl|systemd|glibc|libc6|qemu|openssh)'
CRITICAL_COUNT=$(printf '%s' "$UPDATED" | grep -Ec "$CRITICAL_REGEX" || true)

# ------------------------------------------------------------
# 再起動の予約
# ------------------------------------------------------------
REBOOT_LINE="不要"
if [ -f /var/run/reboot-required ]; then
  REASON=$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | paste -sd ',' - | sed 's/,/, /g' || true)
  REASON="${REASON:-不明}"

  if systemctl is-active --quiet "${REBOOT_UNIT}.timer"; then
    SCHEDULED_AT=$(sed -n 's/^SCHEDULED_AT="\(.*\)"$/\1/p' "$REBOOT_MARKER" 2>/dev/null || true)
    REBOOT_LINE="**予約済み ${SCHEDULED_AT:-（時刻不明）}**（前回までに予約）
理由: ${REASON}"
    if [ "$RESULT" = "成功" ]; then COLOR=$COLOR_REBOOT; fi
  else
    # 次に来る REBOOT_TIME（今日まだなら今日、過ぎていれば明日）
    NOW_TS=$(date +%s)
    if WHEN_TS=$(date -d "today ${REBOOT_TIME}" +%s 2>/dev/null); then
      if [ "$WHEN_TS" -le "$((NOW_TS + 60))" ]; then
        WHEN_TS=$(date -d "tomorrow ${REBOOT_TIME}" +%s)
      fi
      SCHEDULED_AT=$(date -d "@${WHEN_TS}" '+%Y-%m-%d %H:%M:%S')

      # 旧バージョンが使っていたユニット名も含めて掃除してから予約する
      for u in "$REBOOT_UNIT" delayed-reboot; do
        systemctl stop "${u}.timer" "${u}.service" >/dev/null 2>&1 || true
        systemctl reset-failed "${u}.timer" "${u}.service" >/dev/null 2>&1 || true
      done

      if systemd-run --quiet --unit="$REBOOT_UNIT" --on-calendar="$SCHEDULED_AT" \
           --timer-property=AccuracySec=1s /bin/systemctl reboot >> "$LOG" 2>&1; then
        cat > "$REBOOT_MARKER" <<EOF
SCHEDULED_AT="${SCHEDULED_AT}"
KERNEL_BEFORE="$(uname -r)"
REASON="${REASON//\"/}"
EOF
        REBOOT_LINE="**${SCHEDULED_AT} に再起動を予約しました**
理由: ${REASON}"
        if [ "$RESULT" = "成功" ]; then COLOR=$COLOR_REBOOT; fi
      else
        RESULT="失敗"; COLOR=$COLOR_FAIL
        REBOOT_LINE="**再起動が必要ですが、予約に失敗しました（手動で再起動してください）**
理由: ${REASON}"
      fi
    else
      RESULT="失敗"; COLOR=$COLOR_FAIL
      REBOOT_LINE="**再起動が必要ですが、REBOOT_TIME「${REBOOT_TIME}」が不正なため予約できません**
理由: ${REASON}"
    fi
  fi
fi

# ------------------------------------------------------------
# 通知
# ------------------------------------------------------------
if [ "$COUNT" -eq 0 ]; then
  PACKAGE_BLOCK="更新はありませんでした。"
else
  LIST=$(printf '%s\n' "$UPDATED" | head -n 40)
  if [ "$COUNT" -gt 40 ]; then
    LIST="${LIST}
…ほか $((COUNT - 40)) 件"
  fi
  LIST="${LIST:0:2500}"
  PACKAGE_BLOCK="\`\`\`
${LIST}
\`\`\`"
fi

TZ_INFO=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "不明")

DESC="実行結果: **${RESULT}**
更新パッケージ: **${COUNT} 件**（うち重要: ${CRITICAL_COUNT} 件）
再起動: ${REBOOT_LINE}
実行中のカーネル: $(uname -r)
タイムゾーン: ${TZ_INFO}

${PACKAGE_BLOCK}"

if [ -n "$FAIL_NOTE" ]; then
  DESC="${DESC}

${FAIL_NOTE}
\`\`\`
$(log_tail)
\`\`\`"
fi

DESC="${DESC}
詳細ログ: ${LOG}"

send_discord "APT自動メンテナンス結果" "$COLOR" "$DESC"
