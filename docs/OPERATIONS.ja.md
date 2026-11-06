# 運用（複数台への導入・動作確認・カスタマイズ）

[← README.ja.md に戻る](../README.ja.md)

---

## 複数台への導入

台数が少ないので、各サーバーで `install.sh` を実行します（root なら `| bash`、一般ユーザーなら `| sudo bash`）。

```bash
curl -fsSL https://raw.githubusercontent.com/sukun-inu/DEB64-AutoUpdate-Discord-Webhook/main/install.sh | sudo bash
```

再インストールのときは既存の `/etc/apt-discord.conf` を読み込むので、Webhook URL は空のまま Enter で引き継げます。
時刻だけ下の表に合わせて入力してください。

### 時刻の割り当て

再起動が重ならないよう、台ごとに時刻をずらしています（バックアップは 0〜6 時に動く前提）。

| サーバー | 種別 | 更新 | 再起動 |
|---|---|---|---|
| dpl-01 | VM | 02:30 | 03:00 |
| dpl-02 | VM | 02:30 | 03:30 |
| dns-01 | VM | 02:30 | 04:00 |
| pve-01 | PVE | 06:30 | 07:00 |
| pve-02 | PVE | 06:30 | 07:30 |
| pbs-01 | PBS | 06:30 | 08:00 |

- VM の更新・再起動を先に済ませ、ホストはバックアップが終わってから更新します。
- 再起動の直前に次を確認し、危なければ待つか見送ります（Discord に「再起動を見送りました」と届きます）。
  - バックアップ（vzdump）や PBS のタスクが実行中なら、最大 2 時間待つ
  - PVE クラスタが quorate でない、または停止中のノードがあるなら、再起動しない
- 再起動の直前に「これから再起動します」、起動後に「再起動完了」が届きます。前者だけで後者が来なければ、上がってこなかったということです。
- サーバーを増減したら、この表も更新してください。

> **2 ノードの PVE クラスタについて**: 片方を再起動している間、残った 1 台は quorum を失います
> （`/etc/pve` が読み取り専用になり、HA を使っていれば自己フェンスで再起動します）。
> PBS などに QDevice を立てて 3 票にしておくのがおすすめです。
>
> クラスタから外したノードが `pvecm nodes` に残っていると「停止中のノードがある」と判定され、
> 自動再起動が毎回見送られます。外したノードは `pvecm delnode <名前>` で削除してください。

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
| `/etc/systemd/system/apt-health.service` / `.timer` | 毎週月曜 09:00 に安定性チェックを通知 |
| `/var/lib/apt-maintenance/last-run` | 前回のメンテナンスの時刻と結果（安定性チェックが読む） |
| `/var/lib/apt-maintenance/pending.list` | 前回の未適用の更新（差分だけを通知するため） |
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

# 安定性チェックを今すぐ送る
/usr/local/sbin/apt-maintenance.sh health

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
- **安定性チェックの頻度**: `apt-health.timer` の `OnCalendar`（デフォルト 毎週月曜 09:00。毎日なら `*-*-* 09:00:00`）
- **安定性チェックのしきい値**: スクリプト内の `MEM_WARN_PCT`（90%）、`STALE_HOURS`（前回のメンテナンスから 48 時間）
- **通知先の変更**: `WEBHOOK_URL` を差し替えるだけで Slack / Teams 等にも対応可（ペイロード形式は要変更）
- **実行時刻の変更**: タイマーの `OnCalendar` と設定ファイルの `REBOOT_TIME` を変更する。
  再起動は「再起動が必要になったあと、次に `REBOOT_TIME` が来たとき」に行われる

---
