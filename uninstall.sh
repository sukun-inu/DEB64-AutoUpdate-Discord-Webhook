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
AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"
LOG="/var/log/apt-maintenance.log"

[ "$EUID" -ne 0 ] && die "root 権限が必要です。sudo で実行してください。"

echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  APT Auto-Update + Discord Webhook       ║"
echo "  ║  アンインストーラー                      ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"

# --- インストール確認 ---
FOUND_FILES=()
for f in "$CONF" "$SCRIPT" "$SERVICE" "$TIMER" "$AUTO_UPGRADES"; do
  [ -f "$f" ] && FOUND_FILES+=("$f")
done

if [ "${#FOUND_FILES[@]}" -eq 0 ]; then
  warn "インストール済みファイルが見つかりませんでした。"
  info "既にアンインストール済みか、手動でセットアップされた環境の可能性があります。"
  exit 0
fi

warn "以下のファイルを削除します:"
for f in "${FOUND_FILES[@]}"; do
  echo "    - $f"
done
echo ""

read -rp "  本当にアンインストールしますか？ [y/N]: " answer </dev/tty
case "$answer" in
  y|Y|yes|YES) ;;
  *) info "アンインストールを中止しました。"; exit 0 ;;
esac
echo ""

# --- タイマー/サービスの停止・無効化 ---
if systemctl is-active --quiet apt-maintenance.timer 2>/dev/null; then
  info "タイマーを停止しています..."
  systemctl stop apt-maintenance.timer
  success "タイマーを停止しました"
fi

if systemctl is-enabled --quiet apt-maintenance.timer 2>/dev/null; then
  info "タイマーを無効化しています..."
  systemctl disable apt-maintenance.timer
  success "タイマーを無効化しました"
fi

# --- ファイル削除 ---
info "ファイルを削除しています..."
# Fix 3: install.sh が作成した 20auto-upgrades も削除対象に追加
for f in "$TIMER" "$SERVICE" "$SCRIPT" "$CONF" "$AUTO_UPGRADES"; do
  if [ -f "$f" ]; then
    rm -f "$f"
    success "削除: $f"
  fi
done

systemctl daemon-reload
success "systemd をリロードしました"
echo ""

# --- ログファイル ---
if [ -f "$LOG" ]; then
  read -rp "  ログファイル ($LOG) も削除しますか？ [y/N]: " answer </dev/tty
  case "$answer" in
    y|Y|yes|YES)
      rm -f "$LOG"
      success "ログファイルを削除しました"
      ;;
    *)
      info "ログファイルは保持しました: $LOG"
      ;;
  esac
  echo ""
fi

echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║          アンインストール完了！          ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${RESET}"
echo "  依存パッケージ (unattended-upgrades, jq, curl) は"
echo "  他の用途で使用されている可能性があるため削除しませんでした。"
echo "  不要な場合は手動で削除してください:"
echo "    apt-get remove unattended-upgrades jq"
echo ""
