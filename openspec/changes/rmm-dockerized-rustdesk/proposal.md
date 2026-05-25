# SDD Proposal: rmm-service — Dockerized RustDesk Server

**topic_key:** `sdd/rmm-service/proposal`  
**type:** architecture  
**date:** 2026-05-25  
**based_on:** exploration (Approach C — Production-Hardened Stack)

---

## What This Repo Delivers

A single-repo, Docker Compose deployment of RustDesk Server OSS for use as RMM remote access infrastructure. Secure by default, operationally simple after initial setup, and recoverable without specialist knowledge.

**Target user:** A sysadmin deploying a self-hosted remote access server for a managed fleet of endpoints.

---

## Architecture

```
                    Internet
                       │
          ┌────────────┼────────────┐
          │            │            │
     TCP/UDP 21115-21117    TCP 21118/21119 (WSS)
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

### Compose Services

| Service    | Image                                | Network        | Purpose                              |
|------------|--------------------------------------|----------------|--------------------------------------|
| `rustdesk` | `rustdesk/rustdesk-server-s6:1.1.15` | `host`         | hbbs + hbbr via s6-overlay           |
| `caddy`    | `caddy:2-alpine`                     | bridge         | TLS termination for WS ports only    |
| `crowdsec` | `crowdsec/crowdsec`                  | bridge         | Auth log parsing and threat detection |
| `bouncer`  | `crowdsec/blocklist-mirror` (or fw)  | bridge         | Enforces CrowdSec ban decisions      |

### Port Routing

| Port  | Protocol | Service  | Route                          |
|-------|----------|----------|--------------------------------|
| 21115 | TCP      | hbbs     | Direct on host — no proxy      |
| 21116 | TCP+UDP  | hbbs     | Direct on host — no proxy      |
| 21117 | TCP      | hbbr     | Direct on host — no proxy      |
| 21118 | TCP      | hbbs WS  | Via Caddy (TLS termination)    |
| 21119 | TCP      | hbbr WS  | Via Caddy (TLS termination)    |

**Rule:** Raw TCP/UDP ports (21115-21117) MUST NOT go through a reverse proxy. Only WebSocket ports (21118, 21119) route through Caddy.

### Secrets Management

Docker secrets, read by S6 from `/run/secrets/` natively:

- `key_pub` — Ed25519 public key (distributed to clients)
- `key_priv` — Ed25519 private key (never exposed)

### Volumes

- `rustdesk-data:/data` — keys + SQLite database
- `caddy-data:/data` — auto-managed TLS certificates
- `crowdsec-data:/var/lib/crowdsec` — threat intelligence state

---

## Deliverables

| # | File/Directory                   | Purpose                                                      |
|---|----------------------------------|--------------------------------------------------------------|
| 1 | `docker-compose.yml`             | Full production stack (rustdesk, caddy, crowdsec, bouncer)   |
| 2 | `docker-compose.override.yml`    | Development/local overrides (relaxed TLS, debug logging)     |
| 3 | `.env.example`                   | All configurable variables with defaults and documentation   |
| 4 | `Makefile`                       | Operational targets (see below)                              |
| 5 | `caddy/Caddyfile`                | TLS config for WebSocket proxy on 21118/21119 only           |
| 6 | `crowdsec/acquis.yaml`           | Log acquisition config pointing to rustdesk auth logs        |
| 7 | `crowdsec/parsers/` (if needed)  | Custom parser for RustDesk v1.1.15 auth log format           |
| 8 | `scripts/backup.sh`              | Atomic backup of keys + SQLite (db + WAL + SHM)             |
| 9 | `scripts/restore.sh`             | Restore from backup archive                                  |
| 10| `README.md`                      | Setup guide, architecture diagram, port ref, client config   |

### Makefile Targets

| Target         | Description                                    |
|----------------|------------------------------------------------|
| `up`           | Start all services (foreground)                |
| `up-d`         | Start all services (detached)                  |
| `down`         | Stop all services                              |
| `logs`         | Tail all service logs                          |
| `status`       | Show service health and port bindings          |
| `backup`       | Run atomic backup of keys + database           |
| `restore`      | Restore from a backup archive                  |
| `update`       | Pull new images, backup, recreate containers   |
| `keys-show`    | Display public key for client configuration    |

---

## Key Design Decisions

| Decision                            | Rationale                                                        |
|-------------------------------------|------------------------------------------------------------------|
| Pin `s6:1.1.15`, not `latest`      | Auth logging feature required; reproducible deployments          |
| `ENCRYPTED_ONLY=1` always           | Unencrypted connections must be impossible for managed fleet     |
| `network_mode: host` for rustdesk   | Real client IPs visible; no Docker NAT breaking UDP hole-punch  |
| Caddy for WS ports ONLY             | Raw TCP/UDP must not traverse a proxy — latency and NAT issues  |
| Docker secrets, not env vars         | S6 reads `/run/secrets/` natively; keys never in env or compose |
| Backup BEFORE first production use   | Key loss = reconfigure every client in the fleet                |
| CrowdSec over fail2ban              | Modern, community threat intel sharing, designed for containers |

---

## Non-Goals (Explicitly Out of Scope)

- **Client deployment automation** — this repo manages the server only
- **RustDesk Pro features** — no web console, SSO, LDAP, audit logs
- **Multi-node relay scaling** — single-server deployment; future enhancement
- **Custom RustDesk client builds** — use stock clients
- **Monitoring stack (Prometheus/Grafana)** — can layer on later; not in v1
- **IPv6 configuration** — IPv4 only for initial deployment simplicity

---

## Risks

| Risk                                  | Severity | Mitigation                                          |
|---------------------------------------|----------|-----------------------------------------------------|
| Port 21116 TCP+UDP misconfiguration   | High     | `.env.example` documents both protocols; Makefile `status` verifies |
| Key loss (fleet-wide reconfiguration) | Critical | Backup script runs pre-deploy; `update` target backs up first     |
| CrowdSec parser drift on new versions | Medium   | Pin to v1.1.15; parser tested against known log format             |
| Host networking limits container isolation | Low  | Only rustdesk uses host mode; supporting services on bridge        |
| Hairpin NAT (same-LAN clients fail)   | Medium   | Document in README; suggest LAN discovery or split DNS workaround  |
| SQLite WAL incomplete backup          | High     | `backup.sh` copies db + WAL + SHM atomically                      |

---

## Constraints

- **Delivery:** Single PR (`delivery_strategy: single-pr`)
- **Testing:** No automated test framework (`strict_tdd: false`)
- **Runtime:** Docker Compose v2+ required
- **OS:** Linux host assumed (host networking requirement)
- **Image arch:** amd64, arm64v8, armv7 supported by upstream

---

## Next Recommended Phase

**sdd-spec** — Detail each deliverable's configuration: exact environment variables, volume paths, Caddyfile structure, CrowdSec parser format, backup script logic, Makefile implementation.

**sdd-design** (parallel) — File/directory layout, Makefile conventions, script error handling patterns.
