# SDD Specification: rmm-service — Dockerized RustDesk Server

**topic_key:** `sdd/rmm-service/spec`  
**type:** architecture  
**date:** 2026-05-25  
**based_on:** proposal (Approach C — Production-Hardened Stack)

---

## Overview

This document specifies every deliverable at the level of detail required for implementation without ambiguity. Each section defines exact configuration, variable names, expected behavior, and constraints.

---

## 1. `docker-compose.yml`

### Top-level structure

```yaml
version: "3.9"

secrets:
  key_pub:
    file: ./secrets/id_ed25519.pub
  key_priv:
    file: ./secrets/id_ed25519

volumes:
  rustdesk-data:
  caddy-data:
  caddy-config:
  crowdsec-data:

services:
  rustdesk: ...
  caddy: ...
  crowdsec: ...
  bouncer: ...
```

### Service: `rustdesk`

```yaml
rustdesk:
  image: rustdesk/rustdesk-server-s6:${RUSTDESK_IMAGE_TAG:-1.1.15}
  container_name: rustdesk
  network_mode: host
  environment:
    RELAY: "${RELAY_HOST}"
    ENCRYPTED_ONLY: "1"
    RUST_LOG: "${RUST_LOG:-info}"
  volumes:
    - rustdesk-data:/data
  secrets:
    - key_pub
    - key_priv
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "s6-svstat", "/var/run/s6/legacy-services/hbbs"]
    interval: 30s
    timeout: 10s
    retries: 3
    start_period: 15s
```

**Constraints:**
- `network_mode: host` is mandatory — bridge networking breaks UDP hole-punch on port 21116 and hides real client IPs.
- `ENCRYPTED_ONLY: "1"` must always be set to string `"1"`, not boolean. Default allows unencrypted connections; that is never acceptable for a managed fleet.
- `RELAY` must resolve to the public hostname or IP of the relay server — typically the same host as the rendezvous server.
- Secrets are mounted by S6 at `/run/secrets/key_pub` and `/run/secrets/key_priv` natively.
- Data volume mounts at `/data` — keys and SQLite database live here.

### Service: `caddy`

```yaml
caddy:
  image: caddy:2-alpine
  container_name: caddy
  ports:
    - "80:80"
    - "443:443"
    - "21118:21118"
    - "21119:21119"
  volumes:
    - caddy-data:/data
    - caddy-config:/config
    - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
  depends_on:
    - rustdesk
  restart: unless-stopped
```

**Constraints:**
- Caddy handles ONLY ports 21118 (hbbs WebSocket) and 21119 (hbbr WebSocket) plus 80/443 for ACME challenge and HTTP→HTTPS redirect.
- Caddy does NOT proxy raw TCP/UDP ports 21115, 21116, 21117 — those bind directly to the host via `network_mode: host` on the rustdesk container.
- The Caddyfile is mounted read-only.
- `caddy-data` persists auto-managed TLS certificates across restarts.
- `caddy-config` persists Caddy's internal config state.

### Service: `crowdsec`

```yaml
crowdsec:
  image: crowdsecurity/crowdsec:latest
  container_name: crowdsec
  environment:
    COLLECTIONS: "crowdsecurity/linux"
    GID: "${GID:-1000}"
  volumes:
    - crowdsec-data:/var/lib/crowdsec/data
    - ./crowdsec/acquis.yaml:/etc/crowdsec/acquis.yaml:ro
    - /var/log:/var/log:ro
    - /var/run/docker.sock:/var/run/docker.sock:ro
  restart: unless-stopped
```

**Constraints:**
- Docker socket access is required so CrowdSec can read container log streams.
- `/var/log` is mounted read-only for host log access.
- The `acquis.yaml` is mounted read-only.
- `crowdsec-data` persists ban decisions and threat intelligence state.

### Service: `bouncer`

```yaml
bouncer:
  image: crowdsecurity/cs-firewall-bouncer:latest
  container_name: bouncer
  environment:
    CROWDSEC_LAPI_URL: "http://crowdsec:8080"
    CROWDSEC_LAPI_KEY: "${CROWDSEC_BOUNCER_KEY}"
  cap_add:
    - NET_ADMIN
    - NET_RAW
  network_mode: host
  depends_on:
    - crowdsec
  restart: unless-stopped
```

