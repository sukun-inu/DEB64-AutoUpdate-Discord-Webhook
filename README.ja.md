# DEB64-AutoUpdate-Discord-Webhook
## APT 自動メンテナンス + Discord 通知

Debian/Ubuntu 系サーバーのパッケージを毎日自動アップデートし、結果を Discord に通知するセットアップです。
カーネル更新を検知した場合は翌朝指定時刻に自動再起動をスケジュールします。

English: [README.md](README.md)

---

## クイックスタート

### インストール

```bash
curl -fsSL https://raw.githubusercontent.com/sukun-inu/DEB64-AutoUpdate-Discord-Webhook/main/install.sh | sudo bash
```

> 実行前にスクリプトの内容を確認したい場合:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/sukun-inu/DEB64-AutoUpdate-Discord-Webhook/main/install.sh | less
> ```

インストール中に以下を対話形式で入力します:
- **Webhook URL** — Discord チャンネルの「サーバー設定 → 連携サービス → ウェブフック」から取得
- **メンテナンス実行時刻** — APT アップデートを実行する時刻（デフォルト: `02:30`）
- **カーネル更新後の再起動時刻** — カーネル更新を検知した翌朝に再起動する時刻（デフォルト: `03:00`）

既にインストール済みの場合は上書き確認プロンプトが表示されます。

---

### アンインストール

```bash
curl -fsSL https://raw.githubusercontent.com/sukun-inu/DEB64-AutoUpdate-Discord-Webhook/main/uninstall.sh | sudo bash
```

インストール済みファイルを検出して一覧表示し、削除確認を求めます。
ログファイルの削除有無も個別に確認します。

---

### Ansible でクラスター一括インストール

#### 事前準備（管理ノードで1回だけ）

```bash
apt install -y ansible sshpass git
ansible-galaxy collection install community.general

# 初回
git clone https://github.com/sukun-inu/DEB64-AutoUpdate-Discord-Webhook.git /tmp/apt-discord \
  || git -C /tmp/apt-discord pull

cd /tmp/apt-discord/ansible
```

> `ansible.cfg` を読み込むため、以降のコマンドは `/tmp/apt-discord/ansible/` で実行してください。

#### 全ノード（root パスワード認証）

```bash
ansible-playbook -i inventory.ini --ask-pass \
  -e "webhook_url=YOUR_DISCORD_WEBHOOK_URL" playbook.yml
```

#### 特定ノードのみ

```bash
ansible-playbook -i inventory.ini \
  --limit pve-01.prod.dc1.kawasaki-n3t.f5.si --ask-pass \
  -e "webhook_url=YOUR_DISCORD_WEBHOOK_URL" playbook.yml
```

---

## 構成ファイル一覧

| ファイル | 役割 |
|---|---|
| `/etc/apt-discord.conf` | Webhook URL・再起動時刻の設定 |
| `/usr/local/sbin/apt-maintenance.sh` | メンテナンス本体スクリプト |
| `/etc/systemd/system/apt-maintenance.service` | systemd サービス定義 |
| `/etc/systemd/system/apt-maintenance.timer` | 毎日 02:30 に起動するタイマー |

---

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

---

## ドキュメント

| | |
|---|---|
| [docs/MANUAL-SETUP.ja.md](docs/MANUAL-SETUP.ja.md) | `install.sh` を使わず手作業で入れる場合の手順 |
