#!/bin/bash
# APT 自動メンテナンス + Discord 通知
#
#   apt-maintenance.sh               更新を実行して結果を通知（apt-maintenance.timer から起動）
#   apt-maintenance.sh boot-notify   起動完了を通知（apt-boot-notify.timer から起動）
#   apt-maintenance.sh do-reboot     安全を確認してから再起動（予約した再起動タイマーから起動）
#   apt-maintenance.sh health        安定性チェックを通知（apt-health.timer から週 1 回起動）
#
# このファイル（リポジトリ直下の apt-maintenance.sh）が唯一の正。install.sh 内の写しはこのファイルと同一に保つこと。
set -Eeuo pipefail

CONF="/etc/apt-discord.conf"
LOG="/var/log/apt-maintenance.log"
DPKG_LOG="/var/log/dpkg.log"
STATE_DIR="/var/lib/apt-maintenance"
REBOOT_MARKER="$STATE_DIR/reboot-scheduled"
PENDING_STATE="$STATE_DIR/pending.list"
LAST_RUN="$STATE_DIR/last-run"
REBOOT_UNIT="apt-delayed-reboot"

COLOR_OK=3066993        # 緑
COLOR_WARN=15844367     # 黄（再起動予約・要確認）
COLOR_FAIL=15158332     # 赤
COLOR_INFO=3447003      # 青

DISK_WARN_PCT=90        # ディスク使用率がこれ以上なら ⚠️
MEM_WARN_PCT=90         # メモリ使用率がこれ以上なら ⚠️
STALE_HOURS=48          # 前回のメンテナンスからこれ以上空いていたら ⚠️
BUSY_WAIT_MIN=120       # バックアップ等の実行中は最大この分数だけ再起動を待つ
LIST_MAX=15             # 通知に並べるパッケージの最大行数（Discord の文字数制限対策）

# shellcheck source=/dev/null
source "$CONF"
[ -z "${WEBHOOK_URL:-}" ] && exit 0
REBOOT_TIME="${REBOOT_TIME:-03:00}"

HOST=$(hostname -s 2>/dev/null || hostname)

log() { echo "$*" >> "$LOG"; }

# ログ末尾を Discord に貼れる長さで返す
log_tail() {
  local s
  s=$(tail -n 15 "$LOG" 2>/dev/null | cut -c1-160 || true)
  if [ "${#s}" -gt 1200 ]; then s="${s: -1200}"; fi
  printf '%s' "$s"
}

# 改行区切りの一覧を最大 LIST_MAX 行にし、溢れた分を「…ほか N 件」にする
clip_list() {
  local all n
  all=$(cat)
  n=$(printf '%s' "$all" | grep -c . || true)
  printf '%s\n' "$all" | head -n "$LIST_MAX"
  if [ "$n" -gt "$LIST_MAX" ]; then echo "…ほか $((n - LIST_MAX)) 件"; fi
}

# 「a, b, c」形式のパッケージ名を、コードブロックで縦に並べる
pkg_block() {
  local body
  body=$(printf '%s\n' "${1:-不明}" | sed 's/, */\n/g' | clip_list)
  printf '```\n%s\n```' "$body"
}

# 改行区切りの一覧を、コードブロックで縦に並べる（後ろに改行を付ける）
list_block() {
  local body
  body=$(printf '%s\n' "$1" | clip_list)
  printf '```\n%s\n```\n' "$body"
}

# 「YYYY-MM-DD HH:MM:SS」→「MM/DD HH:MM」
short_time() { date -d "$1" '+%m/%d %H:%M' 2>/dev/null || echo "$1"; }

# ------------------------------------------------------------
# サーバー情報（どれも失敗したら「?」にして、スクリプトは止めない）
# ------------------------------------------------------------
os_short() {
  local n="?" virt
  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    n=$(. /etc/os-release && echo "${NAME%% *} ${VERSION_ID:-}")
  fi
  if command -v pveversion >/dev/null 2>&1; then
    n="$n / PVE $(pveversion 2>/dev/null | cut -d/ -f2 || echo '?')"
  elif command -v proxmox-backup-manager >/dev/null 2>&1; then
    n="$n / PBS"
  fi
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [ -n "$virt" ] && [ "$virt" != "none" ]; then n="$n (VM: $virt)"; fi
  echo "$n"
}

