# SDD Exploration: rmm-service — Dockerized RustDesk Server

**topic_key:** `sdd/rmm-service/explore`  
**type:** architecture  
**date:** 2026-05-25

---

## Problem Statement

Build a self-hosted RMM (Remote Monitoring & Management) service using RustDesk Server OSS as the underlying remote access infrastructure. The service needs to be deployable via Docker, secure by default, operationally manageable, and maintainable long-term.

---

## Architecture Background

### RustDesk Server Components

**hbbs** (ID/Rendezvous Server) — coordination hub
- Peer registration and NAT traversal coordination
- Relay brokering when P2P fails
- Ports: 21115 TCP (NAT test), 21116 TCP+UDP (main), 21118 TCP (WebSocket)
- Resource profile: 1 vCPU + 512MB RAM handles ~1000 peers

**hbbr** (Relay Server) — encrypted traffic forwarding
- Only active when P2P hole-punch fails
- Relay sees only XSalsa20-Poly1305 ciphertext — zero plaintext exposure
- Ports: 21117 TCP, 21119 TCP (WebSocket)
- Resource profile: CPU + bandwidth constrained. ~180KB/s avg per relay session. 1 vCPU ≈ 1000 concurrent sessions.
- KEY INSIGHT: relay is the operational bottleneck, not rendezvous

**Connection flow:** Client registers with hbbs → requests connection → hbbs coordinates hole-punch attempt → if P2P fails → hbbr relays encrypted stream.

### Security Model

- Ed25519 key pair auto-generated on first run (`id_ed25519` / `id_ed25519.pub`)
- Session encryption: Curve25519 key exchange + XSalsa20-Poly1305 stream
- **CRITICAL**: Must set `ENCRYPTED_ONLY=1` (or `-k _` flag) — default allows unencrypted connections
- v1.1.15 (Jan 2026): auth logging added, compatible with fail2ban/CrowdSec
- Rate limiting built-in: 30 reg requests/IP/180s, 300 unique peers/IP/24h

### Docker Image Options

| Image | Size | Description |
|-------|------|-------------|
| `rustdesk/rustdesk-server` | 5.6MB | Single binary, two containers needed |
| `rustdesk/rustdesk-server-s6` | 10.9MB | Both services in one container via s6-overlay |
| `rustdesk/rustdesk-server-pro` | 108-112MB | Commercial, requires license |

All support: amd64, arm64v8, armv7.

---

## Approach Comparison

### Approach A: S6 Single Container (Simple)

**Description:** Use `rustdesk/rustdesk-server-s6` with docker-compose and host networking. Single container, minimal configuration.

**Pros:**
- Fastest to deploy — one image, one compose service
- S6-overlay handles ordered startup (key-gen → hbbr → hbbs with 2s delay)
- Built-in process supervision and auto-restart
- Built-in healthcheck via `s6-svstat`
- Docker secrets support (`/run/secrets/key_pub`, `/run/secrets/key_priv`)
- Single container simplifies log aggregation, backups, updates
- Data lives at `/data` — clean volume mount point

**Cons:**
- Cannot scale hbbr independently (both services restart together)
- Slightly harder to read per-service logs (interleaved)
- Less common in production tutorials — fewer community examples

| Dimension | Rating |
|-----------|--------|
| Complexity | Low |
| Security | Good (with ENCRYPTED_ONLY=1) |
| Scalability | Low (monolithic, relay cannot scale independently) |
| Ops overhead | Very low |
| Cost | Free (OSS) |

**Verdict:** Best for small deployments (<100 concurrent users). Not suitable if relay becomes the bottleneck.

---

### Approach B: Two-Container Classic (Scalable)

**Description:** Separate `hbbs` and `hbbr` containers from `rustdesk/rustdesk-server`. Docker Compose with bridge or host networking.

**Pros:**
- Can scale hbbr replicas independently when relay is bottleneck
- Per-service log streams, resource limits, restarts
- More community documentation and examples

**Cons:**
- Two containers to manage, update, monitor
- Bridge networking introduces Docker NAT — can interfere with UDP hole-punching on port 21116
- Need explicit `healthcheck` stanzas (not built-in)
- Key sharing between containers requires shared volume or init container pattern

**Networking note:** `network_mode: host` recommended for Linux production — real client IPs visible, no UDP NAT issues. Bridge mode can work but requires careful port mapping and testing.

| Dimension | Rating |
|-----------|--------|
| Complexity | Medium |
| Security | Good (with explicit `-k` flag) |
| Scalability | Medium-High (relay scales independently) |
| Ops overhead | Medium |
| Cost | Free (OSS) |

**Verdict:** Best when relay saturation is anticipated or service isolation is organizationally required.

---

### Approach C: Production-Hardened Stack (RECOMMENDED)

**Description:** S6 single container as core, with added: Caddy for TLS on WebSocket ports, CrowdSec for auth log monitoring, Docker secrets for key management, backup automation, healthchecks, and operational Makefile.

**Architecture layers:**

1. **Core**: S6 single container (`rustdesk/rustdesk-server-s6:1.1.15`) — hbbs + hbbr
2. **Security layer**: CrowdSec sidecar consuming auth logs from v1.1.15+
3. **Proxy layer**: Caddy for automatic TLS on WebSocket ports (21118, 21119) ONLY — raw TCP/UDP bypass entirely
4. **Observability**: cAdvisor + node_exporter for container metrics (no native Prometheus in OSS)
5. **Secrets**: Docker secrets for key_pub/key_priv (S6 reads from `/run/secrets/` natively)
6. **Backup**: Script to atomically copy `id_ed25519`, `id_ed25519.pub`, `db_v2.sqlite3` + WAL files
7. **Operations**: Makefile targets for deploy, backup, restore, update, logs

