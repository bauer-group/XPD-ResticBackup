#!/usr/bin/env bash
# =============================================================================
# Start the rig backend and PROVE the declarative init really took effect
# =============================================================================
# `docker compose up -d --wait minio minio-init` looks like the obvious command
# and is wrong: --wait waits for services to be RUNNING or HEALTHY, and a
# run-to-completion service can be neither. Compose reports
#     container <p>-minio-init-1 exited (0)
# and returns 1 - on a successful init. Locally that was masked by shell
# invocations that discarded the status; CI, which uses `bash -e`, failed every
# integration run on it.
#
# WHY THIS SCRIPT DOES MORE THAN WAIT. The init container is declarative and
# idempotent, but it is not fail-fast: tasks/02_policies.py logs a failed
# `mc admin policy create` in red and moves on WITHOUT raising, and main.py
# counts only raised exceptions as failures. A rig whose policy never applied
# therefore exits 0 and looks perfect. Everything downstream - every
# least-privilege assertion in every e2e suite - would then be measuring an
# account with whatever permissions it happened to have.
#
# So the exit code is treated as necessary, never sufficient: afterwards the
# users and their attached policies are read BACK OFF THE SERVER. The
# verification runs inside the init image because that is where `mc` lives; the
# host needs nothing but docker.
# =============================================================================

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

COMPOSE=(docker compose -f tests/rig/docker-compose.yml)
TIMEOUT="${BGB_RIG_TIMEOUT:-120}"

"${COMPOSE[@]}" up -d --wait minio || {
  echo "rig: MinIO did not become healthy" >&2
  "${COMPOSE[@]}" logs minio | tail -30 >&2
  exit 1
}

# The rest-server is part of the BACKEND, so it belongs here rather than in a
# victim's depends_on. `docker compose run victim` starts only that service's
# dependencies, and a rest-server listed nowhere simply never runs - which
# surfaces as restic failing with
#     dial tcp: lookup rest-server on 127.0.0.11:53: no such host
# in the middle of a copy, reading like a container networking fault rather than
# a service that was never asked to start.
"${COMPOSE[@]}" up -d rest-server >/dev/null || {
  echo "rig: could not start the append-only rest-server" >&2
  "${COMPOSE[@]}" logs rest-server | tail -30 >&2
  exit 1
}

"${COMPOSE[@]}" up -d minio-init >/dev/null || {
  echo "rig: could not start minio-init" >&2
  exit 1
}

# Poll rather than `docker compose wait`, which only exists in newer Compose
# releases and would make the rig depend on the developer's version.
state=""
for _ in $(seq 1 "${TIMEOUT}"); do
  state="$("${COMPOSE[@]}" ps -a --format '{{.Service}} {{.State}} {{.ExitCode}}' 2>/dev/null \
    | awk '$1 == "minio-init" { print $2 ":" $3 }')"
  case "${state}" in
    exited:0) break ;;
    exited:*)
      echo "rig: minio-init FAILED (${state}) - the bucket or the scoped policy was not created" >&2
      "${COMPOSE[@]}" logs minio-init | tail -40 >&2
      exit 1
      ;;
  esac
  sleep 1
done

if [ "${state}" != "exited:0" ]; then
  echo "rig: minio-init did not finish within ${TIMEOUT}s (last state: ${state:-unknown})" >&2
  "${COMPOSE[@]}" logs minio-init | tail -40 >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Read the result back off the server
# -----------------------------------------------------------------------------
# --no-deps: minio is healthy and minio-init has already run; without it compose
# would start the whole dependency chain again for a read-only check.
#
# The policy name is matched WITH ITS SURROUNDING QUOTES against mc's JSON
# output. Matching the bare name would let 'bgb-scoped' also match
# 'bgb-scoped-prune' - and a rig that attached the PRUNE policy to the BACKUP
# identity is precisely the mix-up that would make ADR-0005's separation
# untestable while every assertion still passed.
verify='
set -u
mc alias set rig "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1 || {
  echo "FATAL: cannot reach ${MINIO_ENDPOINT} as root" >&2; exit 1; }

mc ls "rig/${BGB_IT_BUCKET}" >/dev/null 2>&1 || {
  echo "FATAL: bucket ${BGB_IT_BUCKET} does not exist" >&2; exit 1; }

fail=0
check_user() {
  _user="$1"; _policy="$2"
  _info="$(mc --json admin user info rig "${_user}" 2>&1)" || {
    echo "FATAL: user ${_user} was not created" >&2
    echo "  ${_info}" >&2
    fail=1
    return
  }
  case "${_info}" in
    *"\"${_policy}\""*) echo "  ok  ${_user} -> ${_policy}" ;;
    *)
      echo "FATAL: policy ${_policy} is NOT attached to ${_user}" >&2
      echo "  ${_info}" >&2
      fail=1
      ;;
  esac
}

check_user "${BGB_IT_ACCESS_KEY}"       bgb-scoped
check_user "${BGB_IT_PRUNE_ACCESS_KEY}" bgb-scoped-prune

exit "${fail}"
'

if ! "${COMPOSE[@]}" run --rm --no-deps --entrypoint sh minio-init -c "${verify}"; then
  echo "rig: the declarative init reported success but the server disagrees." >&2
  echo "rig: see tests/rig/minio-init.json - and note that a failed policy does" >&2
  echo "rig: NOT make the init container exit non-zero." >&2
  "${COMPOSE[@]}" logs minio-init | tail -40 >&2
  exit 1
fi

echo "rig ready (bucket, two scoped identities, verified against the server)"