human_secs() {
  awk -v s="$1" 'BEGIN{s=int(s); d=int(s/86400); h=int(s%86400/3600); m=int(s%3600/60); x=s%60;
    if (d>0) printf "%d日%d時間\n", d, h;
    else if (h>0) printf "%d時間%d分\n", h, m;
    else if (m>0) printf "%d分%d秒\n", m, x;
    else printf "%d秒\n", x }'
}

# DISK_PCT / DISK_TEXT を設定する（値を残すため $(...) ではなく直接呼ぶこと）
DISK_PCT=0
DISK_TEXT="?"
calc_disk() {
  local line
  line=$(df -P / 2>/dev/null | awk 'NR==2{p=$5; sub("%","",p); printf "%d %.1f\n", p, $4/1048576}' || true)
  if [ -z "$line" ]; then return 0; fi
  DISK_PCT=${line%% *}
  if [ "$DISK_PCT" -ge "$DISK_WARN_PCT" ]; then
    DISK_TEXT="⚠️ ${DISK_PCT}%（空き ${line#* }GB）"
  else
    DISK_TEXT="${DISK_PCT}%"
  fi
}

FAILED_UNITS=""
collect_failed_units() {
  FAILED_UNITS=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | grep . || true)
}

next_maintenance() {
  local t now ts
  t="${MAINTENANCE_TIME:-}"
  if [ -z "$t" ]; then
    # 設定に無ければタイマーの定義から読む（OnCalendar=*-*-* 02:30:00）
    t=$(sed -n 's/^OnCalendar=.* \([0-9][0-9]:[0-9][0-9]\).*/\1/p' \
      /etc/systemd/system/apt-maintenance.timer 2>/dev/null | head -n1 || true)
  fi
  if [ -n "$t" ] && ts=$(date -d "today $t" +%s 2>/dev/null); then
    now=$(date +%s)
    if [ "$ts" -le "$now" ]; then ts=$(date -d "tomorrow $t" +%s); fi
    date -d "@$ts" '+%m/%d %H:%M'
  else
    echo "?"
  fi
}

# フッター: 10.75.65.50 ・ Debian 13 / PVE 9.2.24 ・ 7.0.14-26-pve
footer_base() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  echo "${ip:+$ip ・ }$(os_short) ・ $(uname -r)"
}

# ------------------------------------------------------------
# Discord 送信
# ------------------------------------------------------------
# send_discord <タイトル> <色> <本文> [フッター]
# 失敗しても最大 6 回（約 1 分）再送する。通知失敗でスクリプトは止めない。
send_discord() {
  local payload code="000" i
  payload=$(jq -n \
    --arg title "${1:0:250}" --argjson color "$2" --arg desc "${3:0:4000}" \
    --arg footer "${4:-$(footer_base)}" \
    '{embeds:[{title:$title, color:$color, description:$desc,
      footer:{text:$footer}, timestamp:(now|todate)}]}') \
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
  send_discord "❌ ${HOST} ｜ スクリプトエラー" "$COLOR_FAIL" \
"${line} 行目で異常終了しました（終了コード ${code}）。更新や再起動予約が済んでいない可能性があります。
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
  BOOT_AT=$(uptime -s 2>/dev/null || echo "")
  collect_failed_units

  SCHEDULED_AT=""; KERNEL_BEFORE=""; REASON=""
  COLOR=$COLOR_INFO
  if [ -f "$REBOOT_MARKER" ]; then
    # shellcheck source=/dev/null
    source "$REBOOT_MARKER"
    rm -f "$REBOOT_MARKER"
    COLOR=$COLOR_OK
    BOOT_TS=$(date -d "$BOOT_AT" +%s 2>/dev/null || echo 0)
    SCHED_TS=$(date -d "${SCHEDULED_AT:-}" +%s 2>/dev/null || echo 0)
    if [ "$BOOT_TS" -gt 0 ] && [ "$SCHED_TS" -gt 0 ] && [ "$BOOT_TS" -lt "$((SCHED_TS - 120))" ]; then
      TITLE="🟢 ${HOST} ｜ 再起動完了（予約より前に再起動）"
    else
      TITLE="🟢 ${HOST} ｜ 再起動完了"
    fi
    if [ -n "$KERNEL_BEFORE" ] && [ "$KERNEL_BEFORE" != "$KERNEL_NOW" ]; then
      DESC="**カーネル** ${KERNEL_BEFORE} → **${KERNEL_NOW}**"
    else
      DESC="**カーネル** ${KERNEL_NOW}（変化なし）"
    fi
    DESC="${DESC}
