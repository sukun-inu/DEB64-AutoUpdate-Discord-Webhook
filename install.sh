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

[ "$EUID" -ne 0 ] && die "root 権限が必要です。sudo で実行してください。"

# curl | bash でパイプ実行された場合に read が動くよう stdin を TTY に向け直す
exec 0</dev/tty

echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  APT Auto-Update + Discord Webhook       ║"
echo "  ║  インストーラー                          ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"

# --- 重複チェック ---
INSTALLED_FILES=()
for f in "$CONF" "$SCRIPT" "$SERVICE" "$TIMER"; do
  [ -f "$f" ] && INSTALLED_FILES+=("$f")
done

if [ "${#INSTALLED_FILES[@]}" -gt 0 ]; then
  warn "既にインストール済みのファイルが検出されました:"
  for f in "${INSTALLED_FILES[@]}"; do
    echo "    - $f"
  done
  echo ""
  read -rp "  上書きして再インストールしますか？ [y/N]: " answer
  [[ "$answer" =~ ^[yY] ]] || { info "インストールを中止しました。"; exit 0; }
  echo ""
  if systemctl is-active --quiet apt-maintenance.timer 2>/dev/null; then
    info "既存タイマーを停止します..."
    systemctl stop apt-maintenance.timer
  fi
fi

# --- Step 1: 依存パッケージ ---
echo -e "${BOLD}[Step 1/5]${RESET} 依存パッケージをインストールしています..."
apt-get install -y unattended-upgrades jq curl >/dev/null 2>&1
dpkg-reconfigure -plow unattended-upgrades
success "依存パッケージのインストール完了"
echo ""

# --- Step 2: Webhook 設定 ---
echo -e "${BOLD}[Step 2/5]${RESET} Discord Webhook の設定"

WEBHOOK_URL=""
REBOOT_TIME="03:00"

if [ -f "$CONF" ]; then
  WEBHOOK_URL=$(grep -oP '(?<=WEBHOOK_URL=").*(?=")' "$CONF" 2>/dev/null || true)
  REBOOT_TIME=$(grep -oP '(?<=REBOOT_TIME=").*(?=")' "$CONF" 2>/dev/null || echo "03:00")
fi

if [ -n "$WEBHOOK_URL" ]; then
  warn "現在の WEBHOOK_URL: $WEBHOOK_URL"
  read -rp "  新しい URL（空白で現在の値を維持）: " input
  [ -n "$input" ] && WEBHOOK_URL="$input"
else
  while [ -z "$WEBHOOK_URL" ]; do
    read -rp "  Discord Webhook URL: " WEBHOOK_URL
    [ -z "$WEBHOOK_URL" ] && error "Webhook URL は必須です。"
  done
fi

read -rp "  再起動時刻 (HH:MM, デフォルト: ${REBOOT_TIME}): " input
REBOOT_TIME="${input:-$REBOOT_TIME}"

success "Webhook 設定完了"
echo ""

# --- Step 3: 設定ファイル ---
echo -e "${BOLD}[Step 3/5]${RESET} 設定ファイルを作成しています..."
cat > "$CONF" <<EOF
WEBHOOK_URL="$WEBHOOK_URL"
REBOOT_TIME="$REBOOT_TIME"
EOF
chmod 600 "$CONF"
success "$CONF を作成しました"
echo ""

# --- Step 4: メンテナンススクリプト ---
echo -e "${BOLD}[Step 4/5]${RESET} メンテナンススクリプトを作成しています..."
cat > "$SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

source /etc/apt-discord.conf
[ -z "${WEBHOOK_URL:-}" ] && exit 0

HOST=$(hostname)
CLUSTER=$(hostname -d 2>/dev/null || echo "unknown")
LOG="/var/log/apt-maintenance.log"

RESULT="成功"
COLOR=3066993
KERNEL_UPDATED=0
REBOOT_SCHEDULED=0

echo "===== $(date '+%F %T') =====" >> "$LOG"

if ! unattended-upgrade >> "$LOG" 2>&1; then
  RESULT="失敗"
  COLOR=15158332
fi

TODAY=$(date '+%Y-%m-%d')

UPDATED_PACKAGES=$(grep "$TODAY" /var/log/dpkg.log 2>/dev/null \
  | grep " upgrade " | awk '{print $4}' | sort -u || true)

COUNT=$(echo "$UPDATED_PACKAGES" | grep -c . || true)

SECURITY_COUNT=$(grep "$TODAY" "$LOG" 2>/dev/null \
  | grep -i "security" | grep -c "upgrade" || true)

CRITICAL_REGEX='linux-image|linux-headers|openssl|systemd|glibc|libc6|qemu|pve-kernel'
CRITICAL_COUNT=$(echo "$UPDATED_PACKAGES" | grep -Eic "$CRITICAL_REGEX" || true)

if echo "$UPDATED_PACKAGES" | grep -Eiq '^linux-image|^linux-headers|^pve-kernel'; then
  KERNEL_UPDATED=1
  COLOR=15844367
fi

if [ -f /var/run/reboot-required ] && [ "$KERNEL_UPDATED" -eq 1 ]; then
  NEXT_RUN=$(date -d "tomorrow ${REBOOT_TIME:-03:00}" +"%Y-%m-%d %H:%M:%S")
  systemd-run --on-calendar="$NEXT_RUN" --unit=delayed-reboot.service /sbin/reboot
  REBOOT_SCHEDULED=1
fi

if [ "$COUNT" -eq 0 ]; then
  PACKAGE_LIST="なし"
else
  PACKAGE_LIST=$(echo "$UPDATED_PACKAGES" | head -n 50)
fi
PACKAGE_LIST=$(printf '```\n%s\n```' "$PACKAGE_LIST")

DESCRIPTION="セキュリティ更新数: ${SECURITY_COUNT}
重大パッケージ検知数: ${CRITICAL_COUNT}
カーネル更新: ${KERNEL_UPDATED}
再起動予定: ${REBOOT_SCHEDULED}

更新一覧:
${PACKAGE_LIST}
※詳細ログ: ${LOG}"

PAYLOAD=$(jq -n \
  --arg host    "$HOST" \
  --arg cluster "$CLUSTER" \
  --arg result  "$RESULT" \
  --arg desc    "$DESCRIPTION" \
  --argjson color "$COLOR" \
  '{embeds:[{title:"APT自動メンテナンス結果",color:$color,
    fields:[{name:"ホスト",value:$host,inline:true},
            {name:"クラスタ",value:$cluster,inline:true},
            {name:"実行結果",value:$result,inline:true}],
    description:$desc}]}')

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" -X POST -d "$PAYLOAD" "$WEBHOOK_URL")

echo "Discord HTTP: $HTTP_CODE" >> "$LOG"
SCRIPT_EOF

chmod +x "$SCRIPT"
success "$SCRIPT を作成しました"
echo ""

# --- Step 5: systemd ---
echo -e "${BOLD}[Step 5/5]${RESET} systemd サービスとタイマーを設定しています..."

cat > "$SERVICE" << 'EOF'
[Unit]
Description=APT Maintenance with Delayed Reboot and Discord
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apt-maintenance.sh
EOF

cat > "$TIMER" << 'EOF'
[Unit]
Description=Run APT Maintenance Daily

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now apt-maintenance.timer
success "タイマーを有効化しました（毎日 02:30 実行）"
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
echo "  動作確認:"
echo "    bash -x $SCRIPT"
echo "    systemctl list-timers apt-maintenance.timer"
echo "    tail -f /var/log/apt-maintenance.log"
echo ""
