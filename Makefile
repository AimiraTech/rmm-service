.DEFAULT_GOAL := help

COMPOSE := docker compose

# Color output via tput with graceful fallback
GREEN  := $(shell tput setaf 2 2>/dev/null || true)
YELLOW := $(shell tput setaf 3 2>/dev/null || true)
RED    := $(shell tput setaf 1 2>/dev/null || true)
RESET  := $(shell tput sgr0 2>/dev/null || true)

.PHONY: help up up-d down logs status backup restore update \
        keys-extract keys-show keys-generate _check-env

help: ## Show this help
	@echo "RMM Service — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-18s$(RESET) %s\n", $$1, $$2}'

up: _check-env ## Start all services in foreground
	$(COMPOSE) up

up-d: _check-env ## Start all services in detached mode
	$(COMPOSE) up -d
	@echo "$(GREEN)Services started. Run 'make status' to verify.$(RESET)"

down: ## Stop all services
	$(COMPOSE) down

logs: ## Tail all service logs (Ctrl+C to stop)
	$(COMPOSE) logs -f

status: ## Show service health, ports, and key status
	@echo "$(GREEN)=== Services ===$(RESET)"
	@$(COMPOSE) ps
	@echo ""
	@echo "$(GREEN)=== Ports ===$(RESET)"
	@ss -tlnpu 2>/dev/null | grep -E '(21115|21116|21117|21118|21119|21443|21444|:80 |:443 )' || \
		echo "$(YELLOW)No RustDesk ports detected (services may not be running)$(RESET)"
	@echo ""
	@echo "$(GREEN)=== Keys ===$(RESET)"
	@if [ -f data/id_ed25519.pub ]; then \
		echo "Public key: $$(cat data/id_ed25519.pub)"; \
	else \
		echo "$(YELLOW)No keys found — start the service first$(RESET)"; \
	fi

backup: ## Backup keys and database to BACKUP_DIR
	@sh scripts/backup.sh

restore: ## Restore from backup archive: make restore FILE=<archive>
	@test -n "$(FILE)" || (echo "$(RED)Usage: make restore FILE=<path/to/archive.tar.gz>$(RESET)" && exit 1)
	@sh scripts/restore.sh "$(FILE)"

update: backup ## Pull new images and recreate containers (backup runs first)
	@echo "$(GREEN)=== Pulling new images ===$(RESET)"
	$(COMPOSE) pull
	@echo "$(GREEN)=== Recreating containers ===$(RESET)"
	$(COMPOSE) up -d --force-recreate
	@echo "$(GREEN)=== Update complete ===$(RESET)"
	@$(MAKE) status

keys-extract: ## Copy generated keys from data/ to secrets/
	@mkdir -p secrets
	@test -f data/id_ed25519 || \
		(echo "$(RED)No keys in data/ — run 'make up-d' first$(RESET)" && exit 1)
	@cp data/id_ed25519 secrets/key_priv
	@cp data/id_ed25519.pub secrets/key_pub
	@chmod 600 secrets/key_priv
	@echo "$(GREEN)Keys extracted to secrets/$(RESET)"

keys-show: ## Display public key for client configuration
	@echo "$(GREEN)=== RustDesk Server Public Key ===$(RESET)"
	@if [ -f data/id_ed25519.pub ]; then \
		cat data/id_ed25519.pub; \
	elif $(COMPOSE) ps rustdesk 2>/dev/null | grep -q "running"; then \
		$(COMPOSE) exec rustdesk cat /data/id_ed25519.pub 2>/dev/null || \
			echo "$(RED)Key not found in container$(RESET)"; \
	else \
		echo "$(RED)Key not found. Run 'make up-d' first.$(RESET)"; \
	fi

keys-generate: ## Generate new keypair — WARNING: all clients must be reconfigured
	@echo "$(RED)WARNING: This will replace existing keys. All clients must be reconfigured.$(RESET)"
	@echo "Press Ctrl+C within 5 seconds to cancel..."
	@sleep 5
	@mkdir -p secrets
	@docker run --rm \
		-v "$(PWD)/secrets:/out" \
		"rustdesk/rustdesk-server-s6:$${RUSTDESK_IMAGE_TAG:-1.1.15}" \
		sh -c "hbbs --genkey && cp /data/id_ed25519* /out/" 2>/dev/null || true
	@test -f secrets/key_priv || cp secrets/id_ed25519 secrets/key_priv 2>/dev/null || true
	@test -f secrets/key_pub  || cp secrets/id_ed25519.pub secrets/key_pub 2>/dev/null || true
	@chmod 600 secrets/key_priv 2>/dev/null || true
	@echo "$(GREEN)Keys available in ./secrets/$(RESET)"

# Internal: verify .env exists before starting services
_check-env:
	@test -f .env || \
		(echo "$(RED).env not found — copy .env.example and configure:$(RESET)" && \
		 echo "  cp .env.example .env" && exit 1)
