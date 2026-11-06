#!/bin/bash
# APT 自動メンテナンス + Discord 通知
#
#   apt-maintenance.sh               更新を実行して結果を通知（apt-maintenance.timer から起動）
#   apt-maintenance.sh boot-notify   起動完了を通知（apt-boot-notify.timer から起動）
#   apt-maintenance.sh do-reboot     安全を確認してから再起動（予約した再起動タイマーから起動）
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

DISK_WARN_PCT=90        # ディスク使用率がこれ以上なら ⚠️
BUSY_WAIT_MIN=120       # バックアップ等の実行中は最大この分数だけ再起動を待つ

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

# ------------------------------------------------------------
# サーバー情報の収集（どれも失敗したら「不明」を返し、スクリプトは止めない）
# ------------------------------------------------------------
os_name() {
  local n="不明"
  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    n=$(. /etc/os-release && echo "${PRETTY_NAME:-不明}")
  fi
  if command -v pveversion >/dev/null 2>&1; then
    n="$n
Proxmox VE $(pveversion 2>/dev/null | cut -d/ -f2 || echo '?')"
  elif command -v proxmox-backup-manager >/dev/null 2>&1; then
    n="$n
Proxmox Backup Server"
  fi
  # VM / コンテナなら種別を添える（物理なら何も付けない）
  local virt
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [ -n "$virt" ] && [ "$virt" != "none" ]; then
    n="$n
（仮想: ${virt}）"
  fi
  echo "$n"
}

ip_addr() { hostname -I 2>/dev/null | awk '{print $1}' || true; }

human_secs() {
  awk -v s="$1" 'BEGIN{s=int(s); d=int(s/86400); h=int(s%86400/3600); m=int(s%3600/60); x=s%60;
    if (d>0) printf "%d日 %d時間\n", d, h;
    else if (h>0) printf "%d時間 %d分\n", h, m;
    else if (m>0) printf "%d分 %d秒\n", m, x;
    else printf "%d秒\n", x }'
}

uptime_human() { human_secs "$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)"; }

disk_usage() {
  df -P / 2>/dev/null | awk -v w="$DISK_WARN_PCT" 'NR==2{p=$5; sub("%","",p);
    printf "%s%s%% 使用\n空き %.1f GB\n", (p+0>=w ? "⚠️ " : ""), p, $4/1048576}' || echo "不明"
}

mem_usage() {
  free -m 2>/dev/null | awk '/^Mem:/{printf "%d%% 使用\n%.1f / %.1f GB\n", $3*100/$2, $3/1024, $2/1024}' || echo "不明"
}

load_avg() {
  local l1 l5 l15 rest
  read -r l1 l5 l15 rest < /proc/loadavg || { echo "不明"; return; }
  printf '%s / %s / %s\n(%s コア)\n' "$l1" "$l5" "$l15" "$(nproc 2>/dev/null || echo '?')"
}

FAILED_UNITS=""
collect_failed_units() {
  FAILED_UNITS=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | grep . || true)
}
failed_units_text() {
  local n
  n=$(printf '%s' "$FAILED_UNITS" | grep -c . || true)
  if [ "$n" -eq 0 ]; then
    echo "なし"
  else
    printf '⚠️ %s 件\n%s\n' "$n" "$(printf '%s\n' "$FAILED_UNITS" | head -n 10)"
  fi
}

next_maintenance() {
  local x
  x=$(systemctl show apt-maintenance.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
  if [ -z "$x" ] || [ "$x" = "n/a" ]; then echo "不明"; return; fi
  date -d "${x% *}" '+%m/%d %H:%M' 2>/dev/null || echo "$x"
}

# ------------------------------------------------------------
# Discord 送信
# ------------------------------------------------------------
FIELDS='[]'
# add_field <名前> <値> [inline: true|false]
add_field() {
  local v="$2"
  if [ -z "$v" ]; then v="-"; fi
  FIELDS=$(jq -c --arg n "$1" --arg v "${v:0:1000}" --argjson i "${3:-true}" \
    '. + [{name:$n, value:$v, inline:$i}]' <<<"$FIELDS" 2>/dev/null || echo "$FIELDS")
}

add_host_fields() {
  local ip
  ip=$(ip_addr)
  add_field "ホスト" "${HOST}${ip:+
${ip}}"
  add_field "クラスタ" "$CLUSTER"
  add_field "OS" "$(os_name)"
}

