# SDD Tasks: rmm-service — Dockerized RustDesk Server

**topic_key:** `sdd/rmm-service/tasks`
**type:** architecture
**date:** 2026-05-25
**based_on:** spec + design (Approach C — Production-Hardened Stack)

---

## Task List

### T1 — `.gitignore`

**Title:** Create root `.gitignore`

**Files:**
- `/.gitignore` (create)

**Dependencies:** None

**Description:**
Exclude all secrets, runtime data, user configuration, and backup artifacts from version control. This is the foundation — every subsequent file that generates sensitive data depends on these exclusions being in place.

**Exact entries required:**
```
# User environment — never commit credentials
.env

# Runtime data — keys and database live here
data/

# Docker secrets — generated or restored, never source-controlled
secrets/

# SQLite artifacts — belt-and-suspenders (also inside data/)
*.sqlite3
*.sqlite3-wal
*.sqlite3-shm

# Local backup archives
backups/

# Caddy runtime (managed by Docker volumes, not repo)
caddy-data/
caddy-config/
```

**Acceptance criteria:**
- `git status` after creating `secrets/`, `data/`, `.env`, `backups/` shows none of those paths as untracked
- `.gitignore` itself IS tracked
- No wildcard that would accidentally exclude `Caddyfile` or other config files in `caddy/`

**Estimated LOC:** ~20

---

### T2 — `.env.example`

**Title:** Create `.env.example` with all variables, defaults, and inline documentation

**Files:**
- `/.env.example` (create)

**Dependencies:** T1 (`.gitignore` must exclude `.env` before documenting it)

**Description:**
Defines every environment variable used by the stack. Must be complete enough that a sysadmin can configure the system by reading this file alone, without consulting any other file.

**Variables required (from design §8):**

| Variable | Default | Required | Notes |
|---|---|---|---|
| `DOMAIN` | `rmm.example.com` | Yes | Public DNS name; used by Caddy for TLS cert |
| `TLS_EMAIL` | `admin@example.com` | Yes | Let's Encrypt notification email |
| `RELAY_HOST` | `rmm.example.com` | Yes | Hostname clients use to reach relay (usually same as DOMAIN) |
| `RUSTDESK_IMAGE_TAG` | `1.1.15` | No | Pinned image tag; warn not to change without reading changelog |
| `RUST_LOG` | `info` | No | Valid: error, warn, info, debug, trace |
| `WS_HBBS_TLS_PORT` | `21443` | No | Caddy TLS port for hbbs WebSocket |
| `WS_HBBR_TLS_PORT` | `21444` | No | Caddy TLS port for hbbr WebSocket |
| `BACKUP_DIR` | `/var/backups/rmm` | No | Host path for backup archives |
| `BACKUP_RETENTION_DAYS` | `30` | No | Days before local backup pruning |
| `CROWDSEC_BOUNCER_KEY` | _(empty)_ | After setup | Generate with `docker compose exec crowdsec cscli bouncers add rmm-bouncer` |
| `GID` | `1000` | No | Group ID for CrowdSec log access |

**Acceptance criteria:**
- Every variable referenced in `docker-compose.yml`, `Caddyfile`, and `scripts/` is present in this file
- Each variable has a `# REQUIRED` or `# OPTIONAL` prefix in its comment
- The file is valid as-is for `cp .env.example .env` — no unexpanded placeholders
- `CROWDSEC_BOUNCER_KEY` is documented with the exact generation command

**Estimated LOC:** ~45

---

### T3 — `docker-compose.yml`

**Title:** Create production Docker Compose stack definition

**Files:**
- `/docker-compose.yml` (create)

**Dependencies:** T2 (all `${VAR}` references must be defined in `.env.example`)

**Description:**
Four-service production stack. The canonical configuration to deploy after reading the README.

**Key design decisions to encode:**

1. **rustdesk** — `network_mode: host`, `ENCRYPTED_ONLY: "1"` (string, not boolean), healthcheck using `s6-svstat`, Docker secrets mounted from `./secrets/key_pub` and `./secrets/key_priv`
2. **caddy** — `network_mode: host` (design decision §2: Option A), ports 80/443/`${WS_HBBS_TLS_PORT:-21443}`/`${WS_HBBR_TLS_PORT:-21444}` exposed, Caddyfile mounted read-only, `caddy-data` and `caddy-config` named volumes
3. **crowdsec** — bridge network (`crowdsec-net`), Docker socket mounted read-only, `acquis.yaml` mounted read-only, parser directory mounted read-only
4. **bouncer** — `crowdsec-firewall-bouncer` image, `network_mode: host`, `NET_ADMIN` + `NET_RAW` capabilities, depends on crowdsec