**起動** $(short_time "$BOOT_AT")（予約 $(short_time "${SCHEDULED_AT:-?}")）
**再起動の理由**
$(pkg_block "$REASON")"
  else
    TITLE="🔵 ${HOST} ｜ 起動しました（予約外）"
    DESC="**起動** $(short_time "$BOOT_AT")
手動再起動・停電・ホストの再起動など、自動メンテナンス以外による起動です。"
  fi

  if [ -n "$FAILED_UNITS" ]; then
    COLOR=$COLOR_FAIL
    TITLE="⚠️ ${TITLE#* }"
    DESC="${DESC}

⚠️ **失敗しているサービス**（\`systemctl --failed\`）
$(list_block "$FAILED_UNITS")"
  fi

  log "===== $(date '+%F %T %Z') boot-notify ====="
  send_discord "$TITLE" "$COLOR" "$DESC"
  exit 0
fi

# ------------------------------------------------------------
# 安定性チェック（週 1 回）
# ------------------------------------------------------------
if [ "${1:-}" = "health" ]; then
  WARN=0
  LINES=""
  # check <ok|warn|info> <本文>
  check() {
    local mark="✅"
    case "$1" in warn) mark="⚠️"; WARN=$((WARN + 1)) ;; info) mark="ℹ️" ;; esac
    LINES="${LINES}${mark} $2
"
  }

  # 稼働時間
  UP=$(human_secs "$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo 0)")
  check ok "**稼働** ${UP}（起動 $(short_time "$(uptime -s 2>/dev/null || echo '?')")）"

  # ディスク
  calc_disk
  if [ "$DISK_PCT" -ge "$DISK_WARN_PCT" ]; then
    check warn "**ディスク** ${DISK_TEXT#⚠️ }"
  else
    check ok "**ディスク** ${DISK_PCT}%（空き $(df -P / 2>/dev/null | awk 'NR==2{printf "%.1f", $4/1048576}') GB）"
  fi

  # メモリ
  read -r MEM_PCT MEM_USED MEM_TOTAL < <(free -m 2>/dev/null \
    | awk '/^Mem:/{printf "%d %.1f %.1f\n", $3*100/$2, $3/1024, $2/1024}') || true
  if [ "${MEM_PCT:-0}" -ge "$MEM_WARN_PCT" ]; then st=warn; else st=ok; fi
  check "$st" "**メモリ** ${MEM_PCT:-?}%（${MEM_USED:-?} / ${MEM_TOTAL:-?} GB）"

  # 負荷（15 分平均がコア数を超えていたら ⚠️）
  read -r L1 L5 L15 _ < /proc/loadavg || true
  CORES=$(nproc 2>/dev/null || echo 1)
  if awk -v l="${L15:-0}" -v c="$CORES" 'BEGIN{exit !(l > c)}'; then st=warn; else st=ok; fi
  check "$st" "**負荷** ${L1:-?} / ${L5:-?} / ${L15:-?}（${CORES} コア）"

  # 失敗しているサービス
  collect_failed_units
  if [ -n "$FAILED_UNITS" ]; then
    check warn "**失敗しているサービス** $(printf '%s\n' "$FAILED_UNITS" | grep -c .) 件"
  else
    check ok "**失敗しているサービス** なし"
  fi

  # 時刻同期
  NTP=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "?")
  if [ "$NTP" = "yes" ]; then check ok "**時刻同期** OK"; else check warn "**時刻同期** できていません"; fi

  # 再起動待ち
  if [ -f /var/run/reboot-required ]; then
    if systemctl is-active --quiet "${REBOOT_UNIT}.timer"; then
      SCHEDULED_AT=$(sed -n 's/^SCHEDULED_AT="\(.*\)"$/\1/p' "$REBOOT_MARKER" 2>/dev/null || true)
      check info "**再起動待ち** $(short_time "${SCHEDULED_AT:-?}") に予約済み"
    else
      check warn "**再起動待ち** 予約されていません"
    fi
  else
    check ok "**再起動待ち** なし"
  fi

  # 前回のメンテナンス（タイマーが止まっていないかの確認を兼ねる）
  LAST_AT=""; LAST_RESULT=""
  # shellcheck source=/dev/null
  if [ -f "$LAST_RUN" ]; then source "$LAST_RUN"; fi
  if [ -z "$LAST_AT" ]; then
    check warn "**前回のメンテナンス** 記録がありません"
  else
    AGE_H=$(( ($(date +%s) - $(date -d "$LAST_AT" +%s 2>/dev/null || echo 0)) / 3600 ))
    if [ "$LAST_RESULT" != "成功" ]; then
      check warn "**前回のメンテナンス** $(short_time "$LAST_AT") ${LAST_RESULT}"
    elif [ "$AGE_H" -ge "$STALE_HOURS" ]; then
      check warn "**前回のメンテナンス** $(short_time "$LAST_AT")（${AGE_H} 時間動いていません）"
    else
      check ok "**前回のメンテナンス** $(short_time "$LAST_AT") 成功"
    fi
  fi

  # 未適用の更新（前回メンテナンス時点の件数）
  PN=$(grep -c . "$PENDING_STATE" 2>/dev/null || true)
  if [ "${PN:-0}" -gt 0 ]; then
    check info "**未適用の更新** ${PN} 件（手動で \`apt full-upgrade\`）"
  fi

  DESC="$LINES"
  if [ -n "$FAILED_UNITS" ]; then
    DESC="${DESC}
**失敗しているサービス**
$(list_block "$FAILED_UNITS")"
  fi

  if [ "$WARN" -eq 0 ]; then
    TITLE="🩺 ${HOST} ｜ 安定性チェック：問題なし"; COLOR=$COLOR_OK
  else
    TITLE="⚠️ ${HOST} ｜ 安定性チェック：要確認 ${WARN} 件"; COLOR=$COLOR_WARN
  fi

  log "===== $(date '+%F %T %Z') health ====="
  DOMAIN=$(hostname -d 2>/dev/null || true)
  send_discord "$TITLE" "$COLOR" "$DESC" "$(footer_base)${DOMAIN:+ ・ $DOMAIN}"
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

  if [ -n "$BLOCK" ]; then
    # 見送ったら記録を消す。翌日のメンテナンスで reboot-required が残っていれば再予約される
    rm -f "$REBOOT_MARKER"
    log "再起動を見送り: ${BLOCK}"
    send_discord "⛔ ${HOST} ｜ 再起動を見送り" "$COLOR_FAIL" \
"**見送った理由** ${BLOCK}
次回のメンテナンスで再び予約します。急ぐ場合は状況を確認して手動で再起動してください。
**再起動が必要な理由**
$(pkg_block "$REASON")"
    exit 0
  fi

  DESC="数分以内に「再起動完了」が届かなければ、コンソールを確認してください。"
  if [ "$waited" -gt 0 ]; then DESC="${DESC}
**待ち時間** ${waited} 分（実行中の作業の終了待ち）"; fi
  send_discord "🔁 ${HOST} ｜ これから再起動します" "$COLOR_WARN" "${DESC}
**再起動の理由**
$(pkg_block "$REASON")"
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

FAILED=0
FAIL_NOTE=""

# 今回の実行で dpkg.log に追記された分だけを見るため、開始時点のサイズを控える
START_BYTES=$(stat -c %s "$DPKG_LOG" 2>/dev/null || echo 0)

log "--- apt-get update ---"
if ! apt-get -o DPkg::Lock::Timeout=600 update >> "$LOG" 2>&1; then
  FAILED=1
  FAIL_NOTE="パッケージリストの更新 (apt-get update) に失敗しました。"
fi

log "--- unattended-upgrade ---"
if ! unattended-upgrade -v >> "$LOG" 2>&1; then
  FAILED=1
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

# 前回の未適用一覧と比べて、新しく増えた分だけを通知する（毎日同じ一覧を並べない）
PENDING_NEW=""
PENDING_FIRST=0
if [ -f "$PENDING_STATE" ]; then
  PENDING_NEW=$(comm -13 "$PENDING_STATE" <(printf '%s\n' "$PENDING" | grep . || true) || true)
else
  PENDING_FIRST=1
fi
printf '%s\n' "$PENDING" | grep . > "$PENDING_STATE" || : > "$PENDING_STATE"

# ------------------------------------------------------------
# 再起動の予約
# ------------------------------------------------------------
REBOOT_LINE="不要"
REBOOT_AT=""
REASON=""
if [ -f /var/run/reboot-required ]; then
  REASON=$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | paste -sd ',' - | sed 's/,/, /g' || true)
  REASON="${REASON:-不明}"

  if systemctl is-active --quiet "${REBOOT_UNIT}.timer"; then
    SCHEDULED_AT=$(sed -n 's/^SCHEDULED_AT="\(.*\)"$/\1/p' "$REBOOT_MARKER" 2>/dev/null || true)
    REBOOT_AT=$(short_time "${SCHEDULED_AT:-?}")
    REBOOT_LINE="**${REBOOT_AT}** に予約済み"
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
        REBOOT_AT=$(short_time "$SCHEDULED_AT")
        REBOOT_LINE="**${REBOOT_AT}** に予約しました"
      else
        FAILED=1
        REBOOT_LINE="⚠️ **予約に失敗**（手動で再起動してください）"
      fi
    else
      FAILED=1
      REBOOT_LINE="⚠️ **予約できません**（REBOOT_TIME「${REBOOT_TIME}」が不正）"
    fi
  fi
  REBOOT_LINE="${REBOOT_LINE}
$(pkg_block "$REASON")"
fi

# ------------------------------------------------------------
# 通知
# ------------------------------------------------------------
collect_failed_units
calc_disk

# 安定性チェック用に、今回の実行時刻と結果を残す
if [ "$FAILED" -eq 1 ]; then LAST_RESULT="失敗"; else LAST_RESULT="成功"; fi
printf 'LAST_AT="%s"\nLAST_RESULT="%s"\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LAST_RESULT" > "$LAST_RUN"

# --- タイトルと色 ---
if [ "$COUNT" -gt 0 ]; then SUMMARY="${COUNT} 件更新"; else SUMMARY="更新なし"; fi
if [ "$FAILED" -eq 1 ]; then
  TITLE="❌ ${HOST} ｜ メンテナンス失敗"; COLOR=$COLOR_FAIL
elif [ -n "$REBOOT_AT" ]; then
  TITLE="🔁 ${HOST} ｜ ${SUMMARY} ・ ${REBOOT_AT} に再起動"; COLOR=$COLOR_WARN
elif [ -n "$FAILED_UNITS" ] || [ "$DISK_PCT" -ge "$DISK_WARN_PCT" ]; then
  TITLE="⚠️ ${HOST} ｜ ${SUMMARY}（要確認）"; COLOR=$COLOR_WARN
else
  TITLE="✅ ${HOST} ｜ ${SUMMARY}"; COLOR=$COLOR_OK
fi

# --- 本文 ---
# 1 行ずつ足していく（コードブロックの後ろも必ず改行で区切る）
DESC=""
add() { DESC="${DESC}$1
"; }

if [ -n "$FAILED_UNITS" ]; then
  add "⚠️ **失敗しているサービス**（\`systemctl --failed\`）"
  add "$(list_block "$FAILED_UNITS")"
fi
if [ "$DISK_PCT" -ge "$DISK_WARN_PCT" ]; then
  add "⚠️ **ディスクの空きが少なくなっています**（${DISK_TEXT#⚠️ }）"
fi

if [ "$COUNT" -gt 0 ]; then
  CRIT=""
  if [ "$CRITICAL_COUNT" -gt 0 ]; then CRIT="（うち重要 ${CRITICAL_COUNT} 件）"; fi
  add "**適用** ${COUNT} 件${CRIT}"
  add "$(list_block "$UPDATED")"
else
  add "**適用** なし"
fi

add "**再起動** ${REBOOT_LINE}"

if [ "$PENDING_COUNT" -eq 0 ]; then
  add "**未適用** なし"
elif [ "$PENDING_FIRST" -eq 1 ]; then
  add "**未適用** ${PENDING_COUNT} 件（手動で \`apt full-upgrade\`）"
  add "$(list_block "$PENDING")"
elif [ -n "$PENDING_NEW" ]; then
  NEW_N=$(printf '%s' "$PENDING_NEW" | grep -c . || true)
  add "**未適用** ${PENDING_COUNT} 件 ・ 新たに **+${NEW_N}**（手動で \`apt full-upgrade\`）"
  add "$(list_block "$PENDING_NEW")"
else
  add "**未適用** ${PENDING_COUNT} 件（前回から変化なし）"
fi

if [ -n "$FAIL_NOTE" ]; then
  add ""
  add "❌ ${FAIL_NOTE}"
  add "$(list_block "$(log_tail)")"
fi

send_discord "$TITLE" "$COLOR" "$DESC" \
  "$(footer_base) ・ 次回 $(next_maintenance) ・ 所要 $(human_secs "$SECONDS")"