**Compose services:**
```
rustdesk:    # S6 container — hbbs + hbbr, network_mode: host
caddy:       # TLS termination for WebSocket ports 21118/21119 only
crowdsec:    # Auth log monitoring and IP banning
bouncer:     # Enforces CrowdSec bans at network level
```

**CRITICAL rule:** Raw TCP/UDP ports (21115–21117) MUST NOT go through reverse proxy — direct host binding only. Only WebSocket ports (21118, 21119) go through Caddy.

| Dimension | Rating |
|-----------|--------|
| Complexity | High (initial), Low (ongoing — Makefile abstracts ops) |
| Security | High |
| Scalability | Medium (can evolve to B+C hybrid) |
| Ops overhead | Low (after setup) |
| Cost | Free (OSS + open source stack) |

**Verdict:** RECOMMENDED for RMM service. Key loss is catastrophic for a managed fleet — backup automation is non-negotiable. CrowdSec auth logging is a v1.1.15 designed-in feature for exactly this use case.

---

### Approach D: Pro Server

**Description:** `rustdesk/rustdesk-server-pro` — commercial with web console, SSO/LDAP, audit logs.

**Pros:** Web console, SSO/LDAP, built-in audit logs, custom client builder, OIDC (v1.8.2 Apr 2026)
**Cons:** $9.90+/mo, requires `network_mode: host` for licensing, separate codebase from OSS (not a superset), license tied to host — migration complexity

| Dimension | Rating |
|-----------|--------|
| Complexity | Medium |
| Security | High (includes audit logs OSS lacks) |
| Scalability | High |
| Ops overhead | Low (web console) |
| Cost | $9.90+/mo ongoing |

**Verdict:** Justified only if SSO/LDAP or audit logs are hard requirements, or this is a commercial RMM product. Overkill for internal/team use.

---

## Recommended Architecture: Approach C (Production-Hardened)

### Rationale

For an RMM service specifically:

1. **Key loss is catastrophic** — every managed endpoint needs reconfiguration. Backup automation is not optional.
2. **Unencrypted connections must be impossible** — `ENCRYPTED_ONLY=1` enforced at compose level, not client configuration.
3. **Auth logging in v1.1.15 exists precisely for fail2ban/CrowdSec** — not using a log processor wastes a designed-in production security feature.
4. **WebSocket TLS matters** for web client access and any monitoring UI integration.
5. **Makefile for ops** — emergency recovery at 2am should not require memorizing docker commands.

### Port Reference

| Port  | Protocol | Service | Route           |
|-------|----------|---------|-----------------|
| 21115 | TCP      | hbbs    | Direct (host)   |
| 21116 | TCP+UDP  | hbbs    | Direct (host)   |
| 21117 | TCP      | hbbr    | Direct (host)   |
| 21118 | TCP      | hbbs WS | Via Caddy (TLS) |
| 21119 | TCP      | hbbr WS | Via Caddy (TLS) |

### Volumes

- `rustdesk-data:/data` — Ed25519 keys + SQLite database
- `caddy-data:/data` — TLS certificates (auto-managed via ACME)
- `crowdsec-data:/var/lib/crowdsec` — bouncer state

### Secrets (Docker secrets — S6 reads `/run/secrets/` natively)

- `key_pub` — public key, distributed to clients
- `key_priv` — private key, never exposed

### Backup Strategy

**Critical files** (losing these = reconfigure ALL clients):
- `id_ed25519` + `id_ed25519.pub`
- `db_v2.sqlite3` + `-wal` + `-shm` (all three atomically)

**Target:** encrypted offsite (S3, Backblaze B2, etc.)
**Frequency:** daily minimum, pre-update always
**CRITICAL:** Back up before first production deployment, not after.

---

## Key Risks and Gotchas

1. **Port 21116 must be BOTH TCP and UDP** — most common misconfiguration. Single missed protocol = broken NAT traversal across the board.
2. **Key loss** — implement backup BEFORE first production deployment.
3. **`ENCRYPTED_ONLY` must be explicit** — default has changed across versions; always set explicitly in compose env.
4. **IPv6 can cause unnecessary relay routing** — test with IPv6 disabled if seeing excessive relay usage.
5. **Hairpin NAT** — same-LAN clients may fail if router doesn't support hairpin. Document and test workaround.
6. **SQLite WAL files** — back up all three files atomically (`db_v2.sqlite3`, `-wal`, `-shm`).
7. **Version pin**: Use OSS `1.1.15` (Jan 2026 — latest stable) with auth logging designed for CrowdSec integration.
8. **Pro vs OSS**: Pro is NOT a superset of OSS — it's a different codebase. Migrating from OSS→Pro requires client key reconfiguration.

---

## Version Recommendation

**Use:** `rustdesk/rustdesk-server-s6:1.1.15`

Reasons:
- Latest stable OSS release (Jan 2026)
- Auth logging added — compatible with fail2ban/CrowdSec
- Rootless container support
- Auth logging is a production design intent feature — use it

Do NOT use Pro unless SSO/LDAP is a hard requirement.

---

## Next Phase Recommendations

1. **sdd-propose**: Define the full service scope — what the repo delivers (compose file, Makefile, configuration templates, backup scripts, documentation, CrowdSec parser for RustDesk)
2. **sdd-spec**: Detail each component's configuration, environment variables, volume structure, secret management, backup procedures
3. **sdd-design**: File/directory structure, Makefile targets, backup script design, CrowdSec parser configuration for RustDesk auth logs
