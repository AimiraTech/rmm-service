# RMM Service — Dockerized RustDesk Server

A production-hardened Docker Compose deployment of [RustDesk Server OSS](https://github.com/rustdesk/rustdesk-server) for self-hosted remote access infrastructure. Designed for sysadmins managing a fleet of endpoints who need a secure, recoverable, operationally simple setup.

This repo provides automated TLS via Caddy, intrusion detection via CrowdSec, atomic backup/restore scripts, and a Makefile operational interface — all configured to deploy with a single `make up-d`.

---

## Prerequisites

- **Docker Engine 24+** with Docker Compose v2 (`docker compose` subcommand)
- **Linux host** — `network_mode: host` is required for UDP hole-punch and real client IPs
- **DNS A record** pointing your `DOMAIN` to the server's public IP
- **Open firewall ports:**

| Port  | Protocol | Purpose                                     |
|-------|----------|---------------------------------------------|
| 80    | TCP      | Caddy ACME challenge / HTTP→HTTPS redirect  |
| 443   | TCP      | HTTPS                                       |
| 21115 | TCP      | hbbs — NAT type test                        |
| 21116 | TCP+UDP  | hbbs — peer registration (MUST be both!)    |
| 21117 | TCP      | hbbr — relay traffic                        |
| 21443 | TCP      | Caddy TLS WebSocket for hbbs                |
| 21444 | TCP      | Caddy TLS WebSocket for hbbr                |

---

## Quick Start

```sh
# 1. Configure environment
cp .env.example .env
# Edit .env and fill in: DOMAIN, RELAY_HOST, TLS_EMAIL

# 2. Start all services
make up-d

# 3. Verify all services are healthy
make status

# 4. First run: extract auto-generated keys to secrets/
make keys-extract

# 5. Get public key to configure clients
make keys-show
```

On first startup, `rustdesk-server-s6` generates an Ed25519 keypair in `./data/`. Run `make keys-extract` to copy those keys to `secrets/` so they persist across container recreations. **Back up the keys immediately after step 4** — key loss requires reconfiguring every client in your fleet.

---

## Architecture

```
                    Internet
                       │
          ┌────────────┼────────────┐
          │            │            │
     TCP/UDP 21115-21117    TCP 21443/21444 (WSS via Caddy)
          │            │            │
          │            │         ┌──▼──┐
          │            │         │Caddy│ ← auto TLS (ACME)
          │            │         └──┬──┘
          │            │            │
     ┌────▼────────────▼────────────▼────┐
     │  rustdesk-server-s6:1.1.15        │  network_mode: host
     │  ┌─────────┐  ┌─────────┐         │
     │  │  hbbs   │  │  hbbr   │         │
     │  │(ID/NAT) │  │(relay)  │         │
     │  └─────────┘  └─────────┘         │
     │       ENCRYPTED_ONLY=1            │
     └──────────────┬────────────────────┘
                    │ auth logs
              ┌─────▼─────┐
              │ CrowdSec  │ ← parses auth failures
              └─────┬─────┘
              ┌─────▼─────┐
              │  Bouncer   │ ← enforces IP bans
              └───────────┘
```

### Services

- **rustdesk** — `rustdesk/rustdesk-server-s6:1.1.15` on host network. Runs both `hbbs` (ID/rendezvous server) and `hbbr` (relay server) via s6-overlay. Binds ports 21115–21117 directly on the host. `ENCRYPTED_ONLY=1` is non-negotiable — unencrypted connections are rejected.

- **caddy** — `caddy:2-alpine` on host network. Provides TLS termination for WebSocket traffic on ports 21443 (hbbs WS) and 21444 (hbbr WS), proxying to rustdesk's plain WebSocket ports 21118/21119 on localhost. Manages TLS certificates automatically via Let's Encrypt ACME.

- **crowdsec** — `crowdsecurity/crowdsec:latest` on bridge network. Reads rustdesk container logs via Docker socket, parses auth failure lines with a custom YAML parser, and triggers ban decisions on repeated failures.

- **bouncer** — `crowdsecurity/cs-firewall-bouncer:latest` on host network with `NET_ADMIN`/`NET_RAW` capabilities. Enforces CrowdSec ban decisions at the iptables/nftables level — banned IPs cannot reach any port on the host.

---

## Port Reference

| Port  | Protocol | Service     | Route                          | Firewall |
|-------|----------|-------------|--------------------------------|----------|
| 80    | TCP      | Caddy       | ACME challenge / HTTP redirect | Open     |
| 443   | TCP      | Caddy       | HTTPS                          | Open     |
| 21115 | TCP      | hbbs        | Direct — NAT type test         | Open     |
| 21116 | TCP+UDP  | hbbs        | Direct — peer registration     | Open     |
| 21117 | TCP      | hbbr        | Direct — relay traffic         | Open     |
| 21443 | TCP      | Caddy→hbbs  | TLS WebSocket (via Caddy)      | Open     |
| 21444 | TCP      | Caddy→hbbr  | TLS WebSocket (via Caddy)      | Open     |

Ports 21118 and 21119 are rustdesk's plain WebSocket ports — they are NOT exposed externally. Caddy listens on 21443/21444 and proxies to them on localhost.

---

## Client Configuration

In the RustDesk client:

1. Go to **Settings → Network**
2. Set **ID Server**: `<DOMAIN>:21443`
3. Set **Relay Server**: `<DOMAIN>:21444`
4. Set **Key**: paste the output of `make keys-show`

For single-server deployments, `DOMAIN` and `RELAY_HOST` are the same hostname. Both ID and relay server addresses point to the same host.

---

## CrowdSec Setup

CrowdSec starts without a bouncer key. After the first `make up-d`, generate the key and activate the bouncer:

```sh
# 1. Generate bouncer API key
docker compose exec crowdsec cscli bouncers add rmm-bouncer

# 2. Copy the generated key into .env
# Edit .env and set: CROWDSEC_BOUNCER_KEY=<key>

# 3. Restart to activate
make down && make up-d
```

Verify CrowdSec is active:

```sh
docker compose exec crowdsec cscli metrics
docker compose exec crowdsec cscli decisions list
```

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

### TLS certificate not issued

Caddy uses ACME (Let's Encrypt) to issue certificates. Requirements:
1. `DOMAIN` must resolve to the server's public IP (verify with `dig +short $DOMAIN`)
2. Ports 80 and 443 must be open from the internet (ACME HTTP-01 challenge)
3. `TLS_EMAIL` must be set in `.env`

Check Caddy logs: `docker compose logs caddy`

### CrowdSec blocking legitimate IPs

Review current bans:

```sh
docker compose exec crowdsec cscli decisions list
```

Remove a specific ban:

```sh
docker compose exec crowdsec cscli decisions delete --ip <ip-address>
```

---

## Security Hardening Checklist

- [ ] `ENCRYPTED_ONLY=1` is set — enforced in `docker-compose.yml`, never remove this
- [ ] Keys are in `secrets/` and excluded by `.gitignore` — never commit keys
- [ ] `.env` is excluded by `.gitignore` — never commit credentials
- [ ] Firewall restricts ports to the 7 listed in the Port Reference table
- [ ] CrowdSec bouncer is running: `make status` shows bouncer healthy
- [ ] `CROWDSEC_BOUNCER_KEY` is set in `.env` after initial setup
- [ ] Image tags are pinned: `s6:1.1.15` (not `latest`)
- [ ] Backups are running: `make backup` in cron, archives copied offsite
- [ ] Docker socket is mounted read-only: `:ro` on CrowdSec volume mount

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
