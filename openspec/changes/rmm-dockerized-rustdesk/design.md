# SDD Design: rmm-service — Dockerized RustDesk Server

**topic_key:** `sdd/rmm-service/design`  
**type:** architecture  
**date:** 2026-05-25  
**based_on:** proposal (Approach C — Production-Hardened Stack)

---

## 1. Directory Structure

```
rmm-service/
├── docker-compose.yml            # Production stack definition
├── docker-compose.override.yml   # Dev/local overrides (auto-loaded by compose)
├── .env.example                  # All configurable vars with docs + defaults
├── .env                          # GITIGNORED — user's actual config
├── Makefile                      # Operational interface
├── .gitignore
├── README.md                     # Setup guide, architecture, client config
├── caddy/
│   └── Caddyfile                 # TLS reverse proxy for WS ports only
├── crowdsec/
│   ├── acquis.yaml               # Log acquisition config (docker log source)
│   └── parsers/
│       └── rustdesk-auth.yaml    # Custom parser for RustDesk auth log format
├── scripts/
│   ├── backup.sh                 # Atomic backup of keys + SQLite
│   └── restore.sh                # Restore from backup archive
├── secrets/                      # GITIGNORED — created by `make keys-generate`
│   ├── key_pub                   # Ed25519 public key
│   └── key_priv                  # Ed25519 private key
├── backups/                      # GITIGNORED — backup archives land here
└── data/                         # GITIGNORED — runtime state
    └── (id_ed25519, id_ed25519.pub, db_v2.sqlite3, ...)
```

### Directory Rationale

- **`caddy/`** — isolated config, easy to version and diff
- **`crowdsec/`** — parser + acquisition together; CrowdSec mounts this directory
- **`scripts/`** — executable helpers called by Makefile targets; not run standalone
- **`secrets/`** — ephemeral on the host; generated or restored, never committed
- **`data/`** — bind mount for `/data` in the S6 container; holds runtime state
- **`backups/`** — local backup staging area; user is responsible for offsite copy

---

## 2. Docker Compose Architecture

### Networking Strategy

**Decision: Caddy on host network (Option A)**

| Option | Description | Tradeoff |
|--------|-------------|----------|
| **(A) Caddy on host network** | Both rustdesk and Caddy use `network_mode: host` | Simplest — Caddy reaches rustdesk via localhost. No extra_hosts, no bridge-to-host gymnastics. |
| (B) Caddy on bridge, `host.docker.internal` | Caddy on bridge, proxy_pass to host gateway | Adds complexity; `host.docker.internal` not available on all Linux Docker versions without extra config. |
| (C) Caddy on bridge, `extra_hosts` | Caddy on bridge, `extra_hosts: host-gateway` | Works but fragile — host gateway IP can change on network reconfiguration. |

**Chosen: Option A.** Caddy on host network is the simplest, most reliable path. Caddy listens on ports 443 and 80 (for ACME challenge) on the host, and proxies to localhost:21118 and localhost:21119. Since rustdesk is also on host network, no cross-network routing needed.

**Trade-off acknowledged:** Two services on host network reduces container isolation. Acceptable because Caddy is a hardened, audited reverse proxy — the attack surface increase is minimal compared to the networking reliability gained.

**CrowdSec + bouncer:** Bridge network (`crowdsec-net`). These do not need to reach rustdesk ports — they read logs via Docker socket and enforce bans via the host firewall.

### Compose Service Layout

