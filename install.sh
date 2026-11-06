#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

CONF="/etc/apt-discord.conf"
SCRIPT="/usr/local/sbin/apt-maintenance.sh"
SERVICE="/etc/systemd/system/apt-maintenance.service"
TIMER="/etc/systemd/system/apt-maintenance.timer"
BOOT_SERVICE="/etc/systemd/system/apt-boot-notify.service"
AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"

[ "$EUID" -ne 0 ] && die "root 権限が必要です。sudo で実行してください。"

echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  APT Auto-Update + Discord Webhook       ║"
echo "  ║  インストーラー                          ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"

# --- 重複チェック ---
INSTALLED_FILES=()
for f in "$CONF" "$SCRIPT" "$SERVICE" "$TIMER" "$BOOT_SERVICE"; do
  [ -f "$f" ] && INSTALLED_FILES+=("$f")
done

if [ "${#INSTALLED_FILES[@]}" -gt 0 ]; then
  warn "既にインストール済みのファイルが検出されました:"
  for f in "${INSTALLED_FILES[@]}"; do
    echo "    - $f"
  done
  echo ""
  read -rp "  上書きして再インストールしますか？ [y/N]: " answer </dev/tty
  case "$answer" in
    y|Y|yes|YES) info "上書きインストールを続行します..." ;;
    *) info "インストールを中止しました。"; exit 0 ;;
  esac
  echo ""
  if systemctl is-active --quiet apt-maintenance.timer 2>/dev/null; then
    info "既存タイマーを停止します..."
    systemctl stop apt-maintenance.timer
  fi
fi

# --- Step 1/6: 依存パッケージ ---
echo -e "${BOLD}[Step 1/6]${RESET} 依存パッケージをインストールしています..."

# Fix 6: apt-get update を先に実行してパッケージリストを最新化
info "パッケージリストを更新中..."
apt-get update -qq || die "apt-get update に失敗しました。ネットワーク接続を確認してください。"

# Fix 2: stderr は残し、失敗時に die で明示的に終了
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades jq curl \
  >/dev/null || die "パッケージのインストールに失敗しました。"

# 更新の実行は apt-maintenance.timer に一本化する。
# 標準の apt-daily-upgrade.timer にも更新させると、通知の外で更新が済んでしまうため無効にする。
cat > "$AUTO_UPGRADES" << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
EOF
success "依存パッケージのインストール完了"
echo ""

# --- Step 2/6: タイムゾーン・NTP同期 ---
echo -e "${BOLD}[Step 2/6]${RESET} タイムゾーンと時刻同期を確認しています..."

TZ_CURRENT=$(timedatectl show --property=Timezone --value 2>/dev/null \
  || cat /etc/timezone 2>/dev/null \
  || echo "unknown")
NTP_ENABLED=$(timedatectl show --property=NTP --value 2>/dev/null || echo "no")
NTP_SYNCED=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "no")

info "現在のタイムゾーン : $TZ_CURRENT"
info "NTP 有効          : $NTP_ENABLED"
info "NTP 同期済み      : $NTP_SYNCED"
echo ""

if [ "$TZ_CURRENT" != "Asia/Tokyo" ]; then
  warn "タイムゾーンが Asia/Tokyo ではありません（現在: $TZ_CURRENT）"
  warn "UTC のままだとタイマーが JST より 9 時間ずれて動作します。"
  read -rp "  タイムゾーンを Asia/Tokyo に変更しますか？ [Y/n]: " tz_answer </dev/tty
  case "$tz_answer" in
    n|N|no|NO) warn "タイムゾーンを変更しません。タイマー時刻は $TZ_CURRENT 基準になります。" ;;
    *)
      timedatectl set-timezone Asia/Tokyo
      TZ_CURRENT="Asia/Tokyo"
      success "タイムゾーンを Asia/Tokyo に変更しました"
      ;;
  esac
else
  success "タイムゾーンは Asia/Tokyo に設定されています"
fi

# Fix 5: NTP_ENABLED のみで判定（NTP_SYNCED は起動直後に "no" になるため誤検知する）
if [ "$NTP_ENABLED" != "yes" ]; then
  warn "NTP 時刻同期が有効になっていません。有効化します..."

  # Fix 4: command -v で存在確認（is-enabled では検出漏れがある）
  if command -v chronyd &>/dev/null; then
    info "chrony を有効化します..."
    systemctl enable --now chronyd
    success "chrony の NTP 同期を有効化しました"
  elif command -v ntpd &>/dev/null; then
    info "ntp を有効化します..."
    systemctl enable --now ntp
    success "ntp の時刻同期を有効化しました"
  else
    info "systemd-timesyncd を有効化します..."
    timedatectl set-ntp true
    systemctl enable --now systemd-timesyncd 2>/dev/null || true
    success "systemd-timesyncd の NTP 同期を有効化しました"
  fi

  info "NTP 同期を待っています（最大 15 秒）..."
  for i in $(seq 1 15); do
    SYNCED=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "no")
    [ "$SYNCED" = "yes" ] && break
    sleep 1
  done

  if [ "$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo no)" = "yes" ]; then
    success "NTP 同期完了: $(date)"
  else
    warn "NTP 同期がまだ完了していません。しばらく後に timedatectl で確認してください。"
  fi