**Constraints:**
- `NET_ADMIN` and `NET_RAW` capabilities are required for iptables/nftables firewall rule management.
- `network_mode: host` is required so the bouncer can manipulate host firewall rules.
- `CROWDSEC_LAPI_KEY` must be pre-generated via `cscli bouncers add` and stored in `.env`.
- The bouncer depends on CrowdSec being running but does NOT depend on rustdesk.

---

## 2. `docker-compose.override.yml`

```yaml
version: "3.9"

services:
  rustdesk:
    environment:
      RUST_LOG: debug

  caddy:
    volumes:
      - ./caddy/Caddyfile.dev:/etc/caddy/Caddyfile:ro
    ports:
      - "8080:80"
      - "8443:443"
      - "21118:21118"
      - "21119:21119"
```

**Constraints:**
- Override sets `RUST_LOG: debug` for development — must NOT be set in production compose.
- Dev Caddyfile (`Caddyfile.dev`) uses self-signed TLS or `tls internal` instead of ACME — no domain required locally.
- Port overrides (8080/8443) avoid conflicts with existing local services.
- Raw ports 21118 and 21119 remain unchanged — client connectivity testing still works locally.

---

## 3. `.env.example`

Every variable must appear with a default value and an inline comment explaining its purpose and whether it is required.

```bash
# =============================================================================
# RMM Service — Environment Configuration
# Copy to .env and fill in required values before first deploy.
# =============================================================================

# REQUIRED: Public hostname or IP for your server.
# Used by Caddy for TLS certificate generation (ACME) and by clients.
# Must be a real DNS name for production TLS to work.
DOMAIN=rmm.example.com

# REQUIRED: Hostname or IP that clients use to reach the relay server.
# For a single-server setup this is the same as DOMAIN.
# For split hbbs/hbbr deployments, set to the relay server's address.
RELAY_HOST=rmm.example.com

# OPTIONAL: RustDesk server image tag. Do not change without reading the changelog.
# Changing this may require re-testing the CrowdSec parser against new log formats.
RUSTDESK_IMAGE_TAG=1.1.15

# OPTIONAL: Log verbosity for the rustdesk-server-s6 container.
# Valid values: error, warn, info, debug, trace
# Production: info. Development: debug.
RUST_LOG=info

# OPTIONAL: Absolute path on the host where backup archives are written.
# Directory will be created if it does not exist.
BACKUP_DIR=/var/backups/rmm

# OPTIONAL: Number of days to retain backup archives.
# Backups older than this are deleted by backup.sh automatically.
BACKUP_RETENTION_DAYS=30

# REQUIRED (after first CrowdSec setup): API key for the firewall bouncer.
# Generate with: docker compose exec crowdsec cscli bouncers add bouncer-firewall
# Leave empty on first run; add after CrowdSec initializes.
CROWDSEC_BOUNCER_KEY=

# OPTIONAL: Group ID for CrowdSec container to match host log ownership.
GID=1000
```

---

## 4. `Makefile`

### General rules

- POSIX sh compatible — no bashisms (`[[`, `$((...))`, `local`, etc.).
- Default target is `help`.
- Color output uses ANSI codes with a NO_COLOR fallback.
- Each target prints a short status message before executing.
- Errors abort the recipe (`set -e` equivalent per target via `||` chaining or explicit checks).

### Target specifications

#### `help` (default)

Prints a formatted list of all targets with descriptions. Must read descriptions from `##` comments in the Makefile itself (self-documenting pattern). Example output:

```
RMM Service — available targets:
  up           Start all services in foreground
  up-d         Start all services in detached mode
  down         Stop all services
  logs         Tail all service logs
  status       Show service health and port bindings
  backup       Backup keys and database
  restore      Restore from a backup archive
  update       Pull new images, backup, recreate
  keys-show    Display public key for client config
  keys-generate Generate new keypair (DESTRUCTIVE)
```

#### `up`

```makefile
up: ## Start all services in foreground
	docker compose up
```

#### `up-d`

```makefile
up-d: ## Start all services in detached mode
	docker compose up -d
	@echo "Services started. Run 'make status' to verify."
```

#### `down`

```makefile
down: ## Stop all services
	docker compose down
```

#### `logs`

```makefile
logs: ## Tail all service logs (Ctrl+C to stop)
	docker compose logs -f
```

#### `status`

