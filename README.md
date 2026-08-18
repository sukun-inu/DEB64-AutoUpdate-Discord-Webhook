# DEB64-AutoUpdate-Discord-Webhook

Keeps a Linux server updated on its own, and tells you about it on Discord.

Left alone, a server quietly accumulates security updates. Logging in every day to check
is not something anyone keeps up. With this installed, **updates are applied daily and
the result shows up in Discord** — green when it went fine, red when it did not. You can
tell the state of the machine from the notification alone.

Some updates need a reboot. This does not reboot on the spot: it **books one for a time
you choose**, so nothing goes down while you are using it.

日本語版: [README.ja.md](README.ja.md)

## What it does

- Applies package updates daily via `unattended-upgrades`, on a systemd timer
- Reports each run to Discord: green for clean, yellow when a reboot is needed,
  red on failure
- Includes updated package names and the security-update count in the notification
- Schedules a reboot at your chosen time, and only when the update actually needs one
- Rolls out to many machines at once with Ansible

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/sukun-inu/DEB64-AutoUpdate-Discord-Webhook/main/install.sh | bash
```

You need a Discord webhook URL (Server Settings → Integrations → Webhooks) and a reboot
time in 24-hour form. Both are stored in `/etc/apt-discord.conf`, created with mode 600.

To remove everything, run `uninstall.sh`.

`apt-maintenance.sh` under `ansible/roles/apt-discord/files/` is the single source of
truth for the script itself — it is deliberately not copied into the documentation,
because a copy goes stale.

## Documentation

| | |
|---|---|
| [docs/MANUAL-SETUP.ja.md](docs/MANUAL-SETUP.ja.md) | Installing by hand, step by step |
| [docs/OPERATIONS.ja.md](docs/OPERATIONS.ja.md) | Cluster rollout with Ansible, verification, customisation |

Detailed documentation is Japanese-only for now.
