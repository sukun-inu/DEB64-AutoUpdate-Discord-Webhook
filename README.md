# DEB64-AutoUpdate-Discord-Webhook
## APT 自動メンテナンス + Discord 通知

Debian/Ubuntu 系サーバーのパッケージを毎日自動アップデートし、結果を Discord に通知するセットアップです。
カーネル更新を検知した場合は翌朝指定時刻に自動再起動をスケジュールします。

---

## 構成ファイル一覧

| ファイル | 役割 |
|---|---|
| `/etc/apt-discord.conf` | Webhook URL・再起動時刻の設定 |
| `/usr/local/sbin/apt-maintenance.sh` | メンテナンス本体スクリプト |
| `/etc/systemd/system/apt-maintenance.service` | systemd サービス定義 |
| `/etc/systemd/system/apt-maintenance.timer` | 毎日 02:30 に起動するタイマー |

---

## セットアップ手順

### 1. 必要パッケージのインストール

```bash
apt install -y unattended-upgrades jq curl
dpkg-reconfigure -plow unattended-upgrades
```

---

### 2. 設定ファイルの作成

```bash
cat > /etc/apt-discord.conf << 'EOF'
WEBHOOK_URL="YOUR_DISCORD_WEBHOOK_URL"
REBOOT_TIME="03:00"
EOF

chmod 600 /etc/apt-discord.conf
```

> **WEBHOOK_URL** : Discord チャンネルの「サーバー設定 → 連携サービス → ウェブフック」から取得してください。  
> **REBOOT_TIME** : カーネル更新後に再起動する時刻（24h 表記）。

---

### 3. メンテナンススクリプトの作成

```bash
cat > /usr/local/sbin/apt-maintenance.sh << 'EOF'
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

# --- 重大パッケージ定義（必要に応じて拡張） ---
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
EOF

chmod +x /usr/local/sbin/apt-maintenance.sh
```

---

### 4. systemd サービスの作成

```bash
cat > /etc/systemd/system/apt-maintenance.service << 'EOF'
[Unit]
Description=APT Maintenance with Delayed Reboot and Discord
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apt-maintenance.sh
EOF
```

---

### 5. systemd タイマーの作成

```bash
cat > /etc/systemd/system/apt-maintenance.timer << 'EOF'
[Unit]
Description=Run APT Maintenance Daily

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

> タイマーは毎日 **02:30** に起動します。変更する場合は `OnCalendar` を編集してください。

---

### 6. 有効化

```bash
systemctl daemon-reload
systemctl enable --now apt-maintenance.timer
```

---

## 動作確認

```bash
# デバッグ実行（全コマンドをトレース表示）
bash -x /usr/local/sbin/apt-maintenance.sh
echo "exit code: $?"

# タイマーの登録確認
systemctl list-timers apt-maintenance.timer

# ログ確認
tail -f /var/log/apt-maintenance.log
```

---

## Discord 通知の色凡例

| 色 | 意味 |
|---|---|
| 🟢 緑 `#2ECC71` | 正常完了 |
| 🟡 黄 `#F1C40F` | カーネル更新あり（翌朝再起動予定） |
| 🔴 赤 `#E74C3C` | `unattended-upgrade` がエラー終了 |

---

## カスタマイズポイント

- **重大パッケージの追加**: スクリプト内の `CRITICAL_REGEX` に `|パッケージ名` を追記する
- **通知先の変更**: `WEBHOOK_URL` を差し替えるだけで Slack / Teams 等にも対応可（ペイロード形式は要変更）
- **実行時刻の変更**: タイマーの `OnCalendar` と設定ファイルの `REBOOT_TIME` を変更する