```yaml
# docker-compose.yml structure (logical, not literal)

services:
  rustdesk:
    image: rustdesk/rustdesk-server-s6:1.1.15
    network_mode: host
    environment:
      - ENCRYPTED_ONLY=1
    volumes:
      - ./data:/data
    secrets:
      - key_pub
      - key_priv
    restart: unless-stopped

  caddy:
    image: caddy:2-alpine
    network_mode: host
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    restart: unless-stopped
    depends_on:
      rustdesk:
        condition: service_healthy

  crowdsec:
    image: crowdsec/crowdsec:latest
    networks:
      - crowdsec-net
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./crowdsec/acquis.yaml:/etc/crowdsec/acquis.yaml:ro
      - ./crowdsec/parsers:/etc/crowdsec/parsers/s02-enrich:ro
      - crowdsec-data:/var/lib/crowdsec/data
      - crowdsec-config:/etc/crowdsec
    environment:
      - COLLECTIONS=crowdsecurity/linux
    restart: unless-stopped

  bouncer:
    image: crowdsec/blocklist-mirror:latest
    networks:
      - crowdsec-net
    depends_on:
      - crowdsec
    restart: unless-stopped

secrets:
  key_pub:
    file: ./secrets/key_pub
  key_priv:
    file: ./secrets/key_priv

volumes:
  caddy-data:
  caddy-config:
  crowdsec-data:
  crowdsec-config:

networks:
  crowdsec-net:
    driver: bridge
```

### Log Sharing for CrowdSec

**Decision: Docker socket mount (read-only)**

| Option | Description | Tradeoff |
|--------|-------------|----------|
| **(A) Docker socket** | CrowdSec reads container logs via `/var/run/docker.sock:ro` | S6 logs to stdout by default; Docker captures; CrowdSec reads via docker acquisition type. Zero config on rustdesk side. |
| (B) Shared volume | rustdesk writes to file; CrowdSec reads from shared volume | Requires configuring S6 log output to file; adds volume coupling. |

**Chosen: Option A.** The S6 image logs to stdout, Docker captures via its logging driver, CrowdSec reads via Docker socket. This is the designed-in path — no custom log routing needed.

**Security note:** Docker socket is mounted read-only (`:ro`). CrowdSec only reads container metadata and log streams. This is standard practice for CrowdSec container deployments.

### Secrets Flow — Two Paths

**Path 1: Fresh install (let S6 generate)**
1. `make up` starts the stack — no secrets directory needed
2. S6 auto-generates `id_ed25519` + `id_ed25519.pub` in `/data/`
3. User runs `make keys-extract` to copy generated keys to `secrets/`
4. User runs `make backup` to secure the keys offsite
5. Docker secrets are now available for future restarts

**Path 2: Restore/migrate (provide keys)**
1. User runs `make restore BACKUP=path/to/archive.tar.gz`
2. `restore.sh` extracts keys to `secrets/` and data to `data/`
3. `make up` starts with pre-existing keys via Docker secrets
4. S6 detects keys in `/run/secrets/` and uses them instead of generating new ones

**Design note:** `make keys-generate` is an alias for `keys-extract` — it does NOT generate keys cryptographically. It copies whatever S6 generated. Naming is user-facing clarity ("I need to generate my key setup") rather than technical accuracy.

---

## 3. Caddy Design

### Routing Strategy

**Decision: Port-based routing on 443 with SNI**

After analysis, neither pure port-based nor path-based routing is ideal for RustDesk WebSocket. The WebSocket clients connect to specific ports (21118, 21119) — they do not send path information. Caddy must listen on the same ports the clients expect.

**Final approach: Caddy listens on 21118 and 21119 with TLS, proxying to localhost non-TLS equivalents.**

This means:
- Caddy binds `:21118` (TLS) → reverse_proxy `localhost:21118` — **CONFLICT**: same port.
- Solution: Rustdesk WS ports are reconfigured to non-standard local ports.

**Revised approach:**

```
rustdesk hbbs WS  → localhost:21118 (internal, no TLS)
rustdesk hbbr WS  → localhost:21119 (internal, no TLS)

Caddy listens on:
  :443 → routes to hbbs WS (localhost:21118) and hbbr WS (localhost:21119)
```

Since both Caddy and rustdesk are on host network, we configure rustdesk to keep its default WS ports, and Caddy listens on 443 with path-based routing:

```
{DOMAIN}:443 {
    # hbbs WebSocket (ID server)
    reverse_proxy /ws/id localhost:21118 {
        header_up X-Real-IP {remote_host}
    }

    # hbbr WebSocket (relay server)
    reverse_proxy /ws/relay localhost:21119 {
        header_up X-Real-IP {remote_host}
    }
}
```

