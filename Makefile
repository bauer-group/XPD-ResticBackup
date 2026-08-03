# =============================================================================
# XPD-ResticBackup - Developer entrypoint
# =============================================================================
# `make` with no target prints this file's self-documenting help.
#
# Split by cost: `make test` is hermetic (no Docker, no network, no secrets) and
# is meant to run on every save. Anything needing the MinIO rig is a separate,
# opt-in target so a developer without Docker is never blocked.
# =============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

VERSION  := $(shell cat VERSION)
UBUNTU   ?= 24.04
BATS     := tests/helper/bats-core/bin/bats
COMPOSE  := BGB_UBUNTU_TAG=$(UBUNTU) docker compose -f tests/rig/docker-compose.yml
SHELLSRC := $(shell git ls-files '*.sh' '*.bash' 2>/dev/null)

# MUST stay identical to exclude-codes in .github/workflows/ci.yml. When they
# drift, `make lint` and the CI gate disagree - and the one that is wrong is
# always the one you are not looking at.
#   SC1091 - sourced file not followed; every lib/ module is sourced at runtime
#            from a path that does not exist at lint time.
#   SC2034 - "appears unused"; the config and db-result protocols are deliberately
#            cross-module (BGB_DB_RESULT, JOB_*, BGB_DEFAULT_*).
SHELLCHECK_EXCLUDE := SC1091,SC2034

.PHONY: help version lint format format-check test test-unit test-config \
        rig-up rig-down rig-logs integration docker-e2e dr-rehearse \
        docs recovery-sheet submodules clean check-all

help: ## Show this help
	@printf '\n\033[1mXPD-ResticBackup\033[0m - bg-backup v$(VERSION)\n\n'
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_.-]+:.*##/{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\n'

version: ## Print the tool version
	@echo "$(VERSION)"

# --- Quality gates (hermetic) ------------------------------------------------

lint: ## Run shellcheck over every tracked shell script
	@test -n "$(SHELLSRC)" || { echo "no shell sources tracked yet"; exit 0; }
	shellcheck -x -S warning -e $(SHELLCHECK_EXCLUDE) $(SHELLSRC)

# $(SHELLSRC), not directory globs: `tests` holds the vendored bats submodules
# and walking it would reformat third-party code. Same list as `lint`.
format: ## Rewrite shell sources with shfmt
	shfmt -i 2 -ci -bn -w $(SHELLSRC)

format-check: ## Fail if shfmt would change anything
	shfmt -i 2 -ci -bn -d $(SHELLSRC)

test-unit: submodules ## Run the bats unit suite
	$(BATS) --recursive tests/unit

test-config: ## Validate the shipped example configuration
	@# --no-perm-check: the example lives in the working tree and is owned by
	@# whoever checked it out, not by root. The ownership gate guards the
	@# SOURCING path on a real host, not a lint of a candidate file.
	bash bin/bg-backup.sh --config share/config/bg-backup.conf.example config validate --strict --no-perm-check

test: lint test-unit ## Hermetic gate: lint + unit tests (no Docker, no network)

check-all: lint format-check test-unit test-config ## Everything CI runs in ci.yml

# --- Integration rig (needs Docker) ------------------------------------------

rig-up: ## Start the throwaway MinIO repository backend
	BGB_UBUNTU_TAG=$(UBUNTU) bash tests/rig/up.sh

rig-down: ## Stop the rig and delete its volumes
	$(COMPOSE) down -v

rig-logs: ## Tail rig logs
	$(COMPOSE) logs -f --no-color

integration: rig-up ## Install end to end in a clean Ubuntu container (UBUNTU=22.04|24.04|26.04)
	$(COMPOSE) build victim
	$(COMPOSE) run --rm victim /opt/bgb/tests/e2e/installer.sh

docker-e2e: rig-up ## JOB_MODE=docker end to end against a real daemon (privileged)
	$(COMPOSE) build docker-victim
	$(COMPOSE) run --rm docker-victim /opt/bgb/tests/e2e/docker-stack.sh

dr-rehearse: rig-up ## Full disaster-recovery rehearsal: seed, back up, destroy, restore, assert
	$(COMPOSE) build victim phoenix
	$(COMPOSE) run --rm victim /opt/bgb/tests/e2e/dr-seed-and-backup.sh
	$(COMPOSE) rm -fsv victim
	$(COMPOSE) run --rm phoenix /opt/bgb/tests/e2e/dr-restore-and-assert.sh

# --- Docs and helpers --------------------------------------------------------

docs: ## Render README.md and SECURITY.md from docs/*.template.MD
	bash scripts/generate-docs.sh

recovery-sheet: ## Render the printable one-page recovery sheet
	bash scripts/render-recovery-sheet.sh

submodules: ## Ensure the vendored bats helpers are present
	@test -x $(BATS) || git submodule update --init --recursive

clean: ## Remove local build and test scratch
	rm -rf dist build .bats-tmp tests/rig/.data