**CRITICAL constraints to preserve:**
- `network_mode: host` on rustdesk is non-negotiable (UDP hole-punch, real IPs)
- `ENCRYPTED_ONLY` must be `"1"` (string)
- `caddy` also on host network (resolves proxy-to-localhost cleanly)
- Caddy does NOT expose 21115/21116/21117 — those are host-bound by rustdesk
- Secret file paths: `./secrets/key_pub` and `./secrets/key_priv` (design §2, not `id_ed25519.*`)
- CrowdSec parser directory mounted at `/etc/crowdsec/parsers/s02-enrich` (stage matters)
- `caddy` depends on `rustdesk` with `condition: service_healthy`

**Volumes:**
```
caddy-data, caddy-config, crowdsec-data, crowdsec-config
```
(No named volume for rustdesk-data — uses `./data:/data` bind mount per design §1)

**Networks:**
```
crowdsec-net: driver: bridge
```

**Acceptance criteria:**
- `docker compose config` validates without errors (after `.env` is populated)
- `docker compose up -d` starts all four services
- `docker compose ps` shows `rustdesk` and `caddy` with `network_mode: host`
- `ENCRYPTED_ONLY` value is the string `"1"` in the rendered config

**Estimated LOC:** ~90

---

### T4 — `docker-compose.override.yml`

**Title:** Create development override for local testing

**Files:**
- `/docker-compose.override.yml` (create)

**Dependencies:** T3 (overrides must reference services defined in main compose)

**Description:**
Automatically loaded by `docker compose` when present. Replaces the production Caddyfile with the dev variant and adds `RUST_LOG: debug`. Dev overrides should NOT be committed with production secrets or port conflicts.

**Changes from production:**
- `rustdesk`: set `RUST_LOG: debug`
- `caddy`: override Caddyfile volume mount to `./caddy/Caddyfile.dev:/etc/caddy/Caddyfile:ro`
- `crowdsec`: add `profiles: [security]` so it doesn't start by default in dev (optional but useful)

**Note:** Port overrides (8080/8443) mentioned in spec are NOT needed since Caddy is on host network — ports bind directly on the host, no port mapping.

**Acceptance criteria:**
- `docker compose config` with override applied shows `RUST_LOG: debug`
- Caddyfile path resolves to `Caddyfile.dev` in merged config
- `docker compose up caddy` in dev uses self-signed internal TLS (no domain required)

**Estimated LOC:** ~20

---

### T5 — `caddy/Caddyfile`

**Title:** Create production Caddyfile with separate TLS ports for WebSocket

**Files:**
- `/caddy/Caddyfile` (create)

**Dependencies:** T3 (Caddy service must exist; ports must be consistent with compose definition)

**Description:**
Caddy listens on separate TLS ports (21443 and 21444) for hbbs and hbbr WebSocket traffic respectively. This is the design-validated approach (Option B from design §3) — RustDesk clients do not support path-based routing, so separate ports are required.

**CRITICAL design facts:**
- Caddy is on host network → proxy to `localhost:21118` and `localhost:21119`
- Ports 21443/21444 are Caddy's ports; 21118/21119 are rustdesk's internal WS ports
- NO path-based routing on 443 — this does NOT work with RustDesk WS clients
- `flush_interval -1` disables buffering for WebSocket streams
- `transport http { versions h1.1 }` required (WebSocket is HTTP/1.1 only)
- No `read_timeout`/`write_timeout` overrides needed — Caddy handles WS natively

**Caddyfile structure:**
```caddyfile
{
    email {$TLS_EMAIL}
}

{$DOMAIN}:{$WS_HBBS_TLS_PORT:21443} {
    reverse_proxy localhost:21118 {
        flush_interval -1
        transport http {
            versions h1.1
        }
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}

{$DOMAIN}:{$WS_HBBR_TLS_PORT:21444} {
    reverse_proxy localhost:21119 {
        flush_interval -1
        transport http {
            versions h1.1
        }
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

**Acceptance criteria:**
- `caddy validate --config caddy/Caddyfile` passes (with env vars set)
- Caddy binds on 21443 and 21444 (visible in `make status` port output)
- WebSocket connections to `wss://domain:21443` and `wss://domain:21444` succeed (acceptance scenario S7)
- No reference to path-based routing (`/ws/id`, `/ws/relay`)