# send_discord <タイトル> <色> <本文>   （欄は FIELDS に積んでおく）
# 失敗しても最大 6 回（約 1 分）再送する。通知失敗でスクリプトは止めない。
send_discord() {
  local payload code="000" i
  payload=$(jq -n \
    --arg title "$1" --argjson color "$2" --arg desc "${3:0:4000}" \
    --argjson fields "$FIELDS" \
    '{embeds:[{title:$title, color:$color, description:$desc,
      fields:$fields, timestamp:(now|todate)}]}') \
    || { log "Discord: payload 作成失敗"; return 0; }

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
  FIELDS='[]'
  add_host_fields
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
  collect_failed_units

  SCHEDULED_AT=""; KERNEL_BEFORE=""; REASON=""
  if [ -f "$REBOOT_MARKER" ]; then
    # shellcheck source=/dev/null
    source "$REBOOT_MARKER"
    rm -f "$REBOOT_MARKER"
    if [ -n "$KERNEL_BEFORE" ] && [ "$KERNEL_BEFORE" != "$KERNEL_NOW" ]; then
      KERNEL_LINE="${KERNEL_BEFORE}
→ **${KERNEL_NOW}**"
    else
      KERNEL_LINE="${KERNEL_NOW}
（変化なし）"
    fi
    BOOT_TS=$(date -d "$BOOT_AT" +%s 2>/dev/null || echo 0)
    SCHED_TS=$(date -d "${SCHEDULED_AT:-}" +%s 2>/dev/null || echo 0)
    if [ "$BOOT_TS" -gt 0 ] && [ "$SCHED_TS" -gt 0 ] && [ "$BOOT_TS" -lt "$((SCHED_TS - 120))" ]; then
      TITLE="再起動完了（予約時刻より前に再起動）"
      DESC="予約時刻より前に再起動されました（手動再起動・停電など）。更新の反映は完了しています。"
    else
      TITLE="再起動完了（予約どおり）"
      DESC="予約されていた再起動が完了しました。"
    fi
    DESC="${DESC}
再起動の理由: ${REASON:-不明}"
  else
    KERNEL_LINE="$KERNEL_NOW"
    TITLE="サーバーが起動しました（予約外）"
    DESC="自動メンテナンスが予約したものではない起動です（手動再起動・停電・VM ならホストの再起動など）。"
  fi

  COLOR=$COLOR_INFO
  if [ -n "$FAILED_UNITS" ]; then
    COLOR=$COLOR_FAIL
    DESC="${DESC}

