#!/usr/bin/env bash
# =============================================================================
# Start the rig backend and prove the bucket policy was really applied
# =============================================================================
# `docker compose up -d --wait minio minio-init` looks like the obvious command
# and is wrong: --wait waits for services to be RUNNING or HEALTHY, and a
# run-to-completion service can be neither. Compose reports
#     container <p>-minio-init-1 exited (0)
# and returns 1 - on a successful init. Locally that was masked by shell
# invocations that discarded the status; CI, which uses `bash -e`, failed every
# integration run on it.
#
# So: --wait for minio only, then start the one-shot and inspect its exit code
# ourselves. That also lets us do the thing --wait could never do - say WHAT
# went wrong, by printing the init log on failure.
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
    exited:0) echo "rig ready (bucket and scoped policy in place)"; exit 0 ;;
    exited:*)
      echo "rig: minio-init FAILED (${state}) - the bucket or the scoped policy was not created" >&2
      "${COMPOSE[@]}" logs minio-init | tail -30 >&2
      exit 1 ;;
  esac
  sleep 1
done

echo "rig: minio-init did not finish within ${TIMEOUT}s (last state: ${state:-unknown})" >&2
"${COMPOSE[@]}" logs minio-init | tail -30 >&2
exit 1
