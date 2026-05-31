.DEFAULT_GOAL := help

PROJECT      := webui
DOCKER_DIR   := docker
FRONTEND_DIR := frontend
BACKEND_DIR  := backend
COMPOSE_DEV  := $(DOCKER_DIR)/docker-compose.dev.yml

# Bun is the frontend runtime and package manager.
BUN          ?= bun

# Tarantool is required for embed-assets, dump-schema and integration tests.
TARANTOOL    ?= tarantool

# luatest / luacheck are installed by `tt rocks install` into ./.rocks/bin.
# Prefer that path so a clean checkout works out of the box; the user can
# still override by exporting LUATEST / LUACHECK from a system install.
LUATEST      ?= .rocks/bin/luatest
LUACHECK     ?= .rocks/bin/luacheck

# ─────────────────────────────────────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "Available targets:\n"} \
		/^[a-zA-Z_-]+:.*?##/ { printf "  \033[1m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ─────────────────────────────────────────────────────────────────────────────
# Local development
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: dev
dev: ## Bring up local cluster (HAProxy + 3 instances + etcd + dev frontend).
	docker compose -f $(COMPOSE_DEV) up --build -d
	@echo
	@echo "UI available at:    http://localhost:8080"
	@echo "Direct instances:   http://localhost:8081, 8082, 8083"
	@echo "HAProxy stats:      http://localhost:8404"
	@echo "Vite dev frontend:  http://localhost:5173 (HMR)"

.PHONY: dev-down
dev-down: ## Tear down the local cluster.
	docker compose -f $(COMPOSE_DEV) down --volumes --remove-orphans

.PHONY: dev-logs
dev-logs: ## Tail logs of the local cluster.
	docker compose -f $(COMPOSE_DEV) logs -f

# ─────────────────────────────────────────────────────────────────────────────
# Linting
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: lint
lint: lint-backend lint-frontend ## Lint backend and frontend.

.PHONY: lint-backend
lint-backend: ## Run luacheck on the backend.
	$(LUACHECK) $(BACKEND_DIR)

.PHONY: lint-frontend
lint-frontend: ## Run ESLint and prettier check on the frontend.
	cd $(FRONTEND_DIR) && $(BUN) run lint

.PHONY: lint-fix
lint-fix: ## Auto-fix lint issues where possible.
	cd $(FRONTEND_DIR) && $(BUN) run lint:fix

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: test
test: test-backend test-frontend ## Run unit tests (backend + frontend).

.PHONY: test-backend
test-backend: ## Run backend unit tests (luatest).
	$(LUATEST) $(BACKEND_DIR)/test/unit

.PHONY: test-frontend
test-frontend: ## Run frontend unit tests (vitest).
	cd $(FRONTEND_DIR) && $(BUN) run test:unit

.PHONY: test-integration
test-integration: ## Run integration tests (docker-compose based).
	$(LUATEST) $(BACKEND_DIR)/test/integration

.PHONY: test-e2e
test-e2e: ## Run Playwright end-to-end tests against dev compose.
	cd $(FRONTEND_DIR) && $(BUN)x playwright test

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: install
install: ## Install frontend dependencies via Bun.
	cd $(FRONTEND_DIR) && $(BUN) install --frozen-lockfile

.PHONY: build-frontend
build-frontend: install ## Build production SPA (Vite via Bun).
	cd $(FRONTEND_DIR) && $(BUN) run build

.PHONY: dump-schema
dump-schema: ## Export GraphQL SDL from the backend (offline, no running cluster).
	$(TARANTOOL) tools/dump-schema.lua $(FRONTEND_DIR)/src/shared/api/schema.graphql

.PHONY: gen-types
gen-types: dump-schema ## Generate TypeScript types from the GraphQL schema.
	cd $(FRONTEND_DIR) && $(BUN)x graphql-codegen --config codegen.yml

.PHONY: gen-types-watch
gen-types-watch: ## Watch SDL and regenerate TS types on change.
	cd $(FRONTEND_DIR) && $(BUN)x graphql-codegen --config codegen.yml --watch

.PHONY: embed-assets
embed-assets: build-frontend ## Pack frontend/dist into backend/webui/assets/bundle.lua.
	$(TARANTOOL) tools/embed-assets.lua

.PHONY: docker-build
docker-build: embed-assets ## Build the Docker image for a Tarantool instance with embedded UI.
	docker build -f $(DOCKER_DIR)/Dockerfile.instance -t $(PROJECT)-instance:dev .

# ─────────────────────────────────────────────────────────────────────────────
# Housekeeping
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: clean
clean: ## Remove build artefacts.
	rm -rf $(FRONTEND_DIR)/dist
	rm -rf $(FRONTEND_DIR)/node_modules
	rm -f  $(FRONTEND_DIR)/src/shared/api/schema.graphql
	rm -f  $(FRONTEND_DIR)/src/shared/api/generated.ts
	rm -f  $(BACKEND_DIR)/webui/assets/bundle.lua
	rm -rf .rocks

.PHONY: check-no-tooling-mentions
check-no-tooling-mentions: ## Verify project artefacts do not reference internal tooling vocabulary.
	./tools/check-no-tooling-mentions.sh

.PHONY: check-all
check-all: lint check-no-tooling-mentions test ## Run all quick checks before PR.