```makefile
status: ## Show service health and port bindings
	@echo "=== Service Status ==="
	@docker compose ps
	@echo ""
	@echo "=== Port Bindings ==="
	@ss -tlnpu | grep -E '(21115|21116|21117|21118|21119|80|443)' || true
	@echo ""
	@echo "=== Public Key ==="
	@cat secrets/id_ed25519.pub 2>/dev/null || echo "(key not yet generated)"
```

#### `backup`

```makefile
backup: ## Backup keys and database to BACKUP_DIR
	@./scripts/backup.sh
```

#### `restore`

```makefile
restore: ## Restore from archive: make restore FILE=backup.tar.gz
	@test -n "$(FILE)" || (echo "Usage: make restore FILE=<archive>"; exit 1)
	@./scripts/restore.sh "$(FILE)"
```

#### `update`

```makefile
update: backup ## Pull new images, backup, recreate containers (backup runs first)
	@echo "=== Pulling new images ==="
	@docker compose pull
	@echo "=== Recreating containers ==="
	@docker compose up -d --force-recreate
	@echo "=== Update complete ==="
	@$(MAKE) status
```

Note: `update` depends on `backup` — it will not proceed if backup fails.

#### `keys-show`

```makefile
keys-show: ## Display public key for client configuration
	@echo "=== RustDesk Server Public Key ==="
	@cat secrets/id_ed25519.pub 2>/dev/null || \
		docker compose exec rustdesk cat /data/id_ed25519.pub 2>/dev/null || \
		echo "Key not found. Run 'make up-d' first."
```

#### `keys-generate`

```makefile
keys-generate: ## Generate new keypair — WARNING: all clients must be reconfigured
	@echo "WARNING: This will replace existing keys. All clients must be reconfigured."
	@echo "Press Ctrl+C within 5 seconds to cancel..."
	@sleep 5
	@mkdir -p secrets
	@docker run --rm -v $(PWD)/secrets:/out \
		rustdesk/rustdesk-server-s6:$(RUSTDESK_IMAGE_TAG) \
		sh -c "hbbs --genkey && cp /data/id_ed25519* /out/"
	@echo "Keys generated in ./secrets/"
```

---

## 5. `caddy/Caddyfile`

```caddyfile
{
    # Global options
    email {$ACME_EMAIL:admin@example.com}
}

# HTTP redirect to HTTPS
http://{$DOMAIN} {
    redir https://{$DOMAIN}{uri} permanent
}

# hbbs WebSocket (RustDesk ID/Rendezvous server)
{$DOMAIN}:21118 {
    tls {
        # Automatic certificate via ACME (Let's Encrypt)
    }

    reverse_proxy localhost:21118 {
        header_up Upgrade {http.request.header.Upgrade}
        header_up Connection {http.request.header.Connection}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        transport http {
            read_timeout  600s
            write_timeout 600s
        }
    }
}

# hbbr WebSocket (RustDesk Relay server)
{$DOMAIN}:21119 {
    tls {
        # Automatic certificate via ACME (Let's Encrypt)
    }

    reverse_proxy localhost:21119 {
        header_up Upgrade {http.request.header.Upgrade}
        header_up Connection {http.request.header.Connection}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        transport http {
            read_timeout  600s
            write_timeout 600s
        }
    }
}
```

**Constraints:**
- `read_timeout` and `write_timeout` are set to 600 seconds (10 minutes) to accommodate long-lived WebSocket sessions. Default Caddy timeouts (60s) will terminate active remote sessions.
- `DOMAIN` is injected via Caddy's environment variable interpolation (`{$DOMAIN}`).
- `ACME_EMAIL` is optional but recommended for Let's Encrypt expiry notifications.
- Caddy proxies ONLY 21118 and 21119. Ports 21115, 21116, 21117 are NOT referenced in this file.
- `localhost:21118` and `localhost:21119` are reachable because rustdesk runs `network_mode: host` and binds to all interfaces on the host.
- For `Caddyfile.dev` (development override), replace `tls { ... }` with `tls internal` to use Caddy's self-signed certificate authority without a domain.

---

## 6. `crowdsec/acquis.yaml`

```yaml
---
# Acquire rustdesk authentication logs from Docker container stdout/stderr
source: docker
container_name:
  - rustdesk
labels:
  type: rustdesk
```

