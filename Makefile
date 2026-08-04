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
# 26.04 matches .github/workflows/integration.yml, which runs this rig on that
# release and only that release. Override for a one-off check on an older base
# (`make integration UBUNTU=22.04`); the standing 5.1 cover is the `bash51` job
# in ci.yml, which parses every script against bash 5.1 in twenty seconds.
UBUNTU   ?= 26.04
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

.PHONY: help version lint format format-check test test-unit test-config bash51 \
        rig-up rig-down rig-logs integration maintenance recovery scheduling notify docker-e2e \
        db-engines dr-rehearse e2e docs recovery-sheet submodules clean check-all

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

bash51: ## Parse every shell file with bash 5.1 (the oldest supported)
	@# Mirrors the `bash51` job in ci.yml. The e2e rig runs 26.04 only, so this
	@# is the ONLY thing standing between a ${var@U} and a dead 22.04 host.
	@mapfile -t files < <(git ls-files '*.sh' '*.bash'); \
	docker run --rm -v "$(PWD):/src:ro" -w /src ubuntu:22.04 bash -c '\
	  bash --version | head -1; rc=0; \
	  for f in "$$@"; do bash -n "$$f" || { echo "not parseable by bash 5.1: $$f"; rc=1; }; done; \
	  exit $$rc' _ "$${files[@]}"

test: lint test-unit ## Hermetic gate: lint + unit tests (no Docker, no network)

check-all: lint format-check test-unit test-config ## Everything CI runs in ci.yml

# --- Integration rig (needs Docker) ------------------------------------------

rig-up: ## Start the throwaway MinIO repository backend
	BGB_UBUNTU_TAG=$(UBUNTU) bash tests/rig/up.sh

rig-down: ## Stop the rig and delete its volumes
	$(COMPOSE) down -v

rig-logs: ## Tail rig logs
	$(COMPOSE) logs -f --no-color

integration: rig-up ## Install end to end in a clean Ubuntu container
	$(COMPOSE) build victim
	$(COMPOSE) run --rm victim /opt/bgb/tests/e2e/installer.sh

maintenance: rig-up ## check, verify, forget, prune, copy - and the ADR-0005 identity split
	@# The one suite that proves the least-privilege claim rather than asserting
	@# it: it authenticates as the BACKUP identity and demands that the backend
	@# refuse the delete, then repeats it as the PRUNE identity and demands that
	@# it succeed. Also covers JOB_MODE=config and the append-only copy target.
	$(COMPOSE) build victim
	$(COMPOSE) run --rm victim /opt/bgb/tests/e2e/maintenance.sh

scheduling: rig-up ## schedule sync/enable/disable/list and the generated units
	@# lib/systemd.sh is the largest module here and had zero coverage. It
	@# generates the units through which every backup, check and prune is
	@# invoked, so a defect produces no backup at all - and nothing alerts on a
	@# timer that never fires.
	$(COMPOSE) build victim
	$(COMPOSE) run --rm victim /opt/bgb/tests/e2e/scheduling.sh

notify: rig-up ## prove an alert actually leaves the host
	@# Points the webhook, Teams and Kuma URLs at the rig's throwaway HTTP sink
	@# and reads the recording back. A dead notifier produces SILENCE, which is
	@# indistinguishable from success - the worst thing to leave untested.
	$(COMPOSE) build victim
	$(COMPOSE) run --rm victim /opt/bgb/tests/e2e/notify.sh

recovery: rig-up ## restore preview/system and dr plan/run/verify
	@# Half of what this asserts is INERTNESS: preview must write nothing,
	@# `dr plan` must write nothing, `dr run --dry-run` must change nothing.
	@# Each is fingerprinted around rather than merely checked for exit 0.
	$(COMPOSE) build victim
	$(COMPOSE) run --rm victim /opt/bgb/tests/e2e/recovery.sh

docker-e2e: rig-up ## JOB_MODE=docker end to end against a real daemon (privileged)
	$(COMPOSE) build docker-victim
	$(COMPOSE) run --rm docker-victim /opt/bgb/tests/e2e/docker-stack.sh

db-engines: rig-up ## Every supported database engine, dumped consistently (privileged)
	$(COMPOSE) build docker-victim
	$(COMPOSE) run --rm docker-victim /opt/bgb/tests/e2e/db-engines.sh

dr-rehearse: rig-up ## Full disaster-recovery rehearsal: seed, back up, destroy, restore, assert
	$(COMPOSE) build victim phoenix
	$(COMPOSE) run --rm victim /opt/bgb/tests/e2e/dr-seed-and-backup.sh
	$(COMPOSE) rm -fsv victim
	$(COMPOSE) run --rm phoenix /opt/bgb/tests/e2e/dr-restore-and-assert.sh

# EACH SUITE GETS A FRESH RIG, hence the rig-down between them rather than one
# rig-up at the top. The suites assert exact snapshot counts against a single
# repository prefix, and an interrupted restic run leaves a lock behind; sharing
# one backend makes them read each other's snapshots and each other's debris.
# integration.yml gets this for free by putting each suite on its own runner.
e2e: ## Every e2e suite in sequence, each against its own fresh rig
	$(MAKE) rig-down || true
	$(MAKE) integration
	$(MAKE) rig-down
	$(MAKE) maintenance
	$(MAKE) rig-down
	$(MAKE) recovery
	$(MAKE) rig-down
	$(MAKE) scheduling
	$(MAKE) rig-down
	$(MAKE) notify
	$(MAKE) rig-down
	$(MAKE) docker-e2e
	$(MAKE) rig-down
	$(MAKE) db-engines
	$(MAKE) rig-down
	$(MAKE) dr-rehearse
	$(MAKE) rig-down

# --- Docs and helpers --------------------------------------------------------

docs: ## Where the generated documentation comes from
	@# scripts/generate-docs.sh never existed - this target pointed at a file
	@# that was not in the repository, which is the same class of defect as a
	@# dispatcher sourcing a module nobody wrote. Rendering happens in CI, in the
	@# shared documentation module, and there is nothing local to run.
	@printf '\n  README.MD is GENERATED from docs/README.template.MD by\n'
	@printf '  .github/workflows/documentation.yml on every push to main.\n\n'
	@printf '  Edit  docs/README.template.MD  - not README.MD, which is overwritten.\n'
	@printf '  The .MD extension is upper case on purpose: the shared module\n'
	@printf '  validates for exactly that name and fails on README.md.\n\n'
	@printf '  SECURITY.md and the docs/ tree are hand-written and are not generated.\n\n'

recovery-sheet: ## Print the one-page recovery sheet (needs a configured host)
	@# This called scripts/render-recovery-sheet.sh, which does not exist - and
	@# neither does scripts/. The renderer was never missing: it is
	@# secrets_render_sheet() in lib/secrets.sh, reached through the CLI below.
	@# The target simply pointed at the wrong thing and failed with "No such
	@# file or directory", which reads like a broken checkout.
	@#
	@# It needs the host's real configuration - repository URL, repository ID,
	@# bundle location and checksum - so it runs on a configured machine, not in
	@# a working tree. Redirect it to a file with --out.
	bash bin/bg-backup.sh secrets print-recovery-card

submodules: ## Ensure the vendored bats helpers are present
	@test -x $(BATS) || git submodule update --init --recursive

clean: ## Remove local build and test scratch
	rm -rf dist build .bats-tmp tests/rig/.data
