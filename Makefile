# meenerva-infra operational shortcuts.
# Run from the repository root. Requires Docker Compose v2.

SHELL := /bin/bash
CORE  := docker compose --project-directory core-node --env-file core-node/.env
APPS  := docker compose --project-directory apps-node --env-file apps-node/.env

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

## ---- core-node ----
.PHONY: core-config core-up core-down core-pull core-logs core-ps check-images check-images-core check-images-apps
check-images: ## Verify every pinned image tag (core + apps-node + all apps/*) resolves
	./scripts/check-images.sh

check-images-core: ## Verify only core-node's own image tags (used by core-up)
	./scripts/check-images.sh core-node/docker-compose.yml

check-images-apps: ## Verify only apps-node's edge-stack image tags (used by apps-up)
	./scripts/check-images.sh apps-node/docker-compose.yml

core-config: ## Validate the core stack (render merged compose)
	$(CORE) config -q && echo "core-node/docker-compose.yml OK"

core-up: ## Start / update the core stack (set SKIP_IMAGE_CHECK=1 to bypass the pin check)
ifndef SKIP_IMAGE_CHECK
	$(MAKE) check-images-core
endif
	$(CORE) up -d --remove-orphans

core-down: ## Stop the core stack (volumes kept)
	$(CORE) down

core-pull: ## Pull newer images for the core stack
	$(CORE) pull

core-logs: ## Follow core stack logs
	$(CORE) logs -f --tail=100

core-ps: ## Show core stack containers
	$(CORE) ps

## ---- apps-node ----
.PHONY: apps-config apps-up apps-down
apps-config: ## Validate the apps-node edge stack
	$(APPS) config -q && echo "apps-node/docker-compose.yml OK"

apps-up: ## Start / update the apps-node edge stack (set SKIP_IMAGE_CHECK=1 to bypass the pin check)
ifndef SKIP_IMAGE_CHECK
	$(MAKE) check-images-apps
endif
	$(APPS) up -d --remove-orphans

apps-down: ## Stop the apps-node edge stack
	$(APPS) down

## ---- databases ----
.PHONY: db-create
db-create: ## Create an isolated DB+user in core PostgreSQL: make db-create APP=n8n
	@test -n "$(APP)" || { echo "Usage: make db-create APP=<name>"; exit 1; }
	./scripts/create-app-database.sh "$(APP)"

## ---- apps ----
.PHONY: app-new
app-new: ## Scaffold a new application: make app-new NAME=metabase
	@test -n "$(NAME)" || { echo "Usage: make app-new NAME=<name>"; exit 1; }
	./scripts/new-app.sh "$(NAME)"

## ---- backups ----
.PHONY: backup restore
backup: ## Trigger an on-demand backup to Backblaze B2
	./scripts/backup-now.sh

restore: ## Guided restore from Backblaze B2
	./scripts/restore.sh

## ---- linting ----
.PHONY: lint
lint: ## Lint shell scripts and compose files
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh scripts/lib/*.sh || echo "shellcheck not installed, skipping"
	$(MAKE) core-config
	$(MAKE) apps-config
