# DEB64-AutoUpdate-Discord-Webhook

Linux サーバーの更新を自動で当てて、結果を Discord に知らせる仕組みです。

サーバーは放っておくとセキュリティ更新が溜まっていきます。かといって毎日ログインして
確認するのも続きません。これを入れておくと**更新は毎日勝手に当たり、その結果だけが
Discord に流れてきます**。うまくいけば緑、失敗したら赤なので、通知を眺めるだけで
状態が分かります。

更新の内容によっては再起動が必要になりますが、その場では再起動しません。
**あなたが決めた時刻（深夜など）に予約**されるので、作業中に落ちることがありません。

English: [README.md](README.md)

## できること

- 毎日決まった時刻に自動でパッケージ更新（`unattended-upgrades`）
- 実行結果を Discord へ通知。緑＝正常、黄＝再起動が必要、赤＝失敗
- 更新されたパッケージ名、セキュリティ更新の件数を通知に含める
- 再起動が要る更新のときだけ、指定時刻に再起動を予約
- 複数台へ Ansible で一括導入

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

## ドキュメント

| | |
|---|---|
| [docs/MANUAL-SETUP.ja.md](docs/MANUAL-SETUP.ja.md) | 手作業で入れる場合の手順 |
| [docs/OPERATIONS.ja.md](docs/OPERATIONS.ja.md) | Ansible でのクラスタ一括導入、動作確認、カスタマイズ |
