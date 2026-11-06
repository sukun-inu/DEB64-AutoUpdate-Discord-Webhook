# DEB64-AutoUpdate-Discord-Webhook

Keeps a Linux server updated on its own, and tells you about it on Discord.

Left alone, a server quietly accumulates security updates. Logging in every day to check
is not something anyone keeps up. With this installed, **updates are applied daily and
the result shows up in Discord**. Each notification is titled "server ｜ outcome", so you
can tell the state of every machine by glancing at the channel.

Some updates need a reboot. This does not reboot on the spot: it **books one for a time
you choose**, and right before rebooting it checks that nothing important (such as a
backup) is still running.

日本語版: [README.ja.md](README.ja.md)

## What it does

- Applies package updates daily via `unattended-upgrades`, on a systemd timer
- Lists each updated package as "old version → new version"
- Schedules a reboot at your chosen time, and only when the update actually needs one
  (the notification says when, and which packages need it)
- Right before rebooting, checks for running backups and offline Proxmox cluster nodes,
  and waits or skips the reboot if it is not safe
- **Posts "reboot complete" after every boot**, so you can tell the reboot happened —
  and spot unplanned ones (power loss, manual reboots)
- Reports updates left for a manual upgrade (e.g. Proxmox packages), only when new ones appear
- Sends a weekly stability report: disk, memory, load, failed services, time sync,
  pending reboot, and whether the last maintenance run succeeded
- Reports an error even when the script dies part-way

## Notifications

| Title (example) | When |
|---|---|
| ✅ pve-01 ｜ 3 件更新 | Daily run, all fine |
| 🔁 pve-01 ｜ 3 件更新 ・ 11/07 07:00 に再起動 | Daily run, reboot booked |
| ⚠️ pve-01 ｜ 更新なし（要確認） | Daily run found failed services or low disk |
| ❌ pve-01 ｜ メンテナンス失敗 | Update or reboot booking failed |
| 🔁 pve-01 ｜ これから再起動します | Right before the booked reboot |
| ⛔ pve-01 ｜ 再起動を見送り | Pre-reboot check said no (booked again next day) |
| 🟢 pve-01 ｜ 再起動完了 | 90 s after coming back from a booked reboot |
| 🔵 pve-01 ｜ 起動しました（予約外） | Booted for any other reason |
| 🩺 pve-01 ｜ 安定性チェック：問題なし | Every Monday 09:00 |
| ❌ pve-01 ｜ スクリプトエラー | The script died part-way |

Notification text is in Japanese. If "rebooting now" arrives without a following
"reboot complete", the machine did not come back.

## Requirements

- A Debian-family OS with systemd (used on Debian 12 / 13, Ubuntu 24.04+, Proxmox VE,
  Proxmox Backup Server)
- Root (run as root or through sudo)
- A Discord webhook URL

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/sukun-inu/DEB64-AutoUpdate-Discord-Webhook/main/install.sh | sudo bash
```

The installer asks for a Discord webhook URL (Server Settings → Integrations → Webhooks),
the daily maintenance time and the reboot time (24-hour form). They are stored in
`/etc/apt-discord.conf`, created with mode 600. It finishes by offering a test notification.

Running the same command again upgrades the script; press Enter to keep each existing setting.
To remove everything, run `uninstall.sh` the same way.

`apt-maintenance.sh` at the repository root is the single source of truth for the script.
`install.sh` embeds an identical copy; the two are kept in sync.

## Documentation

| | |
|---|---|
| [docs/OPERATIONS.ja.md](docs/OPERATIONS.ja.md) | Schedules across several machines, verification, troubleshooting, customisation |
| [docs/MANUAL-SETUP.ja.md](docs/MANUAL-SETUP.ja.md) | Installing by hand without `install.sh` |

Detailed documentation is Japanese-only for now.