**Estimated LOC:** ~35

---

### T6 — `caddy/Caddyfile.dev`

**Title:** Create development Caddyfile with internal self-signed TLS

**Files:**
- `/caddy/Caddyfile.dev` (create)

**Dependencies:** T5 (mirrors production Caddyfile structure, replaces TLS block only)

**Description:**
Development variant that uses `tls internal` for self-signed certificates. No domain required, no ACME challenge. Used by `docker-compose.override.yml`.

**Key difference from production:**
- Replace `tls {$TLS_EMAIL}` (ACME) with `tls internal` in each server block
- Keep same port structure (21443, 21444) for consistency with dev client config

**Acceptance criteria:**
- `docker compose up caddy` in dev starts without ACME errors
- Caddy presents a self-signed certificate on ports 21443/21444
- No DOMAIN or TLS_EMAIL env vars required for dev startup

**Estimated LOC:** ~35

---

### T7 — `crowdsec/acquis.yaml`

**Title:** Create CrowdSec log acquisition config

**Files:**
- `/crowdsec/acquis.yaml` (create)

**Dependencies:** T3 (container name `rustdesk` must match compose service definition)

**Description:**
Configures CrowdSec to read rustdesk container logs via Docker socket. The `container_name` value must exactly match the `container_name:` field in `docker-compose.yml`.

```yaml
---
source: docker
container_name:
  - rustdesk
labels:
  type: rustdesk
```

**Constraints:**
- `source: docker` requires the Docker socket mount in the crowdsec service (already in T3)
- `labels.type: rustdesk` is the type identifier matched by the custom parser (T8)
- If CrowdSec Hub gains an official RustDesk parser, this file still works as-is

**Acceptance criteria:**
- CrowdSec starts without acquisition config errors
- `docker compose exec crowdsec cscli metrics` shows `rustdesk` as a log source
- Auth failure lines from rustdesk appear in CrowdSec metrics after triggering a test failure

**Estimated LOC:** ~8

---

### T8 — `crowdsec/parsers/rustdesk-auth.yaml`

**Title:** Create custom CrowdSec parser for RustDesk auth failure logs

**Files:**
- `/crowdsec/parsers/rustdesk-auth.yaml` (create)

**Dependencies:** T7 (`acquis.yaml` must label lines as `type: rustdesk` before parser fires)

**Description:**
Custom YAML parser that extracts the source IP from RustDesk v1.1.15 auth failure log lines and maps it to `evt.Meta.source_ip` for ban decisions.

**Expected log format (v1.1.15 hbbs):**
```
[YYYY-MM-DDTHH:MM:SS] WARN  Failed login attempt from IP: <ip_address>
```

**NOTE for implementer:** The exact log format MUST be verified against real v1.1.15 container output before finalizing the regex. Run `docker compose logs rustdesk` and trigger a failed auth to capture a real sample line. Adjust the grok pattern if the format differs.

```yaml
filter: "evt.Line.Labels.type == 'rustdesk'"
name: custom/rustdesk-auth
description: "Parse RustDesk v1.1.15 authentication failure logs"
onsuccess: next_stage
nodes:
  - grok:
      pattern: '%{TIMESTAMP_ISO8601:timestamp}\s+%{LOGLEVEL:level}\s+Failed login attempt from IP:\s+%{IP:source_ip}'
      apply_on: evt.Line.Raw
    statics:
      - meta: source_ip
        expression: evt.Parsed.source_ip
      - meta: log_type
        value: "rustdesk_auth_fail"
      - target: evt.StrTime
        expression: evt.Parsed.timestamp
```

**Acceptance criteria:**
- CrowdSec starts without parser errors: `docker compose logs crowdsec | grep -i error`
- After simulating 5+ failed auth attempts, `cscli decisions list` shows the source IP banned
- `cscli metrics` shows parser hit count increasing for `custom/rustdesk-auth`

**Estimated LOC:** ~25

---

### T9 — `scripts/backup.sh`

**Title:** Create atomic backup script for keys and database

**Files:**
- `/scripts/backup.sh` (create, executable: `chmod +x`)

**Dependencies:** T3 (relies on `data/` bind mount layout established by compose)

**Description:**
POSIX sh script that creates a timestamped archive of the Ed25519 keypair and SQLite database. Runs while the container is live (SQLite WAL mode allows concurrent reads).