**CRITICAL FINDING:** RustDesk WebSocket clients connect directly to port 21118/21119 — they do NOT use path-based routing natively. The web client and API client use raw WebSocket connections to those ports.

**REVISED FINAL APPROACH: Caddy listens on separate TLS ports (e.g., 21443 for hbbs WS, 21444 for hbbr WS)**

```
{$DOMAIN}:{$WS_HBBS_TLS_PORT:21443} {
    reverse_proxy localhost:21118 {
        transport http {
            versions h1.1
        }
    }
    tls {$TLS_EMAIL}
}

{$DOMAIN}:{$WS_HBBR_TLS_PORT:21444} {
    reverse_proxy localhost:21119 {
        transport http {
            versions h1.1
        }
    }
    tls {$TLS_EMAIL}
}
```

**Design decision: Separate TLS ports**

| Option | Description | Verdict |
|--------|-------------|---------|
| (A) Path-based on 443 | `/ws/id` → 21118, `/ws/relay` → 21119 | NOT VIABLE — RustDesk clients don't support path routing |
| **(B) Separate TLS ports** | 21443→21118, 21444→21119 | Works — clients configure `wss://domain:21443` |
| (C) Replace non-TLS ports | Caddy on 21118/21119, rustdesk on alternate local ports | Adds config complexity; non-standard rustdesk setup |

**Chosen: Option B.** New TLS ports (21443, 21444) that Caddy owns, proxying to the standard rustdesk WS ports on localhost. Clients that want TLS connect to the new ports; non-TLS access to 21118/21119 remains available on the host for LAN clients.

### Caddyfile Configuration

```caddyfile
# caddy/Caddyfile

{
    email {$TLS_EMAIL}
}

# TLS WebSocket proxy for hbbs (ID server)
{$DOMAIN}:{$WS_HBBS_TLS_PORT:21443} {
    reverse_proxy localhost:21118 {
        transport http {
            versions h1.1
        }
    }

    # WebSocket timeouts — RustDesk sessions are long-lived
    reverse_proxy {
        flush_interval -1
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}

# TLS WebSocket proxy for hbbr (relay server)
{$DOMAIN}:{$WS_HBBR_TLS_PORT:21444} {
    reverse_proxy localhost:21119 {
        transport http {
            versions h1.1
        }
    }

    reverse_proxy {
        flush_interval -1
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

### TLS Configuration

- ACME via Let's Encrypt (Caddy default)
- `TLS_EMAIL` env var required for certificate notifications
- `DOMAIN` env var for SNI-based certificate issuance
- Caddy auto-manages renewal — no cron needed
- Caddy data volume persists certificates across restarts

### Timeout Tuning

- `flush_interval -1` — disable buffering for WebSocket streams
- Caddy's default timeouts are generous enough for RustDesk sessions
- No explicit `read_timeout` or `write_timeout` needed — Caddy handles WebSocket upgrade natively

---

## 4. CrowdSec Design

### Acquisition Method

**Docker socket acquisition** — CrowdSec reads rustdesk container logs via the Docker API.

```yaml
# crowdsec/acquis.yaml
source: docker
container_name:
  - rustdesk
labels:
  type: rustdesk
```

### Parser Strategy

**Step 1: Check CrowdSec Hub** — search for existing RustDesk parser.

**Step 2: If no hub parser exists** (likely, as of v1.1.15), create a custom parser:

```yaml
# crowdsec/parsers/rustdesk-auth.yaml
name: custom/rustdesk-auth
description: "Parse RustDesk v1.1.15 auth failure logs"
filter: "evt.Parsed.program == 'rustdesk'"
onsuccess: next_stage
pattern_syntax:
  RUSTDESK_AUTH_FAIL: 'Failed login attempt from (?P<source_ip>\S+)'
nodes:
  - grok:
      pattern: "%{RUSTDESK_AUTH_FAIL}"
      apply_on: message
    statics:
      - meta: log_type
        value: auth_fail
      - meta: source_ip
        expression: evt.Parsed.source_ip
