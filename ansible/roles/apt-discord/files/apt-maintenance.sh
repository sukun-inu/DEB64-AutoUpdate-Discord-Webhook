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

echo "===== $(date '+%F %T %Z') =====" >> "$LOG"

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
  systemctl stop delayed-reboot.service 2>/dev/null || true
  systemd-run --on-calendar="$NEXT_RUN" --unit=delayed-reboot.service /sbin/reboot
  REBOOT_SCHEDULED=1
fi

if [ "$COUNT" -eq 0 ]; then
  PACKAGE_LIST="なし"
else
  PACKAGE_LIST=$(echo "$UPDATED_PACKAGES" | head -n 50)
fi
PACKAGE_LIST=$(printf '```\n%s\n```' "$PACKAGE_LIST")

TZ_INFO=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
NTP_INFO=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")

DESCRIPTION="セキュリティ更新数: ${SECURITY_COUNT}
重大パッケージ検知数: ${CRITICAL_COUNT}
カーネル更新: ${KERNEL_UPDATED}
再起動予定: ${REBOOT_SCHEDULED}
タイムゾーン: ${TZ_INFO} / NTP同期: ${NTP_INFO}

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
