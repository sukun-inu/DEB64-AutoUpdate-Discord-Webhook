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
- 再起動の直前に次を確認し、危なければ待つか見送ります（Discord に「再起動を見送り」と届きます）。
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

## 通知の見方

毎日のメンテナンス通知は、タイトルに「サーバー名 ｜ 結果」、本文に次の 3 行が並びます。

| 行 | 内容 |
|---|---|
| **適用** | 今回入った更新。「パッケージ名 旧版 → 新版」をコードブロックで最大 15 行 |
| **再起動** | 不要／予約した時刻。予約したときは、再起動が必要になったパッケージも並ぶ |
| **未適用** | 自動更新の対象外で残っている更新の件数。前回から増えたときだけ、増えた分の名前が並ぶ |

フッター（下の小さい文字）には IP・OS・カーネル・次回実行・所要時間が出ます。

**未適用の更新**は、`unattended-upgrades` が自動では入れないもの（Proxmox のリポジトリのパッケージなど）です。
必要に応じて手動で `apt full-upgrade` してください。

**安定性チェック**（毎週月曜 09:00）は、次の項目を ✅ / ⚠️ で並べます。

| 項目 | ⚠️ になる条件 |
|---|---|
| ディスク | `/` の使用率が 90% 以上 |
| メモリ | 使用率が 90% 以上 |
| 負荷 | 15 分平均がコア数を超えている |
| 失敗しているサービス | 1 件以上ある |
| 時刻同期 | NTP で同期できていない |
| 再起動待ち | 再起動が必要なのに予約されていない |
| 前回のメンテナンス | 失敗していた、記録がない、または 48 時間以上動いていない |

稼働時間と未適用の更新の件数は、参考として表示するだけです（⚠️ にはなりません）。

---

## 構成ファイル一覧

| ファイル | 役割 |
|---|---|
| `/etc/apt-discord.conf` | Webhook URL・更新時刻（`MAINTENANCE_TIME`）・再起動時刻（`REBOOT_TIME`） |
| `/usr/local/sbin/apt-maintenance.sh` | スクリプト本体 |
| `/etc/systemd/system/apt-maintenance.service` / `.timer` | 毎日 `MAINTENANCE_TIME` にメンテナンスを実行 |
| `/etc/systemd/system/apt-boot-notify.service` / `.timer` | 起動の 90 秒後に起動通知を送る |
| `/etc/systemd/system/apt-health.service` / `.timer` | 毎週月曜 09:00 に安定性チェックを送る |
| `/etc/apt/apt.conf.d/20auto-upgrades` | 標準の自動更新を止める設定（更新はこの仕組みに一本化） |
| `/var/lib/apt-maintenance/reboot-scheduled` | 再起動を予約した記録（起動通知が読んで削除する） |
| `/var/lib/apt-maintenance/last-run` | 前回のメンテナンスの時刻と結果（安定性チェックが読む） |
| `/var/lib/apt-maintenance/pending.list` | 前回の未適用の更新（差分だけを通知するため） |
| `/var/log/apt-maintenance.log` | 実行ログ |

再起動は `apt-delayed-reboot.timer` という一時的なタイマーで予約されます（再起動すると消えます）。

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
systemctl list-timers 'apt-*'

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
systemctl stop apt-delayed-reboot.timer          # 取り消す
rm -f /var/lib/apt-maintenance/reboot-scheduled
```

翌日のメンテナンスで再起動がまだ必要なら、改めて予約されます。

---

## 通知が届かないとき

ログの最後に、Discord から返ってきた HTTP コードが残っています。

```bash
grep "Discord HTTP" /var/log/apt-maintenance.log | tail -n 5
```

| コード | 意味と対処 |
|---|---|
| `204` | 送信できています。Discord 側のチャンネルを確認してください |
| `000` | Discord に届いていません。DNS かネットワークの問題です。`getent hosts discord.com` で名前解決できるか確認してください |
| `401` / `404` | Webhook URL が間違っているか、削除されています。`install.sh` を再実行して URL を入れ直してください |
| `429` | 送りすぎで制限されています。しばらくすると戻ります |

ログに何も書かれていない場合は、タイマー自体が動いていません。`systemctl list-timers 'apt-*'` で
`apt-maintenance.timer` が並んでいるか確認し、なければ `install.sh` を再実行してください。

---

## カスタマイズポイント

- **実行時刻の変更**: `install.sh` を再実行して時刻を入れ直すのが簡単です。
  手で変える場合は、タイマーの `OnCalendar` と設定ファイルの `MAINTENANCE_TIME`（通知の「次回」表示に使う）の両方を変えてください。
  再起動は「再起動が必要になったあと、次に `REBOOT_TIME` が来たとき」に行われます。
- **安定性チェックの頻度**: `apt-health.timer` の `OnCalendar`（デフォルト 毎週月曜 09:00。毎日なら `*-*-* 09:00:00`）
- **起動通知までの待ち時間**: `apt-boot-notify.timer` の `OnBootSec`（デフォルト 90 秒）
- **しきい値など**（スクリプト冒頭の変数）
  - `DISK_WARN_PCT` — ディスク警告（90%）
  - `MEM_WARN_PCT` — メモリ警告（90%）
  - `STALE_HOURS` — 前回のメンテナンスからこの時間空いたら警告（48 時間）
  - `BUSY_WAIT_MIN` — 再起動前にバックアップ等の終了を待つ最大時間（120 分）
  - `LIST_MAX` — 通知に並べるパッケージの最大行数（15 行）
  - `CRITICAL_REGEX` — 「重要」として数えるパッケージ
- **通知先の変更**: `WEBHOOK_URL` を差し替えれば別のチャンネルに送れます。Slack / Teams などはペイロードの形式が違うので、`send_discord` の書き換えが必要です。

スクリプトを手で書き換えた場合、`install.sh` を再実行すると元に戻ります。
