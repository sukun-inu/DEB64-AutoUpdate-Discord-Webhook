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

#### 構成と時刻

`inventory.ini` のグループごとに接続方法と時刻が違います。

| グループ | 対象 | 接続 | 更新 | 再起動 |
|---|---|---|---|---|
| `pve` | pve-01, pve-02 | root | 06:30 | 07:00 / 07:30（1 台ずつ） |
| `pbs` | pbs-01 | root | 06:30 | 08:00 |
| `vm` | dpl-01, dpl-02, dns-01 | kawasaki → sudo | 02:30 | 03:00 / 03:30 / 04:00（1 台ずつ） |

- 更新時刻はグループ単位で `group_vars/hosts.yml`（PVE・PBS）と `group_vars/vm.yml` に、再起動時刻は台ごとに `inventory.ini` に書いています。
- ホストの更新はバックアップ（0〜6 時）が終わってから行います。VM の更新・再起動はホストより先に済ませます。
- 再起動の直前に次を確認し、危なければ待つか見送ります（Discord に「再起動を見送りました」と届きます）。
  - バックアップ（vzdump）や PBS のタスクが実行中なら、最大 2 時間待つ
  - PVE クラスタが quorate でない、または停止中のノードがあるなら、再起動しない
- 再起動の直前に「これから再起動します」、起動後に「再起動完了」が届きます。前者だけで後者が来なければ、上がってこなかったということです。

> **2 ノードの PVE クラスタについて**: 片方を再起動している間、残った 1 台は quorum を失います
> （`/etc/pve` が読み取り専用になり、HA を使っていれば自己フェンスで再起動します）。
> PBS などに QDevice を立てて 3 票にしておくのがおすすめです。

#### PVE・PBS（root でパスワード認証）

```bash
ansible-playbook -i inventory.ini --limit hosts --ask-pass \
  -e "webhook_url=YOUR_DISCORD_WEBHOOK_URL" playbook.yml
```

#### VM（kawasaki で接続して sudo）

```bash
ansible-playbook -i inventory.ini --limit vm --ask-pass --ask-become-pass \
  -e "webhook_url=YOUR_DISCORD_WEBHOOK_URL" playbook.yml
```

> `-e "webhook_url=..."` を省くと、各サーバーの既存の `/etc/apt-discord.conf` から Webhook URL を引き継ぎます（新規のサーバーでは指定が必要）。
>
> SSH 鍵で入れるなら `--ask-pass` は不要です。sudo にパスワードが要らない設定なら `--ask-become-pass` も不要です。

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
| `/etc/systemd/system/apt-boot-notify.service` | 起動を Discord へ通知するサービス |
| `/etc/systemd/system/apt-boot-notify.timer` | 起動の 90 秒後に上のサービスを動かすタイマー |
| `/etc/apt/apt.conf.d/20auto-upgrades` | 標準の自動更新を止める設定（更新はこの仕組みに一本化） |
| `/var/lib/apt-maintenance/reboot-scheduled` | 再起動を予約した記録（起動通知が読んで削除する） |

再起動は `apt-delayed-reboot.timer` という一時的なタイマーで予約されます。

---

---

## 動作確認

```bash
# 今すぐ 1 回実行（結果が Discord に届く）
systemctl start apt-maintenance.service

# 起動通知だけ送ってみる（Webhook の疎通確認）
/usr/local/sbin/apt-maintenance.sh boot-notify

# 次回の実行時刻と、予約中の再起動
systemctl list-timers apt-maintenance.timer apt-delayed-reboot.timer

# 再起動待ちのパッケージ
cat /var/run/reboot-required.pkgs

# 実際に再起動した履歴
last -x reboot | head

# ログ確認
tail -f /var/log/apt-maintenance.log
```

### 予約した再起動を確認・取り消したい

```bash
systemctl list-timers apt-delayed-reboot.timer   # 予約の有無と時刻
systemctl stop apt-delayed-reboot.timer
rm -f /var/lib/apt-maintenance/reboot-scheduled
```

翌日のメンテナンスで再起動がまだ必要なら、改めて予約されます。

---

---

## カスタマイズポイント

- **重大パッケージの追加**: スクリプト内の `CRITICAL_REGEX` に `|パッケージ名` を追記する
- **ディスク警告のしきい値**: スクリプト内の `DISK_WARN_PCT`（デフォルト 90%）
- **起動通知までの待ち時間**: `apt-boot-notify.timer` の `OnBootSec`（デフォルト 90 秒）
- **通知先の変更**: `WEBHOOK_URL` を差し替えるだけで Slack / Teams 等にも対応可（ペイロード形式は要変更）
- **実行時刻の変更**: タイマーの `OnCalendar` と設定ファイルの `REBOOT_TIME` を変更する。
  再起動は「再起動が必要になったあと、次に `REBOOT_TIME` が来たとき」に行われる

---