**Constraints:**
- `source: docker` uses the Docker socket to read container log streams directly. Requires the Docker socket mount in the crowdsec service.
- `container_name` must match the `container_name` field in the `rustdesk` compose service definition exactly.
- `labels.type: rustdesk` is the parser type identifier. The CrowdSec parser must be named `crowdsecurity/rustdesk` or a custom local parser at `crowdsec/parsers/s01-parse/rustdesk-logs.yaml`.
- If a community parser for RustDesk is not yet available in the CrowdSec Hub at implementation time, a custom parser must be created that matches the auth failure log format from rustdesk-server-s6 v1.1.15.

### Expected log format (v1.1.15)

Auth failure log lines from `hbbs` follow the pattern:

```
[YYYY-MM-DDTHH:MM:SS] WARN  Failed login attempt from IP: <ip_address>
```

The custom parser must extract the IP address and map to a `evt.Meta.source_ip` field that CrowdSec uses for ban decisions.

### `crowdsec/parsers/s01-parse/rustdesk-logs.yaml` (if custom parser required)

```yaml
filter: "evt.Line.Labels.type == 'rustdesk'"
name: crowdsecurity/rustdesk
description: "Parse RustDesk authentication failures"
nodes:
  - grok:
      pattern: '%{TIMESTAMP_ISO8601:timestamp} %{LOGLEVEL:level}\s+Failed login attempt from IP: %{IP:source_ip}'
      apply_on: evt.Line.Raw
    statics:
      - meta: source_ip
        expression: evt.Parsed.source_ip
      - meta: log_type
        value: "rustdesk_auth_fail"
      - target: evt.StrTime
        expression: evt.Parsed.timestamp
```

---

## 7. `scripts/backup.sh`

### Behavior specification

1. Load configuration from environment: `BACKUP_DIR` (default: `/var/backups/rmm`), `BACKUP_RETENTION_DAYS` (default: `30`).
2. Create `BACKUP_DIR` if it does not exist.
3. Create a temporary working directory inside `BACKUP_DIR` using `mktemp -d`.
4. Define the data source as the Docker volume mount path. Since the volume is named `rustdesk-data` and mounts at `/data` inside the container, the script must access the files via `docker compose exec rustdesk` or via the volume's host path. Use `docker compose cp rustdesk:/data/. <tmpdir>/` for portability.
5. Copy the following files atomically into the temp directory:
   - `id_ed25519`
   - `id_ed25519.pub`
   - `db_v2.sqlite3`
   - `db_v2.sqlite3-wal` (may not exist if WAL is flushed — copy if present)
   - `db_v2.sqlite3-shm` (may not exist — copy if present)
6. Create archive: `rmm-backup-YYYYMMDD-HHMMSS.tar.gz` from the temp directory.
7. Move (not copy) the archive to `BACKUP_DIR` atomically with `mv`.
8. Remove the temp directory.
9. Delete archives older than `BACKUP_RETENTION_DAYS` using `find BACKUP_DIR -name 'rmm-backup-*.tar.gz' -mtime +N -delete`.
10. Print success message with archive path and size.
11. Exit 0 on success, exit 1 on any failure.

### Error handling

- Any command failure must cause immediate exit with code 1 and a descriptive error message to stderr.
- The temp directory must be cleaned up even on failure (trap `EXIT`).
- The script must work while the rustdesk container is running. SQLite WAL mode is safe for concurrent reads; `docker compose cp` does not lock the database.

### Script header

```sh
#!/bin/sh
set -eu

BACKUP_DIR="${BACKUP_DIR:-/var/backups/rmm}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_NAME="rmm-backup-${TIMESTAMP}.tar.gz"
TMPDIR=""

cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT
```

---

## 8. `scripts/restore.sh`

### Behavior specification

1. Accept exactly one argument: path to the backup archive. Exit 1 with usage message if not provided.
2. Verify the archive exists and is readable. Exit 1 if not.
3. Verify archive integrity: `tar -tzf <archive> > /dev/null`. Exit 1 if the archive is corrupt.
4. Verify the archive contains the expected files: `id_ed25519`, `id_ed25519.pub`, `db_v2.sqlite3`. Exit 1 if any are missing.
5. Print the current public key fingerprint for the operator to compare post-restore.
6. Stop the `rustdesk` container: `docker compose stop rustdesk`.
7. Extract archive contents to a temp directory.
8. Copy files into the container's data volume via `docker compose cp <tmpdir>/. rustdesk:/data/`.
9. Start the `rustdesk` container: `docker compose start rustdesk`.
10. Wait up to 15 seconds for rustdesk to report healthy (poll `docker inspect --format='{{.State.Health.Status}}'`).
11. Verify key consistency: read `id_ed25519.pub` from the running container and compare fingerprint to the archive's `id_ed25519.pub`. Print MATCH or MISMATCH.
12. Exit 0 on success, exit 1 on failure.

