#!/bin/bash
set -euo pipefail

# ================================================
# APT Maintenance + Discord Webhook インストーラー
# ================================================

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

CONF="/etc/apt-discord.conf"
SCRIPT="/usr/local/sbin/apt-maintenance.sh"
SERVICE="/etc/systemd/system/apt-maintenance.service"
TIMER="/etc/systemd/system/apt-maintenance.timer"

# --- root チェック ---
if [ "$EUID" -ne 0 ]; then
  error "root 権限が必要です。sudo bash install.sh で実行してください。"
  exit 1
fi

echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  APT Auto-Update + Discord Webhook       ║"
echo "  ║  インストーラー                          ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"

# --- 重複チェック ---
ALREADY_INSTALLED=0
INSTALLED_FILES=()
[ -f "$CONF" ]    && { ALREADY_INSTALLED=1; INSTALLED_FILES+=("$CONF"); }
[ -f "$SCRIPT" ]  && { ALREADY_INSTALLED=1; INSTALLED_FILES+=("$SCRIPT"); }
[ -f "$SERVICE" ] && { ALREADY_INSTALLED=1; INSTALLED_FILES+=("$SERVICE"); }
[ -f "$TIMER" ]   && { ALREADY_INSTALLED=1; INSTALLED_FILES+=("$TIMER"); }

if [ "$ALREADY_INSTALLED" -eq 1 ]; then
  warn "既にインストール済みのファイルが検出されました:"
  for f in "${INSTALLED_FILES[@]}"; do
    echo "    - $f"
  done
  echo ""
  read -rp "  上書きして再インストールしますか？ [y/N]: " OVERWRITE
  case "$OVERWRITE" in
    y|Y|yes|YES) info "上書きインストールを続行します..." ;;
    *) info "インストールを中止しました。"; exit 0 ;;
  esac
  echo ""

  # 実行中のタイマーを一時停止
  if systemctl is-active --quiet apt-maintenance.timer 2>/dev/null; then
    info "既存タイマーを停止します..."
    systemctl stop apt-maintenance.timer
  fi
fi

# --- 依存パッケージのインストール ---
echo -e "${BOLD}[Step 1/5]${RESET} 依存パッケージをインストールしています..."
apt-get install -y unattended-upgrades jq curl > /dev/null 2>&1
dpkg-reconfigure -plow unattended-upgrades
success "依存パッケージのインストール完了"
echo ""

# --- Webhook URL の入力 ---
echo -e "${BOLD}[Step 2/5]${RESET} Discord Webhook の設定"
if [ -f "$CONF" ]; then
  CURRENT_WEBHOOK=$(grep '^WEBHOOK_URL=' "$CONF" 2>/dev/null | cut -d'"' -f2 || true)
  if [ -n "$CURRENT_WEBHOOK" ]; then
    warn "現在の WEBHOOK_URL: ${CURRENT_WEBHOOK}"
    read -rp "  新しい URL を入力（空白のままで現在の値を維持）: " INPUT_URL
    WEBHOOK_URL="${INPUT_URL:-$CURRENT_WEBHOOK}"
  fi
fi

if [ -z "${WEBHOOK_URL:-}" ]; then
  while true; do
    read -rp "  Discord Webhook URL を入力してください: " WEBHOOK_URL
    if [ -n "$WEBHOOK_URL" ]; then
      break
    fi
    error "Webhook URL は必須です。"
  done
fi

CURRENT_REBOOT="03:00"
if [ -f "$CONF" ]; then
  SAVED_REBOOT=$(grep '^REBOOT_TIME=' "$CONF" 2>/dev/null | cut -d'"' -f2 || true)
  [ -n "$SAVED_REBOOT" ] && CURRENT_REBOOT="$SAVED_REBOOT"
fi
read -rp "  自動再起動時刻 (HH:MM, デフォルト: ${CURRENT_REBOOT}): " INPUT_REBOOT
REBOOT_TIME="${INPUT_REBOOT:-$CURRENT_REBOOT}"
success "Webhook 設定完了"
echo ""

# --- 設定ファイルの作成 ---
echo -e "${BOLD}[Step 3/5]${RESET} 設定ファイルを作成しています..."
cat > "$CONF" << EOF
WEBHOOK_URL="$WEBHOOK_URL"
REBOOT_TIME="$REBOOT_TIME"
EOF
chmod 600 "$CONF"
success "$CONF を作成しました"
echo ""

# --- メンテナンススクリプトの作成 ---
echo -e "${BOLD}[Step 4/5]${RESET} メンテナンススクリプトを作成しています..."
cat > "$SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

# --- 設定読み込み ---
source /etc/apt-discord.conf
[ -z "${WEBHOOK_URL:-}" ] && exit 0

