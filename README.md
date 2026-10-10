# 🚀 Pterodactyl Auto-Installer

> **One-command Pterodactyl Panel + Wings installer with automatic Let's Encrypt SSL, node provisioning via Application API, and Indonesian APT mirror support.**

Created by **[Sewanode](https://github.com/Sewanode)**

---

## 📖 Table of Contents

- [Overview](#-overview)
- [Features](#-features)
- [Requirements](#-requirements)
- [One-Liner Install](#-one-liner-install)
- [CLI Arguments](#-cli-arguments)
- [What Gets Installed](#-what-gets-installed)
- [SSL Configuration](#-ssl-configuration)
- [Post-Installation](#-post-installation)
- [Troubleshooting](#-troubleshooting)
- [File Locations](#-file-locations)
- [Uninstall](#-uninstall)
- [License](#-license)
- [Credits](#-credits)

---

## 🔭 Overview

This installer automates the **entire** Pterodactyl Panel + Wings setup on a fresh Ubuntu/Debian VPS — from system dependencies, database, Panel installation, SSL provisioning, to automatic **Location & Node registration** via the Panel's Application API.

No more manual clicking around the admin panel. Just run one command and get a fully working, SSL-secured Pterodactyl installation with a registered node ready to deploy game servers.

---

## ✨ Features

- ✅ **Fully automated** — panel, database, queue worker, Nginx vhost, Wings daemon in one shot
- 🔒 **Automatic SSL** via Let's Encrypt (Certbot webroot)
- 🌐 **Auto node registration** using Pterodactyl Application API + `artisan tinker`
- 🇮🇩 **Indonesian APT mirror** for faster package downloads (auto-fallback if unreachable)
- 🐳 **Docker + Containerd** setup out of the box
- 🔧 **Redis** configured for cache, session, and queue
- 🧩 **Multi-architecture** — supports `x86_64` (amd64) and `aarch64`/`arm64`
- 🧪 **Fail-fast** with clear error messages and log dumps on failure
- 📦 **Idempotent** — safe to re-run on a partially configured system
- 🔌 **SSL-aware Wings config** — auto-injects certificate paths and `allowed_origins`

---

## 📋 Requirements

| Item | Minimum |
|------|---------|
| **OS** | Ubuntu 22.04 / 24.04 / 26.04 or Debian 12+ |
| **Architecture** | x86_64 or ARM64 |
| **RAM** | 2 GB (4 GB+ recommended) |
| **Disk** | 20 GB |
| **Privileges** | Root access |
| **Domains** | 2 subdomains pointing to the server IP (A records) |
| **Ports** | 80, 443, 2141 (daemon), 2142 (SFTP) open |

> ⚠️ **Important:** Both `panel.domain.com` and `node.domain.com` **must** resolve to your server's IP **before** running the installer, otherwise Let's Encrypt will fail.

---

## ⚡ One-Liner Install

No download, no `chmod +x`. Just run one command as **root**:

### 🔒 With SSL (Production — recommended)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Sewanode/pterodactyl-installer/main/installer.sh) \
  --domainp panel.yourdomain.com \
  --domainw node.yourdomain.com \
  --email admin@yourdomain.com \
  --pass 'YourStrongPassword123' \
  --dport 2141 \
  --sftpport 2142 \
  --ssl
```

### 🌐 Without SSL (Development / Internal)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Sewanode/pterodactyl-installer/main/installer.sh) \
  --domainp panel.yourdomain.com \
  --domainw node.yourdomain.com \
  --email admin@yourdomain.com \
  --pass 'YourStrongPassword123'
```

### 🐚 Alternative — Pipe into bash

```bash
curl -fsSL https://raw.githubusercontent.com/Sewanode/pterodactyl-installer/main/installer.sh | bash -s -- \
  --domainp panel.yourdomain.com \
  --domainw node.yourdomain.com \
  --email admin@yourdomain.com \
  --pass 'YourStrongPassword123' \
  --ssl
```

> 💡 **Tip:** Always wrap the `--pass` value in **single quotes** (`'...'`) so symbols like `$`, `!`, `&` don't get mangled by bash.

### 🧪 Dry-run with `--help`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Sewanode/pterodactyl-installer/main/installer.sh) --help
```

---

## 🎛 CLI Arguments

| Flag | Required | Default | Description |
|------|:--------:|:-------:|-------------|
| `--domainp` | ✅ | — | Panel domain (e.g. `panel.example.com`) |
| `--domainw` | ✅ | — | Wings/Node domain (e.g. `node.example.com`) |
| `--email` | ✅ | — | Admin email + Let's Encrypt registration |
| `--pass` | ✅ | — | Admin password for the Panel |
| `--dport` | ❌ | `2481` | Wings daemon port |
| `--sftpport` | ❌ | `2482` | Wings SFTP port |
| `--timezone` | ❌ | `Asia/Jakarta` | Panel timezone |
| `--ssl` | ❌ | `false` | Enable Let's Encrypt SSL provisioning |
| `--no-id-mirror` | ❌ | `false` | Skip Indonesian APT mirror |
| `--help` | ❌ | — | Show usage |

---

## 📦 What Gets Installed

| Component | Version | Purpose |
|-----------|---------|---------|
| **PHP** | 8.3 (Sury repo) | Panel runtime |
| **MariaDB** | Latest | Panel database |
| **Nginx** | Latest | Web server + reverse proxy |
| **Redis** | Latest | Cache, session, queue |
| **Docker CE** | Latest | Container runtime for Wings |
| **Certbot** | Latest | Let's Encrypt SSL |
| **Pterodactyl Panel** | Latest | Game server control panel |
| **Wings** | Latest | Node daemon |

**Systemd services created:**

- `pteroq.service` — Panel queue worker
- `wings.service` — Wings daemon

---

## 🔒 SSL Configuration

When `--ssl` is passed, the installer:

1. Requests a certificate for **both** domains via `certbot certonly --webroot`
2. Rewrites the Nginx vhost to:
   - Redirect HTTP → HTTPS
   - Serve Panel on `https://panel.domain.com`
   - Keep `/.well-known/acme-challenge/` open for auto-renewal
3. Injects certificate paths into `/etc/pterodactyl/config.yml`
4. Adds `allowed_origins: ["https://panel.domain.com"]` so Wings accepts requests from the Panel

Certificates auto-renew via `certbot.timer` (systemd).

### Manual Renewal Test

```bash
certbot renew --dry-run
```

---

## 🛠 Post-Installation

### Access the Panel

Open: `https://panel.yourdomain.com`

Login with the email and password you passed to the installer.

### Verify Node Status

1. Log in to the Panel
2. Go to **Admin → Nodes**
3. Node should show a **green heart** within ~30 seconds

### Check Services

```bash
systemctl status wings pteroq nginx mariadb redis-server docker
```

### Test Wings Locally

```bash
curl -sk https://node.yourdomain.com:2141/api/system | jq .
```

Expected: JSON response with system info.

### Create Your First Server

1. **Admin → Servers → Create New**
2. Fill in the details, pick an egg (Minecraft, Rust, etc.)
3. Deploy — Wings handles the rest

---

## 🐛 Troubleshooting

### Node shows red in the Panel

Check Wings logs:

```bash
journalctl -u wings -n 50 --no-pager
```

Common causes:

- **Wrong scheme in Wings config** — `remote` and `api.ssl.enabled` must match your Panel scheme (https if SSL)
- **Missing `allowed_origins`** — must contain `https://panel.domain.com`
- **Certificate path wrong** — verify `/etc/letsencrypt/live/node.domain.com/` exists
- **Firewall blocking** port 2141/2142

### `yaml: unmarshal errors: cannot unmarshal !!map into []string`

This was a bug in older versions of this installer. Update to the latest version or manually edit `/etc/pterodactyl/config.yml`:

```yaml
allowed_mounts: []    # NOT: {}
allowed_origins:
  - "https://panel.domain.com"
```

### Certbot fails for node domain

Verify DNS first:

```bash
dig +short panel.yourdomain.com
dig +short node.yourdomain.com
```

Both **must** return your server's public IP.

### `Failed to restart wings.service: Unit wings.service not found`

Harmless — this is from `needrestart` running before Wings is installed. The latest installer suppresses it.

### Wings keeps restarting

```bash
# Full log dump
journalctl -u wings -b --no-pager | tail -100

# Validate config
cat /etc/pterodactyl/config.yml
```

Check that:

- All paths use forward slashes `/` (not `\/`)
- `token_id` and `token` match the Panel node entry

### Reset Wings Config

```bash
# Re-fetch from Panel API
curl -H "Authorization: Bearer <API_KEY>" \
  https://panel.yourdomain.com/api/application/nodes/1/configuration \
  | jq . > /etc/pterodactyl/config.json
```

---

## 📁 File Locations

| Path | Purpose |
|------|---------|
| `/var/www/pterodactyl/` | Panel installation |
| `/var/www/pterodactyl/.env` | Panel environment config |
| `/etc/pterodactyl/config.yml` | Wings daemon config |
| `/etc/nginx/sites-available/pterodactyl.conf` | Nginx vhost |
| `/etc/letsencrypt/live/panel.domain.com/` | Panel SSL cert |
| `/etc/letsencrypt/live/node.domain.com/` | Node SSL cert |
| `/var/lib/pterodactyl/volumes/` | Server data storage |
| `/var/log/letsencrypt/` | Certbot logs |
| `/usr/local/bin/wings` | Wings binary |

---

## 🗑 Uninstall

> ⚠️ This will **delete all game server data**.

```bash
# Stop services
systemctl disable --now wings pteroq nginx mariadb redis-server docker

# Remove Panel
rm -rf /var/www/pterodactyl
rm -f /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/systemd/system/wings.service
rm -f /etc/systemd/system/pteroq.service

# Remove Wings data
rm -rf /etc/pterodactyl /var/lib/pterodactyl /var/log/pterodactyl
rm -f /usr/local/bin/wings

# Remove database
mariadb -u root -e "DROP DATABASE panel; DROP USER 'pterodactyl'@'127.0.0.1';"

# Reload systemd
systemctl daemon-reload
```

---

## 📜 License

MIT License — free to use, modify, and distribute.

```
Copyright (c) 2026 Sewanode

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
```

---

## 🙌 Credits

- **Author:** [Sewanode](https://github.com/Sewanode)
- **Original Panel:** [Pterodactyl](https://pterodactyl.io) by Dane Everitt & contributors
- **Wings:** [pterodactyl/wings](https://github.com/pterodactyl/wings)
- **Certbot:** [Let's Encrypt](https://letsencrypt.org)
- **Docker:** [Docker Inc.](https://docker.com)

---

## ⭐ Contributing

Pull requests are welcome! If you find a bug or want to add a feature:

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing`)
3. Commit your changes
4. Push and open a PR

---

## 💬 Support

- 🐛 **Bug reports:** [Open an issue](https://github.com/Sewanode/pterodactyl-installer/issues)
- 💡 **Feature requests:** [Start a discussion](https://github.com/Sewanode/pterodactyl-installer/discussions)

---

<p align="center">
  <strong>Made with ❤️ by <a href="https://github.com/Sewanode">Sewanode</a></strong><br>
  <em>If this saved you time, consider giving it a ⭐</em>
</p>