⚠️ **起動に失敗したサービスがあります。** \`systemctl --failed\` で確認してください。"
  fi

  add_host_fields
  add_field "起動時刻" "$BOOT_AT"
  add_field "カーネル" "$KERNEL_LINE"
  add_field "予約時刻" "${SCHEDULED_AT:-なし}"
  add_field "ディスク (/)" "$(disk_usage)"
  add_field "メモリ" "$(mem_usage)"
  add_field "負荷 (1/5/15分)" "$(load_avg)"
  add_field "失敗中のサービス" "$(failed_units_text)" false

  log "===== $(date '+%F %T %Z') boot-notify ====="
  send_discord "$TITLE" "$COLOR" "$DESC"
  exit 0
fi

# ------------------------------------------------------------
# 予約した再起動の実行（安全確認つき）
# ------------------------------------------------------------

# 再起動してはいけない作業が動いていれば、その内容を返す（空なら暇）
busy_reason() {
  local n
  # PVE: バックアップ (vzdump) 実行中
  if pgrep -x vzdump >/dev/null 2>&1; then
    echo "バックアップ (vzdump) 実行中"; return
  fi
  # PBS: 実行中のタスク（バックアップ受信・GC・verify・sync など）
  if command -v proxmox-backup-manager >/dev/null 2>&1; then
    n=$(proxmox-backup-manager task list --output-format json 2>/dev/null \
      | jq '[.[] | select(.endtime == null)] | length' 2>/dev/null || echo 0)
    if [ "${n:-0}" -gt 0 ]; then
      echo "PBS のタスク ${n} 件が実行中"; return
    fi
  fi
}

# PVE クラスタで再起動してよいか。問題があれば理由を返す（空なら OK）
cluster_block_reason() {
  command -v pvesh >/dev/null 2>&1 || return 0
  local st total online quorate
  st=$(pvesh get /cluster/status --output-format json 2>/dev/null) \
    || { echo "クラスタ状態を取得できません"; return; }
  total=$(jq '[.[] | select(.type=="node")] | length' <<<"$st")
  online=$(jq '[.[] | select(.type=="node" and .online==1)] | length' <<<"$st")
  quorate=$(jq -r '[.[] | select(.type=="cluster")][0].quorate // "standalone"' <<<"$st")
  if [ "$quorate" != "standalone" ] && [ "$quorate" != "1" ]; then
    echo "クラスタが quorate ではありません"; return
  fi
  if [ "$online" -lt "$total" ]; then
    echo "停止中のノードがあります（オンライン ${online}/${total}）"; return
  fi
}

if [ "${1:-}" = "do-reboot" ]; then
  log "===== $(date '+%F %T %Z') do-reboot ====="
  REASON=""
  if [ -f "$REBOOT_MARKER" ]; then
    REASON=$(sed -n 's/^REASON="\(.*\)"$/\1/p' "$REBOOT_MARKER" 2>/dev/null || true)
  fi

  # メンテナンス本体が動いている間は待つ（最大 30 分）
  exec 9>/run/apt-maintenance.lock
  flock -w 1800 9 || true

  BLOCK=""
  waited=0
  while :; do
    BLOCK=$(busy_reason)
    if [ -z "$BLOCK" ] || [ "$waited" -ge "$BUSY_WAIT_MIN" ]; then break; fi
    log "再起動待ち: ${BLOCK}（${waited} 分経過）"
    sleep 300
    waited=$((waited + 5))
  done
  if [ -z "$BLOCK" ]; then BLOCK=$(cluster_block_reason); fi

  add_host_fields
  if [ -n "$BLOCK" ]; then
    # 見送ったら記録を消す。翌日のメンテナンスで reboot-required が残っていれば再予約される
    rm -f "$REBOOT_MARKER"
    log "再起動を見送り: ${BLOCK}"
    add_field "見送った理由" "$BLOCK" false
    add_field "再起動が必要な理由" "${REASON:-不明}" false
    send_discord "再起動を見送りました" "$COLOR_FAIL" \
"安全に再起動できない状態だったため、予約していた再起動を中止しました。
次回のメンテナンスで再び予約します。急ぐ場合は状況を確認して手動で再起動してください。"
    exit 0
  fi

  add_field "再起動の理由" "${REASON:-不明}" false
  if [ "$waited" -gt 0 ]; then add_field "待ち時間" "${waited} 分（実行中の作業の終了待ち）" false; fi
  send_discord "これから再起動します" "$COLOR_REBOOT" \
"予約していた再起動を開始します。数分以内に「再起動完了」が届かなければ、コンソールを確認してください。"
  log "reboot 実行"
  systemctl reboot
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

# 自動更新の対象外で残っている更新（PVE のリポジトリや通常の更新など。手動で full-upgrade が必要）
PENDING=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | awk '/^Inst /{print $2}' | sort -u || true)
PENDING_COUNT=$(printf '%s' "$PENDING" | grep -c . || true)

# ------------------------------------------------------------
# 再起動の予約
# ------------------------------------------------------------
REBOOT_SHORT="不要"
REASON=""
if [ -f /var/run/reboot-required ]; then
  REASON=$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | paste -sd ',' - | sed 's/,/, /g' || true)
  REASON="${REASON:-不明}"

  if systemctl is-active --quiet "${REBOOT_UNIT}.timer"; then
    SCHEDULED_AT=$(sed -n 's/^SCHEDULED_AT="\(.*\)"$/\1/p' "$REBOOT_MARKER" 2>/dev/null || true)
    REBOOT_SHORT="予約済み
${SCHEDULED_AT:-（時刻不明）}"
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
           --timer-property=AccuracySec=1s "$(readlink -f "$0")" do-reboot >> "$LOG" 2>&1; then
        cat > "$REBOOT_MARKER" <<EOF
SCHEDULED_AT="${SCHEDULED_AT}"
KERNEL_BEFORE="$(uname -r)"
REASON="${REASON//\"/}"
EOF
        REBOOT_SHORT="**予約しました**
${SCHEDULED_AT}"
        if [ "$RESULT" = "成功" ]; then COLOR=$COLOR_REBOOT; fi
      else
        RESULT="失敗"; COLOR=$COLOR_FAIL
        REBOOT_SHORT="⚠️ **予約失敗**
手動で再起動してください"
      fi
    else
      RESULT="失敗"; COLOR=$COLOR_FAIL
      REBOOT_SHORT="⚠️ **予約不可**
REBOOT_TIME「${REBOOT_TIME}」が不正"
    fi
  fi
fi

# ------------------------------------------------------------
# 通知
# ------------------------------------------------------------
collect_failed_units

WARNINGS=""
DISK_TEXT=$(disk_usage)
case "$DISK_TEXT" in ⚠️*) WARNINGS="${WARNINGS}⚠️ ディスクの空きが少なくなっています。
" ;; esac
if [ -n "$FAILED_UNITS" ]; then
  WARNINGS="${WARNINGS}⚠️ 失敗しているサービスがあります（\`systemctl --failed\`）。
"
fi
if [ "$PENDING_COUNT" -gt 0 ]; then
  WARNINGS="${WARNINGS}ℹ️ 自動更新の対象外の更新が ${PENDING_COUNT} 件あります（手動で \`apt full-upgrade\`）。
"
fi

DESC=""
if [ -n "$WARNINGS" ]; then DESC="${WARNINGS}
"; fi

if [ "$COUNT" -eq 0 ]; then
  DESC="${DESC}今回適用した更新はありません。"
else
  LIST=$(printf '%s\n' "$UPDATED" | head -n 40)
  if [ "$COUNT" -gt 40 ]; then
    LIST="${LIST}
…ほか $((COUNT - 40)) 件"
  fi
  DESC="${DESC}**適用した更新**
\`\`\`
${LIST:0:2000}
\`\`\`"
fi

if [ -n "$REASON" ]; then
  DESC="${DESC}
**再起動が必要な理由**: ${REASON}"
fi

if [ "$PENDING_COUNT" -gt 0 ]; then
  PLIST=$(printf '%s\n' "$PENDING" | head -n 15 | paste -sd ' ' -)
  if [ "$PENDING_COUNT" -gt 15 ]; then PLIST="${PLIST} …ほか $((PENDING_COUNT - 15)) 件"; fi
  DESC="${DESC}
**未適用の更新**: ${PLIST:0:600}"
fi

if [ -n "$FAIL_NOTE" ]; then
  DESC="${DESC}

${FAIL_NOTE}
\`\`\`
$(log_tail)
\`\`\`"
fi

DESC="${DESC}
詳細ログ: ${LOG}"

add_host_fields
add_field "実行結果" "**${RESULT}**"
add_field "適用した更新" "${COUNT} 件
（重要: ${CRITICAL_COUNT} 件）"
add_field "未適用の更新" "${PENDING_COUNT} 件"
add_field "再起動" "$REBOOT_SHORT"
add_field "カーネル (実行中)" "$(uname -r)"
add_field "稼働時間" "$(uptime_human)"
add_field "ディスク (/)" "$DISK_TEXT"
add_field "メモリ" "$(mem_usage)"
add_field "負荷 (1/5/15分)" "$(load_avg)"
add_field "失敗中のサービス" "$(failed_units_text)"
add_field "次回実行" "$(next_maintenance)"
add_field "所要時間" "$(human_secs "$SECONDS")"

send_discord "APT自動メンテナンス結果" "$COLOR" "$DESC"