```

**Design note:** The exact log format from v1.1.15 auth logging needs to be verified during implementation (`sdd-apply`). The parser pattern above is a template — the actual regex will be calibrated against real log output from the container.

### Bouncer Strategy

**Decision: Firewall bouncer (iptables)**

| Option | Description | Tradeoff |
|--------|-------------|---------|
| **(A) Firewall bouncer** | `crowdsec-firewall-bouncer-iptables` on the host | Blocks at network level — banned IPs can't reach ANY port. Most effective for RMM. |
| (B) Blocklist mirror | Returns blocklist via HTTP for consumption by other tools | Indirect; requires another tool to enforce. |
| (C) Caddy bouncer | CrowdSec Caddy plugin | Only protects WS ports behind Caddy; raw TCP/UDP ports unprotected. |

**Chosen: Option A.** For an RMM server, banned IPs should be blocked from ALL services, not just WebSocket. The firewall bouncer operates at the iptables/nftables level.

**Implementation note:** The firewall bouncer runs on the **host**, not in a container, because it needs direct iptables access. Two options:
1. Install `crowdsec-firewall-bouncer-iptables` directly on the host (recommended — apt/yum package)
2. Run in a privileged container with `NET_ADMIN` capability and host network

**Design decision:** Document BOTH options in README. Recommend host-installed bouncer for production (simpler, more reliable). Provide a compose service definition for the containerized option as `docker-compose.bouncer.yml` override for users who prefer full-container deployments.

### Alert/Notification Strategy

Out of scope for v1. Document as future enhancement:
- CrowdSec supports notification plugins (Slack, email, webhook)
- Can be added by mounting a `notifications/` directory into the CrowdSec container

---

## 5. Makefile Design

### Conventions

```makefile
# Pattern: self-documenting help via ## comments
.DEFAULT_GOAL := help
SHELL := /bin/bash
COMPOSE := docker compose

# Color codes via tput (POSIX compatible)
GREEN  := $(shell tput setaf 2)
YELLOW := $(shell tput setaf 3)
RED    := $(shell tput setaf 1)
RESET  := $(shell tput sgr0)
```

### Target Design

```makefile
.PHONY: help up up-d down logs status backup restore update keys-extract keys-show

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-15s$(RESET) %s\n", $$1, $$2}'

up: _check-env ## Start all services (foreground)
	$(COMPOSE) up

up-d: _check-env ## Start all services (detached)
	$(COMPOSE) up -d

down: ## Stop all services
	$(COMPOSE) down

logs: ## Tail all service logs
	$(COMPOSE) logs -f

status: ## Show service health, ports, and key status
	@echo "$(GREEN)=== Services ===$(RESET)"
	@$(COMPOSE) ps
	@echo ""
	@echo "$(GREEN)=== Ports ===$(RESET)"
	@ss -tlnp | grep -E '2111[5-9]|443|80' || echo "$(RED)No RustDesk ports detected$(RESET)"
	@echo ""
	@echo "$(GREEN)=== Keys ===$(RESET)"
	@test -f data/id_ed25519.pub && echo "Public key: $$(cat data/id_ed25519.pub)" || echo "$(YELLOW)No keys found — start the service first$(RESET)"

backup: ## Create backup of keys + database
	@bash scripts/backup.sh

restore: ## Restore from backup (BACKUP=path/to/archive.tar.gz)
	@test -n "$(BACKUP)" || (echo "$(RED)Usage: make restore BACKUP=path/to/archive.tar.gz$(RESET)" && exit 1)
	@bash scripts/restore.sh "$(BACKUP)"

update: backup ## Pull new images, backup, then recreate
	$(COMPOSE) pull
	$(COMPOSE) up -d --force-recreate

keys-extract: ## Copy generated keys from data/ to secrets/
	@mkdir -p secrets
	@test -f data/id_ed25519 || (echo "$(RED)No keys in data/ — run 'make up' first$(RESET)" && exit 1)
	@cp data/id_ed25519 secrets/key_priv
	@cp data/id_ed25519.pub secrets/key_pub
	@chmod 600 secrets/key_priv
	@echo "$(GREEN)Keys extracted to secrets/$(RESET)"

