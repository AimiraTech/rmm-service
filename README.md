# RMM Service — MeshCentral Deployment

A production-ready Docker Compose deployment of [MeshCentral](https://github.com/Ylianst/MeshCentral) for self-hosted remote monitoring and management. Single-container setup with TLS offloaded to Apache/Virtualmin, named volumes for persistent storage, and a Makefile operational interface.

---

## Prerequisites

- **Docker Engine 24+** with Docker Compose v2 (`docker compose` subcommand)
- **Linux host** with Apache and the following modules enabled:
  - `mod_proxy`
  - `mod_proxy_http`
  - `mod_proxy_wstunnel`
  - `mod_rewrite`
  - `mod_headers`
  - `mod_ssl`
- **DNS A record** pointing your hostname (e.g. `rmm.aimiratech.com`) to the server's public IP
- **TLS certificate** managed by Virtualmin/Let's Encrypt for the hostname

---

## Quick Start

```sh
# 1. Create directory and copy deploy scripts
mkdir -p /home/aimiratech/rmm-service
cd /home/aimiratech/rmm-service
git clone --filter=blob:none --sparse git@github.com:AimiraTech/rmm-service.git .
git sparse-checkout set deploy/

# 2. Run setup (pulls config image, extracts all configs, initializes .env)
./deploy/setup.sh

# 3. Configure
nano .env   # Set MESHCENTRAL_HOSTNAME to your actual domain

# 4. Configure Apache VirtualHost (see section below)

# 5. Start MeshCentral
make up-d

# 6. Wait ~60s for startup, verify health
make status

# 7. Create initial admin account
make admin-create

# 8. First backup
make backup
```

`setup.sh` pulls the config image from GHCR, extracts all files (docker-compose.yml, Makefile, scripts/, config/, etc.) into the install directory, and generates a random `MESHCENTRAL_SESSION_KEY`. Only `deploy/` needs to exist beforehand.

---

## Apache VirtualHost Configuration

Enable required modules first:

```sh
a2enmod proxy proxy_http proxy_wstunnel rewrite headers ssl
systemctl reload apache2
```

Create `/etc/apache2/sites-available/rmm.aimiratech.com.conf` (or configure via Virtualmin):

```apache
<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName rmm.aimiratech.com

    ProxyRequests Off
    ProxyPreserveHost On

    # ACME challenge must NOT be proxied
    ProxyPass /.well-known/acme-challenge/ !

    RequestHeader setifempty X-Forwarded-Proto https
    RequestHeader setifempty X-Forwarded-Host rmm.aimiratech.com

    # WebSocket rewrite (required for agent connections)
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} websocket [NC]
    RewriteCond %{HTTP:Connection} upgrade [NC]
    RewriteRule .* "ws://127.0.0.1:4430%{REQUEST_URI}" [P,L]

    ProxyPass / http://127.0.0.1:4430/
    ProxyPassReverse / http://127.0.0.1:4430/

    ProxyTimeout 600

    SSLEngine On
    SSLCertificateFile /path/to/fullchain.pem
    SSLCertificateKeyFile /path/to/privkey.pem
</VirtualHost>
</IfModule>
```

Replace `/path/to/fullchain.pem` and `/path/to/privkey.pem` with the actual certificate paths managed by Virtualmin/Let's Encrypt (typically under `/etc/letsencrypt/live/<domain>/`).

---

## Agent Deployment

### Windows Agent

1. Log in to `https://rmm.aimiratech.com` as admin.
2. Navigate to **My Meshes** → select your mesh → **Add Agent**.
3. Download the Windows agent installer.
4. Run the installer on target machines — it connects to `wss://rmm.aimiratech.com:443` automatically.

The agent uses the standard HTTPS port (443) for all communication, making it transparent to most corporate firewalls.

---

## Backup & Restore

### Backup

```sh
make backup
```

Creates a timestamped archive in `BACKUP_DIR` (default: `/home/aimiratech/rmm-service/backups`) containing the `meshcentral-data` and `meshcentral-files` named volumes. The MeshCentral container does NOT need to be running.

Archives older than `BACKUP_RETENTION_DAYS` (default: 30) are pruned automatically.

### Restore

```sh
make restore FILE=/home/aimiratech/rmm-service/backups/rmm-backup-20260525-143022.tar.gz
```

The script validates archive integrity, stops the `meshcentral` container, extracts volume contents, and exits without restarting. Run `make up-d` after restore.

### Automated Backups via Cron

```sh
# Add to crontab: backup at 03:00 daily
0 3 * * * /home/aimiratech/rmm-service/deploy/backup-cron.sh >> /var/log/rmm-backup.log 2>&1
```

---

## Update Process

```sh
cd /home/aimiratech/rmm-service
./deploy/update.sh
```

The update script is idempotent — it compares the config image digest before and after pulling, extracts new configs only if changed, pulls the MeshCentral image, and only recreates the container if something actually changed. The `.env` file is never overwritten.

---

## Makefile Reference

| Target            | Description                                              |
|-------------------|----------------------------------------------------------|
| `make help`       | Show all available targets (default)                     |
| `make up`         | Start MeshCentral in foreground                          |
| `make up-d`       | Start MeshCentral in detached mode                       |
| `make down`       | Stop MeshCentral                                         |
| `make logs`       | Tail MeshCentral logs (Ctrl+C to stop)                   |
| `make status`     | Show container status and health                         |
| `make backup`     | Create backup archive of named volumes                   |
| `make restore`    | Restore from archive: `make restore FILE=<archive>`      |
| `make update`     | Pull new images and recreate via deploy/update.sh        |
| `make admin-create` | Instructions to create the initial admin account       |
