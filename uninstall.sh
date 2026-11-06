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
BOOT_TIMER="/etc/systemd/system/apt-boot-notify.timer"
STATE_DIR="/var/lib/apt-maintenance"
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
for f in "$CONF" "$SCRIPT" "$SERVICE" "$TIMER" "$BOOT_SERVICE" "$BOOT_TIMER" "$AUTO_UPGRADES"; do
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
# bad-setting 等の壊れた状態でも確実に止まるよう is-active/is-enabled チェックを省き
# 直接 stop/disable し、失敗は無視する。シンボリックリンクも明示的に削除する。
info "タイマーを停止・無効化しています..."
systemctl stop apt-maintenance.timer 2>/dev/null || true
systemctl disable apt-maintenance.timer 2>/dev/null || true
rm -f /etc/systemd/system/timers.target.wants/apt-maintenance.timer
systemctl disable apt-boot-notify.timer 2>/dev/null || true
rm -f /etc/systemd/system/timers.target.wants/apt-boot-notify.timer
rm -f /etc/systemd/system/multi-user.target.wants/apt-boot-notify.service
success "タイマーを停止・無効化しました"

# 予約済みの再起動があれば取り消す（旧バージョンのユニット名も対象）
for u in apt-delayed-reboot delayed-reboot; do
  if systemctl is-active --quiet "${u}.timer" 2>/dev/null; then
    systemctl stop "${u}.timer" "${u}.service" 2>/dev/null || true
    success "予約されていた再起動を取り消しました (${u}.timer)"
  fi
done

# --- ファイル削除 ---
info "ファイルを削除しています..."
# Fix 3: install.sh が作成した 20auto-upgrades も削除対象に追加
for f in "$TIMER" "$SERVICE" "$BOOT_SERVICE" "$BOOT_TIMER" "$SCRIPT" "$CONF" "$AUTO_UPGRADES"; do
  if [ -f "$f" ]; then
    rm -f "$f"
    success "削除: $f"
  fi
done

rm -rf "$STATE_DIR"

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
