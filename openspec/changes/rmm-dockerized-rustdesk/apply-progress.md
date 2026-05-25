# Apply Progress: rmm-dockerized-rustdesk

**date:** 2026-05-25
**status:** complete
**batch:** 1 of 1

---

## Tasks Completed

| Task | File | Status |
|------|------|--------|
| T1  | `.gitignore` | DONE |
| T2  | `.env.example` | DONE |
| T3  | `docker-compose.yml` | DONE |
| T4  | `docker-compose.override.yml` | DONE |
| T5  | `caddy/Caddyfile` | DONE |
| T6  | `caddy/Caddyfile.dev` | DONE |
| T7  | `crowdsec/acquis.yaml` | DONE |
| T8  | `crowdsec/parsers/rustdesk-auth.yaml` | DONE |
| T9  | `scripts/backup.sh` | DONE |
| T10 | `scripts/restore.sh` | DONE |
| T11 | `Makefile` | DONE |
| T12 | `README.md` | DONE |

---

## Design Decisions Applied

1. Caddy on `network_mode: host` (not bridge) — per design §2 Option A
2. TLS ports 21443/21444 for Caddy WS (not 21118/21119) — per design §3 Option B
3. `./data:/data` bind mount (not named volume) — per design §1
4. Containerized `crowdsecurity/cs-firewall-bouncer` with `NET_ADMIN`/`NET_RAW` + host network — per tasks.md implementation notes
5. `key_pub`/`key_priv` in `secrets/` directory — per design §2 secrets flow

---

## Constraints Verified

- `ENCRYPTED_ONLY: "1"` — string value, not boolean
- No `version:` field in docker-compose.yml (Compose v2+ compatible)
- Scripts use `#!/bin/sh` + `set -eu` (POSIX sh)
- Scripts are executable (chmod 755)
- Makefile: `.DEFAULT_GOAL := help`, self-documenting `##` comments
- `restore.sh` does NOT auto-start containers after restore
- README ASCII diagram from proposal used verbatim (updated to show 21443/21444)

---

## Known Verification Item

The CrowdSec parser regex in `crowdsec/parsers/rustdesk-auth.yaml` uses a best-effort grok pattern for v1.1.15 auth failure log format. Per tasks.md T8 implementation note, the regex MUST be calibrated against real container log output after first deployment. The pattern may need adjustment if the actual log format differs from the expected template.

---

## Files Created

- `/home/ruben/dev/rmm-service/.gitignore`
- `/home/ruben/dev/rmm-service/.env.example`
- `/home/ruben/dev/rmm-service/docker-compose.yml`
- `/home/ruben/dev/rmm-service/docker-compose.override.yml`
- `/home/ruben/dev/rmm-service/caddy/Caddyfile`
- `/home/ruben/dev/rmm-service/caddy/Caddyfile.dev`
- `/home/ruben/dev/rmm-service/crowdsec/acquis.yaml`
- `/home/ruben/dev/rmm-service/crowdsec/parsers/rustdesk-auth.yaml`
- `/home/ruben/dev/rmm-service/scripts/backup.sh`
- `/home/ruben/dev/rmm-service/scripts/restore.sh`
- `/home/ruben/dev/rmm-service/Makefile`
- `/home/ruben/dev/rmm-service/README.md`
