# RMM Service — Dockerized RustDesk Server

A production-hardened Docker Compose deployment of [RustDesk Server OSS](https://github.com/rustdesk/rustdesk-server) for self-hosted remote access infrastructure. Designed for sysadmins managing a fleet of endpoints who need a secure, recoverable, operationally simple setup.

This repo provides atomic backup/restore scripts and a Makefile operational interface — configured to deploy with a single `make up-d`.

---

## Prerequisites

- **Docker Engine 24+** with Docker Compose v2 (`docker compose` subcommand)
- **Linux host** — `network_mode: host` is required for UDP hole-punch and real client IPs
- **DNS A record** pointing your `DOMAIN` to the server's public IP
- **Open firewall ports:**

| Port  | Protocol | Purpose                                     |
|-------|----------|---------------------------------------------|
| 21115 | TCP      | hbbs — NAT type test                        |
| 21116 | TCP+UDP  | hbbs — peer registration (MUST be both!)    |
| 21117 | TCP      | hbbr — relay traffic                        |

---

## Deploy to EC2 (or any Linux VPS)

```sh
# 1. Create directory and copy deploy scripts
mkdir -p /home/aimiratech/rmm-service
cd /home/aimiratech/rmm-service
git clone --filter=blob:none --sparse git@github.com:AimiraTech/rmm-service.git .
git sparse-checkout set deploy/

# 2. Run setup (installs Docker, pulls config image, extracts all configs, initializes .env)
./deploy/setup.sh

# 3. Configure
nano .env   # Fill in: DOMAIN, RELAY_HOST

# 4. Start all services
make up-d

# 5. Wait ~15s, verify everything is healthy
make status

# 6. First backup — BEFORE giving access to anyone
make backup

# 7. Get public key for client configuration
make keys-show
```

`setup.sh` pulls the config image from GHCR and extracts all files (docker-compose.yml, Makefile, scripts, etc.) into the install directory. Only `deploy/` needs to exist beforehand.

---

## Updating

```sh
cd /home/aimiratech/rmm-service
./deploy/update.sh
```

The update script is idempotent — it pulls the latest config image, extracts new configs only if the image changed, pulls service images, and only recreates containers if something actually changed. Runtime data (`.env`, `data/`, `secrets/`) is never overwritten.

**AWS Security Group inbound rules:**

| Port  | Protocol | Source    | Purpose                        |
|-------|----------|-----------|--------------------------------|
| 22    | TCP      | Your IP   | SSH access                     |
| 21115 | TCP      | 0.0.0.0/0 | NAT type test                  |
| 21116 | TCP      | 0.0.0.0/0 | Peer registration              |
| 21116 | UDP      | 0.0.0.0/0 | Peer registration (hole-punch) |
| 21117 | TCP      | 0.0.0.0/0 | Relay traffic                  |

`setup.sh` auto-generates Ed25519 keys on first install and writes them to `secrets/`. **Back up the keys immediately** — key loss requires reconfiguring every client in your fleet.

---

## Quick Start (non-EC2)

For any Linux host with Docker already installed:

```sh
git clone git@github.com:AimiraTech/rmm-service.git
cd rmm-service
cp .env.example .env
# Edit .env: DOMAIN, RELAY_HOST
make up-d
make status
make keys-extract
make keys-show
```

---

## Architecture

```
                    Internet
                       │
          TCP/UDP 21115-21117
                       │
     ┌─────────────────▼─────────────────┐
     │  rustdesk-server-s6:1.1.15        │  network_mode: host
     │  ┌─────────┐  ┌─────────┐         │
     │  │  hbbs   │  │  hbbr   │         │
     │  │(ID/NAT) │  │(relay)  │         │
     │  └─────────┘  └─────────┘         │
     │       ENCRYPTED_ONLY=1            │
     └───────────────────────────────────┘
```

### Services

- **rustdesk** — `rustdesk/rustdesk-server-s6:1.1.15` on host network. Runs both `hbbs` (ID/rendezvous server) and `hbbr` (relay server) via s6-overlay. Binds ports 21115–21117 directly on the host. `ENCRYPTED_ONLY=1` is non-negotiable — unencrypted connections are rejected.

---

## Port Reference

| Port  | Protocol | Service  | Purpose                    | Firewall |
|-------|----------|----------|----------------------------|----------|
| 21115 | TCP      | hbbs     | NAT type test              | Open     |
| 21116 | TCP+UDP  | hbbs     | Peer registration          | Open     |
| 21117 | TCP      | hbbr     | Relay traffic              | Open     |

---

## Client Configuration

In the RustDesk client:

1. Go to **Settings → Network**
2. Set **ID Server**: `<DOMAIN>:21116`
3. Set **Relay Server**: `<DOMAIN>:21117`
4. Set **Key**: paste the output of `make keys-show`

For single-server deployments, `DOMAIN` and `RELAY_HOST` are the same hostname. Both ID and relay server addresses point to the same host.

---

## Backup & Restore

### Backup

```sh
make backup
```

Creates a timestamped archive in `BACKUP_DIR` (default: `/var/backups/rmm`) containing:
- `id_ed25519` — Ed25519 private key
- `id_ed25519.pub` — Ed25519 public key
- `db_v2.sqlite3` — RustDesk peer database
- `db_v2.sqlite3-wal` / `db_v2.sqlite3-shm` — SQLite WAL files (if present)

Archives older than `BACKUP_RETENTION_DAYS` (default: 30) are pruned automatically.

**Back up keys before first production deployment.** Key loss requires reconfiguring every managed endpoint.

### Restore

```sh
make restore FILE=/var/backups/rmm/rmm-backup-20260525-143022.tar.gz
```

The script stops `rustdesk`, validates the archive, extracts keys to `secrets/`, and data to `data/`. It does NOT auto-start services.

```sh
# After restore:
make up-d
```

---

## Troubleshooting

### Port 21116 must be BOTH TCP AND UDP

The most common misconfiguration. RustDesk uses 21116/UDP for peer registration (UDP hole-punch). Opening only TCP will cause connection failures for NAT traversal. Open both:

```
ufw allow 21116/tcp
ufw allow 21116/udp
```

### Hairpin NAT (LAN clients + server on same network)

Clients on the same LAN as the server may fail to connect via the public hostname due to hairpin NAT limitations. Workaround: configure LAN clients to use the server's private IP directly, or configure split DNS so the domain resolves to the private IP from inside the LAN.

### Key mismatch

Clients configured with the wrong or an old public key will be rejected with a key verification error. Verify the current public key:

```sh
make keys-show
```

Reconfigure all clients with the key shown. If you restored from backup, the key shown is the restored key.

---

## Security Hardening Checklist

- [ ] `ENCRYPTED_ONLY=1` is set — enforced in `docker-compose.yml`, never remove this
- [ ] Keys are in `secrets/` and excluded by `.gitignore` — never commit keys
- [ ] `.env` is excluded by `.gitignore` — never commit credentials
- [ ] Firewall restricts ports to the 3 listed in the Port Reference table
- [ ] Image tags are pinned: `s6:1.1.15` (not `latest`)
- [ ] Backups are running: `make backup` in cron, archives copied offsite

---

## Makefile Reference

| Target          | Description                                          |
|-----------------|------------------------------------------------------|
| `make help`     | Show all available targets (default)                 |
| `make up`       | Start all services in foreground                     |
| `make up-d`     | Start all services in detached mode                  |
| `make down`     | Stop all services                                    |
| `make logs`     | Tail all service logs                                |
| `make status`   | Show service health, ports, and public key           |
| `make backup`   | Create backup archive of keys and database           |
| `make restore`  | Restore from archive: `make restore FILE=<archive>`  |
| `make update`   | Pull new images and recreate (backup runs first)     |
| `make keys-extract` | Copy auto-generated keys from data/ to secrets/ |
| `make keys-show`    | Display public key for client configuration      |
| `make keys-generate`| Generate new keypair (destructive — all clients must be reconfigured) |
