# 運用（クラスタ展開・動作確認・カスタマイズ）

[← README.ja.md に戻る](../README.ja.md)

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

---

## カスタマイズポイント

- **重大パッケージの追加**: スクリプト内の `CRITICAL_REGEX` に `|パッケージ名` を追記する
- **通知先の変更**: `WEBHOOK_URL` を差し替えるだけで Slack / Teams 等にも対応可（ペイロード形式は要変更）
- **実行時刻の変更**: タイマーの `OnCalendar` と設定ファイルの `REBOOT_TIME` を変更する

---