**Behavior (from spec §7):**
1. Load `BACKUP_DIR` (default: `/var/backups/rmm`) and `BACKUP_RETENTION_DAYS` (default: `30`) from environment
2. Create `BACKUP_DIR` if absent (`mkdir -p`)
3. Create temp dir with `mktemp -d`
4. Copy from `./data/` (bind mount, no `docker compose cp` needed since bind mount is accessible on host):
   - `id_ed25519` (private key)
   - `id_ed25519.pub` (public key)
   - `db_v2.sqlite3`
   - `db_v2.sqlite3-wal` (copy only if present — `2>/dev/null || true`)
   - `db_v2.sqlite3-shm` (copy only if present — `2>/dev/null || true`)
5. Create archive `rmm-backup-YYYYMMDD-HHMMSS.tar.gz` from temp dir
6. Atomically move archive to `BACKUP_DIR` with `mv`
7. Remove temp dir
8. Prune archives older than `BACKUP_RETENTION_DAYS` with `find ... -mtime +N -delete`
9. Print success: archive path + size (`du -sh`)

**Error handling:**
- `#!/bin/sh` + `set -eu` at top
- `trap cleanup EXIT` for temp dir cleanup on failure
- Any failure exits with code 1 and message to stderr

**IMPORTANT NOTE:** The design uses `./data:/data` bind mount. The script accesses `./data/` directly on the host — NOT via `docker compose cp`. This is simpler and avoids container dependencies during backup.

**Acceptance criteria:**
- `make backup` exits 0 and creates `rmm-backup-*.tar.gz` in `BACKUP_DIR`
- Archive is non-empty and passes `tar -tzf` integrity check
- Re-running after `BACKUP_RETENTION_DAYS + 1` old archives exist removes old ones
- Script works while rustdesk container is running (no lock contention)
- `set -eu` is set — a missing source file causes exit 1 with message

**Estimated LOC:** ~60

---

### T10 — `scripts/restore.sh`

**Title:** Create restore-from-archive script

**Files:**
- `/scripts/restore.sh` (create, executable: `chmod +x`)

**Dependencies:** T9 (restore is the inverse of backup; same file list)

**Description:**
POSIX sh script that validates and extracts a backup archive, restoring keys to `secrets/` and data to `data/`. Does NOT auto-start containers after restore.

**Behavior (from spec §8 + design §6):**
1. Accept one argument: path to `.tar.gz` archive. Exit 1 with usage if absent.
2. Verify archive exists and is readable.
3. Verify archive integrity: `tar -tzf <archive> > /dev/null`
4. Verify archive contains `id_ed25519`, `id_ed25519.pub`, `db_v2.sqlite3` — exit 1 if missing.
5. Print current public key fingerprint (if `secrets/key_pub` exists) for operator comparison.
6. Stop rustdesk: `docker compose stop rustdesk`
7. Extract to temp dir.
8. Copy keys to `secrets/`: `id_ed25519 → secrets/key_priv`, `id_ed25519.pub → secrets/key_pub`
9. Set permissions: `chmod 600 secrets/key_priv`
10. Copy data files to `data/`: `db_v2.sqlite3`, `db_v2.sqlite3-wal`, `db_v2.sqlite3-shm` (copy if present)
11. Remove temp dir.
12. Print instructions: `"Restore complete. Run 'make up-d' to start services."`
13. Exit 0.

**CRITICAL:** Do NOT auto-start containers. User explicitly runs `make up-d` after reviewing restore. This is a deliberate design decision to prevent accidental starts with partial data.

**Error handling:**
- `#!/bin/sh` + `set -eu`
- `trap cleanup EXIT`
- If archive integrity fails, exit 1 before modifying any files

**Acceptance criteria:**
- `make restore FILE=<archive>` extracts and places files correctly
- `secrets/key_priv` has permissions `600` after restore
- Script exits BEFORE modifying anything if archive is corrupt or missing required files
- Containers are NOT started automatically after restore
- `make keys-show` shows the restored public key

**Estimated LOC:** ~70

---

### T11 — `Makefile`

**Title:** Create operational Makefile with self-documenting help

**Files:**
- `/Makefile` (create)

**Dependencies:** T9, T10 (backup and restore targets call scripts; Makefile must reference existing scripts)

**Description:**
Primary operational interface. Self-documenting via `##` comments. All user-facing operations available as make targets.

**Target list (from spec §4 + design §5):**