HOST=$(hostname)
CLUSTER=$(hostname -d 2>/dev/null || echo "unknown")
LOG="/var/log/apt-maintenance.log"

# --- 初期値 ---
RESULT="成功"
COLOR=3066993      # 緑
KERNEL_UPDATED=0
REBOOT_SCHEDULED=0
SECURITY_COUNT=0
CRITICAL_COUNT=0

echo "===== $(date '+%F %T') =====" >> "$LOG"

# --- unattended-upgrades 実行 ---
if ! unattended-upgrade >> "$LOG" 2>&1; then
  RESULT="失敗"
  COLOR=15158332   # 赤
fi

TODAY=$(date '+%Y-%m-%d')

# --- 本日更新されたパッケージ一覧を取得 ---
UPDATED_PACKAGES=$(grep "$TODAY" /var/log/dpkg.log 2>/dev/null \
  | grep " upgrade " \
  | awk '{print $4}' \
  | sort -u || true)

COUNT=$(echo "$UPDATED_PACKAGES" | grep -c . || true)

# --- セキュリティ更新数（unattended-upgrades ログ基準） ---
SECURITY_COUNT=$(grep "$TODAY" "$LOG" 2>/dev/null \
  | grep -i "security" \
  | grep -c "upgrade" || true)

# --- 重大パッケージ定義 ---
CRITICAL_REGEX='linux-image|linux-headers|openssl|systemd|glibc|libc6|qemu|pve-kernel'

CRITICAL_COUNT=$(echo "$UPDATED_PACKAGES" \
  | grep -Eic "$CRITICAL_REGEX" || true)

# --- カーネル更新の検知 ---
if echo "$UPDATED_PACKAGES" | grep -Eiq '^linux-image|^linux-headers|^pve-kernel'; then
  KERNEL_UPDATED=1
  COLOR=15844367   # 黄
fi

# --- カーネル更新時は翌朝 REBOOT_TIME に再起動を予約 ---
if [ -f /var/run/reboot-required ] && [ "$KERNEL_UPDATED" -eq 1 ]; then
  NEXT_RUN=$(date -d "tomorrow ${REBOOT_TIME:-03:00}" +"%Y-%m-%d %H:%M:%S")
  systemd-run --on-calendar="$NEXT_RUN" --unit=delayed-reboot.service /sbin/reboot
  REBOOT_SCHEDULED=1
fi

# --- パッケージ一覧（最大 50 件） ---
if [ "$COUNT" -eq 0 ]; then
  PACKAGE_LIST="なし"
else
  PACKAGE_LIST=$(echo "$UPDATED_PACKAGES" | head -n 50)
fi

PACKAGE_LIST=$(printf '```\n%s\n```' "$PACKAGE_LIST")

# --- Discord Embed のメッセージ本文 ---
DESCRIPTION="セキュリティ更新数: ${SECURITY_COUNT}
重大パッケージ検知数: ${CRITICAL_COUNT}
カーネル更新: ${KERNEL_UPDATED}
再起動予定: ${REBOOT_SCHEDULED}

更新一覧:
${PACKAGE_LIST}
※詳細ログ: ${LOG}"

# --- JSON ペイロード生成 ---
PAYLOAD=$(jq -n \
  --arg host    "$HOST"    \
  --arg cluster "$CLUSTER" \
  --arg result  "$RESULT"  \
  --arg desc    "$DESCRIPTION" \
  --argjson color "$COLOR" \
'{
  embeds: [{
    title: "APT自動メンテナンス結果",
    color: $color,
    fields: [
      {name: "ホスト",     value: $host,    inline: true},
      {name: "クラスタ",   value: $cluster, inline: true},
      {name: "実行結果",   value: $result,  inline: true}
    ],
    description: $desc
  }]
}')

# --- Discord へ送信 ---
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -X POST \
  -d "$PAYLOAD" \
  "$WEBHOOK_URL")

echo "Discord HTTP: $HTTP_CODE" >> "$LOG"
exit 0
SCRIPT_EOF

chmod +x "$SCRIPT"
success "$SCRIPT を作成しました"
echo ""

# --- systemd サービス/タイマーの作成 ---
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

# --- 完了メッセージ ---
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║          インストール完了！              ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"
echo "  設定ファイル : $CONF"
echo "  スクリプト   : $SCRIPT"
echo "  ログファイル : /var/log/apt-maintenance.log"
echo ""
echo "  動作確認コマンド:"
echo "    bash -x $SCRIPT"
echo "    systemctl list-timers apt-maintenance.timer"
echo "    tail -f /var/log/apt-maintenance.log"
echo ""
