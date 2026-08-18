# DEB64-AutoUpdate-Discord-Webhook

Unattended APT maintenance for Debian and Ubuntu, reporting to Discord.

Packages are updated daily by `unattended-upgrades`; the result is posted to a Discord
webhook as a colour-coded embed. If the update touched the kernel, a reboot is scheduled
for a time you choose rather than taken immediately.

日本語版: [README.ja.md](README.ja.md)

## What it does

- Daily automatic package updates via `unattended-upgrades`, driven by a systemd timer
- Discord notification per run: **green** for a clean run, **yellow** when a kernel
  update was applied, **red** on failure
- Kernel updates are detected and a reboot is booked for the configured `REBOOT_TIME`
  instead of interrupting whatever the box is doing
- Security-update and critical-package counts are summarised in the embed
- Ansible playbook for rolling the whole thing out across a cluster at once
- `install.sh` and `uninstall.sh` for single hosts

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/sukun-inu/DEB64-AutoUpdate-Discord-Webhook/main/install.sh | bash
```

You will need a Discord webhook URL (Server Settings → Integrations → Webhooks) and a
reboot time in 24-hour form. Both live in `/etc/apt-discord.conf`, which is created with
mode 600.

For a cluster, use the Ansible playbook under `ansible/`. To remove everything, run
`uninstall.sh`.

If you would rather install by hand, or `curl` is not available, the full manual
procedure is in [docs/MANUAL-SETUP.ja.md](docs/MANUAL-SETUP.ja.md).

## Layout

```
install.sh / uninstall.sh                          single-host install
ansible/                                           cluster rollout
ansible/roles/apt-discord/files/apt-maintenance.sh the maintenance script itself
```

`apt-maintenance.sh` is the single source of truth for the script — it is deliberately
not duplicated into the documentation, because a copy in a README goes stale.

## Documentation

| | |
|---|---|
| [docs/MANUAL-SETUP.ja.md](docs/MANUAL-SETUP.ja.md) | Installing by hand, step by step |

Detailed documentation is Japanese-only for now.
