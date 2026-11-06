# 手動セットアップ

[← README.ja.md に戻る](../README.ja.md)

`install.sh` を使わず、内容を確認しながら入れたい場合の手順。

---

curl が使えない環境や、内容を確認しながらセットアップしたい場合。

### 1. 必要パッケージのインストール

```bash
apt install -y unattended-upgrades jq curl

# 更新はこの仕組みのタイマーに一本化する（標準の apt-daily-upgrade に更新させない）
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
EOF
```

> `dpkg-reconfigure unattended-upgrades` は実行しないでください。標準の自動更新が有効になり、
> 通知の外で更新が済んでしまいます。

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
> **REBOOT_TIME** : 再起動が必要な更新があったとき、次にこの時刻が来たら再起動する（24h 表記）。

---

### 3. メンテナンススクリプトの作成

スクリプト本体は **リポジトリの [`apt-maintenance.sh`](../apt-maintenance.sh)** が唯一の正です。
手順書に写しを置くと必ず古くなるので、ここでは実ファイルをそのまま配置します。

リポジトリを clone 済みの場合:

```bash
install -m 755 apt-maintenance.sh \
  /usr/local/sbin/apt-maintenance.sh
```

curl で直接取る場合:

```bash
curl -fsSL https://raw.githubusercontent.com/sukun-inu/DEB64-AutoUpdate-Discord-Webhook/main/apt-maintenance.sh \
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

### 6. 起動通知サービスとタイマーの作成

起動の 90 秒後に、起動したことと失敗しているサービスの有無を Discord へ通知します。

```bash
cat > /etc/systemd/system/apt-boot-notify.service << 'EOF'
[Unit]
Description=Notify Discord that the server has booted
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apt-maintenance.sh boot-notify
EOF

cat > /etc/systemd/system/apt-boot-notify.timer << 'EOF'
[Unit]
Description=Notify Discord shortly after boot

[Timer]
# サービスの起動が一通り終わってから状態を報告する
OnBootSec=90s

[Install]
WantedBy=timers.target
EOF
```

---

### 7. 有効化

```bash
systemctl daemon-reload
systemctl enable --now apt-maintenance.timer
systemctl enable apt-boot-notify.timer

# 疎通確認（Discord に「サーバーが起動しました」と届けば OK）
/usr/local/sbin/apt-maintenance.sh boot-notify
```

---