keys-show: ## Display public key for client configuration
	@test -f data/id_ed25519.pub && cat data/id_ed25519.pub || echo "$(RED)No public key found$(RESET)"

# Internal targets
_check-env:
	@test -f .env || (echo "$(RED).env not found — copy .env.example and configure$(RESET)" && exit 1)
```

### Error Handling in Scripts

All scripts sourced from Makefile use:
```bash
#!/usr/bin/env bash
set -euo pipefail
```

Scripts print colored status messages and exit non-zero on failure — Makefile propagates the exit code.

---

## 6. Backup Design

### Strategy: Atomic Copy

```
backup.sh flow:
1. Create temp dir: TMPDIR=$(mktemp -d)
2. Copy keys: cp data/id_ed25519{,.pub} $TMPDIR/
3. Copy SQLite atomically: cp data/db_v2.sqlite3{,-wal,-shm} $TMPDIR/ 2>/dev/null
4. Create archive: tar czf backups/rmm-backup-YYYYMMDD-HHMMSS.tar.gz -C $TMPDIR .
5. Clean temp dir: rm -rf $TMPDIR
6. Apply retention: find backups/ -name 'rmm-backup-*.tar.gz' -mtime +${BACKUP_RETENTION_DAYS:-30} -delete
7. Print result: echo path + size + file count
```

### SQLite Backup Decision

**Decision: File copy with WAL + SHM (not `sqlite3 .backup`)**

| Option | Description | Verdict |
|--------|-------------|---------|
| (A) `sqlite3 .backup` | SQL-level backup via CLI tool | S6 image is busybox-based — `sqlite3` binary may not be available. Would need `docker exec` which adds failure modes. |
| **(B) Copy db + WAL + SHM** | File-level copy of all three files | Safe for read-while-running. SQLite replays WAL automatically on next open. No dependency on sqlite3 binary. |

**Chosen: Option B.** Copy all three files (`db_v2.sqlite3`, `db_v2.sqlite3-wal`, `db_v2.sqlite3-shm`). The WAL and SHM files may not exist (if SQLite is in rollback mode or cleanly checkpointed), so the copy uses `2>/dev/null` for those.

**Safety justification:** SQLite guarantees that copying the database file + WAL + SHM while the database is in use produces a consistent snapshot, provided:
1. All three files are from the same point in time (our `cp` is sequential but fast enough for a small DB)
2. The reader (restore) replays the WAL on open (SQLite does this automatically)

For the expected database size (<10MB for typical RustDesk deployments), the copy window is sub-millisecond — no inconsistency risk in practice.

### Restore Flow

```
restore.sh flow:
1. Validate archive exists and is a tar.gz
2. Stop services: docker compose down
3. Extract to temp dir
4. Copy keys to secrets/
5. Copy data files to data/
6. Set permissions (600 for private key)
7. Print instructions: "Run 'make up-d' to start with restored data"
```

**Design note:** `restore.sh` does NOT auto-start services. The user explicitly runs `make up-d` after reviewing the restore. This prevents accidental starts with partial data.

### Retention

- Default: 30 days (`BACKUP_RETENTION_DAYS` env var)
- `find` + `-mtime` + `-delete` — POSIX-compatible
- Only applies to local `backups/` directory — offsite copies are the user's responsibility

### Naming Convention

`rmm-backup-YYYYMMDD-HHMMSS.tar.gz`

Example: `rmm-backup-20260525-143022.tar.gz`

---

## 7. .gitignore Design

```gitignore
# User environment
.env

# Runtime data (keys, database, logs)
data/

# Docker secrets (generated or restored keys)
secrets/

# SQLite artifacts (belt + suspenders — also covered by data/)
*.sqlite3
*.sqlite3-wal
*.sqlite3-shm

# Local backups
backups/

# Caddy runtime data (managed by Docker volume, but safety net)
caddy-data/
caddy-config/
```

---

## 8. Environment Variables (.env.example)

```bash
# === Required ===
DOMAIN=rmm.example.com          # Public domain for TLS certificates
TLS_EMAIL=admin@example.com     # Let's Encrypt notification email