### Script header

```sh
#!/bin/sh
set -eu

ARCHIVE="${1:-}"

if [ -z "$ARCHIVE" ]; then
    echo "Usage: $0 <backup-archive.tar.gz>" >&2
    exit 1
fi
```

---

## 9. `README.md`

### Required sections (in order)

1. **Overview** — What this repo provides in 2–3 sentences. Link to RustDesk OSS upstream.
2. **Prerequisites** — Docker Engine 24+, Docker Compose v2, Linux host, open firewall ports (table below), DNS A record pointing to server IP.
3. **Quick Start** — Numbered steps:
   1. `cp .env.example .env` and fill in `DOMAIN` and `RELAY_HOST`
   2. Create `secrets/` directory and copy Ed25519 keypair or let it auto-generate on first run
   3. `make up-d`
   4. `make status` to verify all services healthy
   5. `make keys-show` to get public key for client configuration
4. **Architecture** — ASCII diagram (reproduced from proposal, see below). One-paragraph explanation of each service.
5. **Port Reference** — Full table:

| Port  | Protocol | Service     | Route                       | Firewall |
|-------|----------|-------------|-----------------------------|----------|
| 80    | TCP      | Caddy       | ACME challenge / HTTP→HTTPS | Open     |
| 443   | TCP      | Caddy       | HTTPS                       | Open     |
| 21115 | TCP      | hbbs        | Direct — NAT type test      | Open     |
| 21116 | TCP+UDP  | hbbs        | Direct — peer registration  | Open     |
| 21117 | TCP      | hbbr        | Direct — relay traffic      | Open     |
| 21118 | TCP      | hbbs WS     | Via Caddy (TLS)             | Open     |
| 21119 | TCP      | hbbr WS     | Via Caddy (TLS)             | Open     |

6. **Client Configuration** — Where to enter server settings in the RustDesk client:
   - Settings → Network → ID/Relay Server: enter `DOMAIN` value
   - Settings → Network → Key: paste contents of `id_ed25519.pub`
   - Both hbbs and hbbr addresses can be set to the same hostname for single-server deployments

7. **Backup & Restore** — `make backup`, `make restore FILE=<archive>`. Warn that keys must be backed up before first production deployment. Explain what is backed up and why (all three SQLite files, keypair).

8. **Troubleshooting** — Cover these specific cases:
   - **Port 21116 must be both TCP AND UDP** — most common misconfiguration
   - **Hairpin NAT** — clients on the same LAN as the server may fail to connect. Workaround: configure LAN clients with the server's private IP, or use split DNS.
   - **Key mismatch** — client configured with wrong or old public key will be rejected. Verify with `make keys-show`.
   - **TLS certificate not issued** — verify `DOMAIN` resolves to server IP and ports 80/443 are open. Check `make logs` for Caddy ACME errors.
   - **CrowdSec blocking legitimate IPs** — use `docker compose exec crowdsec cscli decisions list` to review, `cscli decisions delete --ip <ip>` to unban.

9. **Security Hardening** — Checklist:
   - `ENCRYPTED_ONLY=1` is set (enforced by compose)
   - Keys are in `secrets/` and not committed to version control (`.gitignore` entry required)
   - Firewall restricts ports not in the port table above
   - CrowdSec bouncer is running and `make status` shows it healthy
   - Backups are stored off-host (S3, Backblaze B2, etc.)
   - Image tags are pinned, not `latest`

---

## Acceptance Scenarios

### S1: Fresh deploy

**Precondition:** Clean Linux host with Docker Compose v2. `.env` populated with a valid `DOMAIN` and `RELAY_HOST`.

**Steps:**
1. `make up-d`

**Expected:**
- `make status` shows all four containers (rustdesk, caddy, crowdsec, bouncer) as `running` or `healthy`
- `ss -tlnpu` shows ports 21115, 21116 (TCP+UDP), 21117, 21118, 21119 bound
- `make keys-show` returns a non-empty base64 public key

