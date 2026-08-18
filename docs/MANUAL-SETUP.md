# 手動セットアップ

[← README に戻る](../README.md)

`install.sh` や Ansible を使わず、内容を確認しながら入れたい場合の手順。

---

curl が使えない環境や、内容を確認しながらセットアップしたい場合。

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

スクリプト本体は **リポジトリの [`ansible/roles/apt-discord/files/apt-maintenance.sh`](../ansible/roles/apt-discord/files/apt-maintenance.sh)** が唯一の正です。
手順書に写しを置くと必ず古くなるので、ここでは実ファイルをそのまま配置します。

リポジトリを clone 済みの場合:

```bash
install -m 755 ansible/roles/apt-discord/files/apt-maintenance.sh \
  /usr/local/sbin/apt-maintenance.sh
```

curl で直接取る場合:

```bash
curl -fsSL https://raw.githubusercontent.com/sukun-inu/DEB64-AutoUpdate-Discord-Webhook/main/ansible/roles/apt-discord/files/apt-maintenance.sh \
  -o /usr/local/sbin/apt-maintenance.sh
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
