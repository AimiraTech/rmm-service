.DEFAULT_GOAL := help

COMPOSE := docker compose

# Color output via tput with graceful fallback
GREEN  := $(shell tput setaf 2 2>/dev/null || true)
YELLOW := $(shell tput setaf 3 2>/dev/null || true)
RED    := $(shell tput setaf 1 2>/dev/null || true)
RESET  := $(shell tput sgr0 2>/dev/null || true)

.PHONY: help up up-d down logs status backup restore update admin-create _check-env

help: ## Show this help
	@echo "RMM Service (MeshCentral) — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-18s$(RESET) %s\n", $$1, $$2}'

up: _check-env ## Start MeshCentral in foreground
	$(COMPOSE) up

up-d: _check-env ## Start MeshCentral in detached mode
	$(COMPOSE) up -d
	@echo "$(GREEN)MeshCentral started. Run 'make status' to verify.$(RESET)"

down: ## Stop MeshCentral
	$(COMPOSE) down

logs: ## Tail MeshCentral logs (Ctrl+C to stop)
	$(COMPOSE) logs -f

status: ## Show service health and container status
	@echo "$(GREEN)=== Services ===$(RESET)"
	@$(COMPOSE) ps
	@echo ""
	@echo "$(GREEN)=== Health ===$(RESET)"
	@docker inspect meshcentral --format '{{.State.Health.Status}}' 2>/dev/null || \
		echo "$(YELLOW)meshcentral container not found$(RESET)"

backup: ## Backup MeshCentral volumes to BACKUP_DIR
	@sh scripts/backup.sh

restore: ## Restore from backup archive: make restore FILE=<archive>
	@test -n "$(FILE)" || (echo "$(RED)Usage: make restore FILE=<path/to/archive.tar.gz>$(RESET)" && exit 1)
	@sh scripts/restore.sh "$(FILE)"

update: ## Pull new images and recreate containers via deploy/update.sh
	@sh deploy/update.sh

admin-create: ## Instructions to create the initial admin account
	@echo "$(GREEN)=== Create MeshCentral Admin Account ===$(RESET)"
	@echo ""
	@echo "Option 1 — Web UI (recommended for first run):"
	@echo "  Open https://<MESHCENTRAL_HOSTNAME> in your browser."
	@echo "  MeshCentral will prompt you to create the first admin account."
	@echo ""
	@echo "Option 2 — CLI (container must be running):"
	@echo "  docker exec -it meshcentral node node_modules/meshcentral --createaccount <user> --pass <pass> --email <email>"
	@echo "  docker exec -it meshcentral node node_modules/meshcentral --adminaccount <user>"
	@echo ""

# Internal: verify .env exists before starting services
_check-env:
	@test -f .env || \
		(echo "$(RED).env not found — copy .env.example and configure:$(RESET)" && \
		 echo "  cp .env.example .env" && exit 1)