| Target | Dependency | Description |
|---|---|---|
| `help` | (default) | Print formatted target list from `##` comments |
| `up` | `_check-env` | `docker compose up` (foreground) |
| `up-d` | `_check-env` | `docker compose up -d` + status hint |
| `down` | — | `docker compose down` |
| `logs` | — | `docker compose logs -f` |
| `status` | — | Services + ports + key display |
| `backup` | — | Call `scripts/backup.sh` |
| `restore` | — | Validate `FILE=` arg, call `scripts/restore.sh "$(FILE)"` |
| `update` | `backup` | Pull images + recreate (backup runs first — non-negotiable) |
| `keys-extract` | — | Copy `data/id_ed25519*` to `secrets/` as `key_priv`/`key_pub` |
| `keys-show` | — | Print `data/id_ed25519.pub` (fallback: via docker exec) |
| `keys-generate` | — | 5-second warning + generate via docker run |
| `_check-env` | — | Internal: verify `.env` exists before starting services |

**Makefile conventions (from design §5):**
- `.DEFAULT_GOAL := help`
- Color output via `tput` with graceful fallback if `tput` unavailable
- `COMPOSE := docker compose`
- `help` uses grep + awk on `##` comments (standard self-doc pattern)
- `restore` uses `$(FILE)` (not `$(BACKUP)`) — consistent with spec §4 usage `make restore FILE=<archive>`
- `_check-env` prefixed with underscore — internal, excluded from `help` output
- POSIX sh compatible — no bashisms in recipes

**status target must show:**
1. `docker compose ps` output
2. `ss -tlnpu` filtered for RustDesk ports (21115-21119, 21443-21444, 80, 443)
3. Public key content (from `data/id_ed25519.pub` or "not yet generated")

**Acceptance criteria:**
- `make` (no args) prints formatted help with all public targets
- `make up-d` fails with readable error if `.env` is absent
- `make update` runs backup step before image pull (visible in output)
- `make restore FILE=path/to/archive` passes `FILE` to script correctly
- `make restore` (no FILE) prints usage message and exits 1

**Estimated LOC:** ~80

---

### T12 — `README.md`

**Title:** Create operator README with setup guide, architecture, and troubleshooting

**Files:**
- `/README.md` (create)

**Dependencies:** T1–T11 (documents the complete, implemented stack)

**Description:**
The complete operational reference. Written for a sysadmin deploying for the first time. Must be accurate to the actual implementation (use real port numbers, real make targets, real env var names).

**Required sections (from spec §9):**

1. **Overview** (2-3 sentences, link to RustDesk OSS upstream)

2. **Prerequisites**
   - Docker Engine 24+, Docker Compose v2, Linux host
   - Firewall ports table (all 7 ports with protocol and purpose)
   - DNS A record requirement

3. **Quick Start** (numbered steps):
   1. `cp .env.example .env` → fill `DOMAIN`, `RELAY_HOST`, `TLS_EMAIL`
   2. `make up-d`
   3. `make status` to verify all healthy
   4. `make keys-extract` (first run — copies S6-generated keys to `secrets/`)
   5. `make keys-show` for public key to configure clients

4. **Architecture** — ASCII diagram from proposal + one paragraph per service

5. **Port Reference** table (7 ports):
   | Port | Protocol | Service | Route | Firewall |
   Note: must include 21443 and 21444 (Caddy TLS WS ports) — NOT 21118/21119 as TLS endpoints

6. **Client Configuration**:
   - Settings → Network → ID Server: `DOMAIN:21443`
   - Settings → Network → Relay Server: `DOMAIN:21444`
   - Key: paste contents of `id_ed25519.pub` (from `make keys-show`)

7. **CrowdSec Setup** (post-deploy step):
   - Generate bouncer key: `docker compose exec crowdsec cscli bouncers add rmm-bouncer`
   - Add key to `.env` as `CROWDSEC_BOUNCER_KEY=<key>`
   - `make down && make up-d`

8. **Backup & Restore**:
   - `make backup` → creates archive
   - `make restore FILE=<archive>` → extracts, then `make up-d`
   - Warning: backup keys BEFORE first production deployment
   - What is backed up: keypair + SQLite db + WAL + SHM

9. **Troubleshooting** (5 specific cases from spec §9):
   - Port 21116 must be BOTH TCP AND UDP
   - Hairpin NAT (LAN clients + server on same network)
   - Key mismatch (`make keys-show`)
   - TLS cert not issued (DNS + ports 80/443)
   - CrowdSec blocking legitimate IPs (`cscli decisions list`, `cscli decisions delete`)