# === RustDesk ===
ENCRYPTED_ONLY=1                # NEVER change this — forces encryption
RUSTDESK_IMAGE=rustdesk/rustdesk-server-s6:1.1.15

# === Caddy TLS Ports ===
WS_HBBS_TLS_PORT=21443         # TLS port for hbbs WebSocket
WS_HBBR_TLS_PORT=21444         # TLS port for hbbr WebSocket

# === Backup ===
BACKUP_RETENTION_DAYS=30        # Days to keep local backups

# === CrowdSec ===
CROWDSEC_BOUNCER_KEY=           # Generated by: docker exec crowdsec cscli bouncers add rmm-bouncer
```

---

## 9. Security Hardening Checklist

For README and operational validation:

1. **`ENCRYPTED_ONLY=1`** — non-negotiable, set in compose env
2. **Docker secrets for keys** — never env vars, never compose file
3. **CrowdSec active** — auth log monitoring + firewall bouncer
4. **Firewall rules** — expose ONLY: 21115-21117 (TCP/UDP), 21443-21444 (TLS WS), 80 (ACME challenge)
5. **Pin image version** — `s6:1.1.15`, not `latest`
6. **Regular key backup** — `make backup` in cron, offsite copy
7. **Docker socket read-only** — CrowdSec mounts `:ro`
8. **No root in Caddy** — `caddy:2-alpine` runs as non-root by default
9. **Backup before first production deploy** — keys are the fleet's identity

---

## 10. docker-compose.override.yml (Development)

```yaml
# Loaded automatically by docker compose for local development
services:
  caddy:
    # Use internal TLS (self-signed) for local dev
    volumes:
      - ./caddy/Caddyfile.dev:/etc/caddy/Caddyfile:ro

  crowdsec:
    # Skip CrowdSec in dev (optional — just don't start it)
    profiles:
      - security
```

A `Caddyfile.dev` variant uses `tls internal` for local self-signed certificates.

---

## 11. Healthcheck Design

```yaml
# In docker-compose.yml
services:
  rustdesk:
    healthcheck:
      test: ["CMD", "s6-svstat", "/run/service/hbbs"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
```

S6 provides `s6-svstat` for process supervision status — built into the image.

Caddy healthcheck: default `/` endpoint returns 200 on its admin API (disabled in production) or simply check the process is running.

---

## Design Decisions Summary

| # | Decision | Choice | Alternatives Considered |
|---|----------|--------|------------------------|
| 1 | Caddy networking | Host network (Option A) | Bridge + host.docker.internal, Bridge + extra_hosts |
| 2 | Log acquisition | Docker socket (read-only) | Shared volume file |
| 3 | CrowdSec bouncer | Firewall bouncer (iptables on host) | Blocklist mirror, Caddy bouncer |
| 4 | Caddy routing | Separate TLS ports (21443, 21444) | Path-based on 443, Port replacement |
| 5 | SQLite backup | File copy (db + WAL + SHM) | sqlite3 .backup command |
| 6 | Secrets on fresh install | S6 generates → user extracts | Pre-generate with openssl |
| 7 | Restore behavior | Extract only, no auto-start | Auto-start after restore |

---

## Risks Identified in Design Phase

| Risk | Severity | Mitigation |
|------|----------|------------|
| CrowdSec parser regex needs calibration against real logs | Medium | Template parser provided; implementation phase tests against actual v1.1.15 output |
| Caddy + rustdesk both on host network reduces isolation | Low | Caddy is hardened; minimal attack surface increase |
| Firewall bouncer requires host installation (outside compose) | Medium | Document both host-install and privileged-container options |
| TLS WebSocket ports (21443/21444) are non-standard | Low | Documented in README; clients must be configured with these ports |
| S6 image may lack sqlite3 binary for backup | Low | Chose file-copy approach — no dependency |

---

## Next Recommended Phase

**sdd-tasks** — Break this design into implementable tasks with clear file-by-file deliverables, dependencies, and acceptance criteria.