**Pass criterion:** All four services running, all five ports bound, public key readable.

---

### S2: Client connection

**Precondition:** S1 passed. RustDesk client configured with server `DOMAIN` and correct public key.

**Steps:**
1. Connect RustDesk client to a registered peer

**Expected:**
- Connection established (either P2P or via relay)
- `make logs` shows hbbs registration events and relay negotiation for the client IP

**Pass criterion:** Remote control session established with no TLS or key errors.

---

### S3: Encrypted only — reject unconfigured client

**Precondition:** S1 passed. RustDesk client configured with server `DOMAIN` but NO public key set.

**Steps:**
1. Attempt connection from unconfigured client

**Expected:**
- Connection refused with key verification error
- No remote control session established

**Pass criterion:** Client receives rejection; `make logs` shows `ENCRYPTED_ONLY` enforcement log line.

---

### S4: Backup and restore cycle

**Precondition:** S1 passed. At least one peer has registered (SQLite has data).

**Steps:**
1. `make backup` — note archive filename
2. Record public key fingerprint from `make keys-show`
3. Stop containers: `make down`
4. Delete volume data: `docker volume rm rmm-service_rustdesk-data` (or equivalent)
5. `make up-d` (new keys auto-generated on fresh volume)
6. `make restore FILE=<archive-from-step-1>`
7. `make keys-show`

**Expected:**
- Public key fingerprint after restore matches fingerprint from step 2
- `make status` shows all services healthy after restore

**Pass criterion:** Fingerprint matches, services healthy.

---

### S5: CrowdSec blocks repeated auth failures

**Precondition:** S1 passed. CrowdSec and bouncer running and healthy.

**Steps:**
1. Simulate repeated failed auth attempts from a test IP (or observe organic failures in logs)
2. Wait for CrowdSec detection window (default: 5 failures in 5 minutes for most scenarios)
3. `docker compose exec crowdsec cscli decisions list`

**Expected:**
- Test IP appears in decisions list with action `ban`
- Subsequent connection attempts from that IP are dropped at the firewall level

**Pass criterion:** IP appears in `cscli decisions list` with ban action.

---

### S6: Update with zero key loss

**Precondition:** S1 passed. At least one backup exists.

**Steps:**
1. Record public key fingerprint: `make keys-show`
2. `make update`

**Expected:**
- `make update` runs backup before pulling images (visible in output)
- New images pulled and containers recreated
- `make keys-show` fingerprint after update matches fingerprint from step 1
- All services healthy after update

**Pass criterion:** Fingerprint unchanged, all services healthy.

---

### S7: WebSocket TLS connection

**Precondition:** S1 passed. DNS resolves `DOMAIN` to server IP. Ports 80 and 443 are open (ACME challenge completed).

**Steps:**
1. Configure RustDesk client to connect via WebSocket by appending `:wss` protocol to server address, or verify via web client if applicable
2. Observe connection in `make logs` for Caddy access log entries on port 21118/21119

**Expected:**
- Caddy issues TLS certificate via ACME on first connect (or certificate already present)
- WebSocket upgrade succeeds (HTTP 101)
- Remote control session established via WSS

**Pass criterion:** HTTP 101 Switching Protocols in Caddy logs, session established.

---

## Constraints Summary

| Constraint | Value |
|---|---|
| Delivery | Single PR |
| Docker Compose | v2+ required |
| OS | Linux host (host networking requirement) |
| RustDesk image | `rustdesk/rustdesk-server-s6:1.1.15` (pinned) |
| Shell compatibility | POSIX sh (no bashisms in scripts or Makefile recipes) |
| `ENCRYPTED_ONLY` | Always `"1"` — non-negotiable |
| Port 21116 | Must open BOTH TCP AND UDP |
| Secrets | Never in `.env` or compose environment — Docker secrets only for keys |
| `.gitignore` | Must exclude `secrets/`, `.env`, `*.tar.gz` |

---

## Files Excluded from Scope

Per proposal non-goals, the following are explicitly NOT delivered:

- Prometheus/Grafana monitoring stack
- IPv6 configuration
- Client deployment automation
- Custom RustDesk client builds
- Multi-node relay scaling
- RustDesk Pro integration