10. **Security Hardening Checklist** (9 items from design §9)

**Acceptance criteria:**
- All make targets referenced in README exist in the Makefile
- All env vars referenced in README exist in `.env.example`
- Port table includes 21443/21444 as TLS WebSocket ports (not 21118/21119 as TLS)
- Client configuration section shows the correct ports for WSS connections
- No references to path-based routing (`/ws/id`, `/ws/relay`) — those don't exist

**Estimated LOC:** ~200

---

## Task Dependency Graph

```
T1 (.gitignore)
└── T2 (.env.example)
    └── T3 (docker-compose.yml)
        ├── T4 (docker-compose.override.yml)
        ├── T5 (caddy/Caddyfile)
        │   └── T6 (caddy/Caddyfile.dev)
        ├── T7 (crowdsec/acquis.yaml)
        │   └── T8 (crowdsec/parsers/rustdesk-auth.yaml)
        └── T9 (scripts/backup.sh)
            ├── T10 (scripts/restore.sh)
            └── T11 (Makefile)
                └── T12 (README.md)
```

All tasks feed into T12. T11 (Makefile) is the last code task; T12 (README) is final.

---

## File Checklist

| # | File | Task | Type |
|---|---|---|---|
| 1 | `.gitignore` | T1 | Config |
| 2 | `.env.example` | T2 | Config |
| 3 | `docker-compose.yml` | T3 | Config |
| 4 | `docker-compose.override.yml` | T4 | Config |
| 5 | `caddy/Caddyfile` | T5 | Config |
| 6 | `caddy/Caddyfile.dev` | T6 | Config |
| 7 | `crowdsec/acquis.yaml` | T7 | Config |
| 8 | `crowdsec/parsers/rustdesk-auth.yaml` | T8 | Config |
| 9 | `scripts/backup.sh` | T9 | Script |
| 10 | `scripts/restore.sh` | T10 | Script |
| 11 | `Makefile` | T11 | Build |
| 12 | `README.md` | T12 | Docs |

---

## Implementation Notes for `sdd-apply`

### Design discrepancies to resolve

The spec (§1) and design (§2) have minor inconsistencies — **design takes precedence**:

1. **Caddy networking:** spec shows `ports:` mapping (bridge); design explicitly chose host network (Option A). Use host network.
2. **TLS ports:** spec uses 21118/21119 for Caddy; design's final approach uses 21443/21444. Use 21443/21444.
3. **Data storage:** spec shows named volume `rustdesk-data:/data`; design shows bind mount `./data:/data`. Use bind mount (enables direct file access for backup.sh without docker compose cp).
4. **Bouncer image:** spec uses `crowdsecurity/cs-firewall-bouncer`; design discusses host-install vs. containerized. Use containerized `crowdsecurity/cs-firewall-bouncer` image with `NET_ADMIN`/`NET_RAW` caps and host network.
5. **Secret file names:** spec uses `id_ed25519`/`id_ed25519.pub`; design uses `key_pub`/`key_priv`. Use design names (`key_pub`, `key_priv`) — these are the Docker secret names and the filenames in `secrets/`.

### CrowdSec parser calibration

The parser regex in T8 MUST be tested against real container log output. The pattern provided is a best-effort template. Implementer must:
1. Start the stack
2. Trigger a failed auth attempt
3. Capture the actual log line format
4. Adjust the grok pattern if it differs from the template

### Script path for backup.sh

`backup.sh` accesses `./data/` directly (bind mount on host), not via `docker compose cp`. This means:
- The script must be run from the repo root (Makefile handles this)
- If the user moves the repo, `./data/` path is still correct relative to repo root
- No container dependency for backup (can backup even if container is stopped)

---

## Review Workload Forecast

| Metric | Value |
|---|---|
| Total files | 12 |
| Total estimated LOC | ~668 |
| Largest single file | `README.md` (~200 LOC) |
| Script LOC | ~130 (backup.sh + restore.sh) |
| Config LOC | ~253 (compose + env + caddy + crowdsec) |
| Chained PRs recommended | No |
| 400-line budget risk | High (668 LOC total) |
| Decision needed before apply | No — size:exception applies |

**Size exception justification:** This change is infrastructure-as-code with no business logic. All 12 files are configuration files, scripts, and documentation. The line count is high but the cognitive complexity per file is low. Each file is independently reviewable and the diff is additive-only (no existing code modified). Single PR is appropriate for this change type.

**Delivery:** `single-pr` with `size:exception` acknowledged.