else
  success "NTP 時刻同期は有効です"
fi

echo ""

# --- Step 3/6: Webhook 設定 ---
echo -e "${BOLD}[Step 3/6]${RESET} Discord Webhook の設定"

WEBHOOK_URL=""
MAINTENANCE_TIME="02:30"
REBOOT_TIME="03:00"

if [ -f "$CONF" ]; then
  WEBHOOK_URL=$(grep -oP '(?<=WEBHOOK_URL=").*(?=")' "$CONF" 2>/dev/null || true)
  MAINTENANCE_TIME=$(grep -oP '(?<=MAINTENANCE_TIME=").*(?=")' "$CONF" 2>/dev/null || echo "02:30")
  REBOOT_TIME=$(grep -oP '(?<=REBOOT_TIME=").*(?=")' "$CONF" 2>/dev/null || echo "03:00")
fi

if [ -n "$WEBHOOK_URL" ]; then
  warn "現在の WEBHOOK_URL: $WEBHOOK_URL"
  read -rp "  新しい URL（空白で現在の値を維持）: " input </dev/tty
  [ -n "$input" ] && WEBHOOK_URL="$input"
else
  while [ -z "$WEBHOOK_URL" ]; do
    read -rp "  Discord Webhook URL: " WEBHOOK_URL </dev/tty
    [ -z "$WEBHOOK_URL" ] && error "Webhook URL は必須です。"
  done
fi

echo ""
info "--- 時刻設定 ---"
info "メンテナンス実行時刻  : APT アップデートを実行する時刻（タイマー）"
info "再起動時刻          : 再起動が必要な更新があったとき、次にこの時刻が来たら再起動"
echo ""
read -rp "  メンテナンス実行時刻      (HH:MM, デフォルト: ${MAINTENANCE_TIME}): " input </dev/tty
MAINTENANCE_TIME="${input:-$MAINTENANCE_TIME}"

read -rp "  再起動時刻                (HH:MM, デフォルト: ${REBOOT_TIME}): " input </dev/tty
REBOOT_TIME="${input:-$REBOOT_TIME}"

success "設定完了"
echo ""

# --- Step 4/6: 設定ファイル ---
echo -e "${BOLD}[Step 4/6]${RESET} 設定ファイルを作成しています..."
cat > "$CONF" <<EOF
WEBHOOK_URL="$WEBHOOK_URL"
MAINTENANCE_TIME="$MAINTENANCE_TIME"
REBOOT_TIME="$REBOOT_TIME"
EOF
chmod 600 "$CONF"
success "$CONF を作成しました"
echo ""

# --- Step 5/6: メンテナンススクリプト ---
echo -e "${BOLD}[Step 5/6]${RESET} メンテナンススクリプトを作成しています..."
cat > "$SCRIPT" << 'SCRIPT_EOF'
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
SCRIPT_EOF

chmod +x "$SCRIPT"
success "$SCRIPT を作成しました"
echo ""

# --- Step 6/6: systemd ---
echo -e "${BOLD}[Step 6/6]${RESET} systemd サービスとタイマーを設定しています..."

cat > "$SERVICE" << 'EOF'
[Unit]
Description=APT Maintenance with Delayed Reboot and Discord
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apt-maintenance.sh
EOF

cat > "$TIMER" <<EOF
[Unit]
Description=Run APT Maintenance Daily

[Timer]
OnCalendar=*-*-* ${MAINTENANCE_TIME}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > "$BOOT_SERVICE" << 'EOF'
[Unit]
Description=Notify Discord that the server has booted
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apt-maintenance.sh boot-notify

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now apt-maintenance.timer
systemctl enable apt-boot-notify.service
success "起動通知を有効化しました（起動のたびに Discord へ通知）"
TZ_SET=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
success "タイマーを有効化しました（毎日 ${MAINTENANCE_TIME} ${TZ_SET} 実行）"

echo ""
info "タイマー確認: systemctl list-timers apt-maintenance.timer"
echo ""

echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║          インストール完了！              ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"
info "設定ファイル : $CONF"
info "スクリプト   : $SCRIPT"
info "ログファイル : /var/log/apt-maintenance.log"
echo ""
read -rp "  今すぐ Discord にテスト通知を送りますか？ [Y/n]: " test_answer </dev/tty
case "$test_answer" in
  n|N|no|NO) ;;
  *)
    if "$SCRIPT" boot-notify; then
      success "テスト通知を送信しました（「サーバーが起動しました」と表示されれば OK）"
    else
      warn "テスト通知に失敗しました。Webhook URL と /var/log/apt-maintenance.log を確認してください。"
    fi
    ;;
esac
echo ""
echo "  動作確認:"
echo "    systemctl start apt-maintenance.service   # 今すぐ 1 回実行"
echo "    systemctl list-timers apt-maintenance.timer"
echo "    tail -f /var/log/apt-maintenance.log"
echo ""
