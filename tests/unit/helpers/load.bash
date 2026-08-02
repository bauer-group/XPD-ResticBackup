# =============================================================================
# bg-backup - bats helper: load a library under test into a hermetic sandbox
# =============================================================================
# shellcheck shell=bash
#
# Deliberately has NO shebang and is NOT executable: bats sources it
# (`load 'helpers/load'`), it is never run. The `shell=bash` directive above is
# what tells shellcheck how to parse the file, and it keeps the
# check-shebang-scripts-are-executable pre-commit hook quiet without lying about
# the file's nature.
#
# WHY A SANDBOX AT ALL
# --------------------
# Every lib/*.sh reads its paths from BGB_* globals whose defaults are /etc,
# /var/lib, /var/log and /run/lock. A unit test that forgot to override even one
# of them would either need root or would quietly write into the developer's
# real installation - and that failure looks like a flaky test, never like a bug
# in the harness. So the sandbox is unconditional, is rebuilt per test, and
# every path-shaped global is pointed inside it before any library is sourced.
#
# WHY THE LIBRARIES ARE SOURCED RATHER THAN EXERCISED THROUGH bin/bg-backup.sh
# ---------------------------------------------------------------------------
# The entrypoint sets `set -euo pipefail`; the modules must not. Sourcing them
# directly is the only way to prove that they behave under the shell options
# bats itself uses, which is also the configuration `bg-backup doctor` and every
# hook subshell runs them in.
# =============================================================================

# -----------------------------------------------------------------------------
# stat shim - makes BOTH config permission gates reachable from ANY uid
# -----------------------------------------------------------------------------
# config_require_perms() checks `stat -c %u` (ownership) BEFORE `stat -c %a`
# (mode). That ordering makes one of the two gates untestable in any given
# environment, and untestable *silently*:
#
#   * as an unprivileged user  - every file the suite creates is owned by that
#     user, so the ownership gate always fires first and the MODE branch is
#     never reached. A test asserting "0644 is refused" would pass for entirely
#     the wrong reason.
#   * as root (CI containers)  - every file is root-owned, so the OWNERSHIP
#     branch is never reached at all.
#
# Shadowing `stat` with a shell function is the smallest change that makes both
# branches reachable in both environments. It is inert until a test sets
# BGB_TEST_FAKE_UID, and it never fakes the MODE: that assertion is always made
# against a real chmod on a real file, because the mode check is the one doing
# the security work.
BGB_TEST_FAKE_UID=""
stat() {
  if [ -n "${BGB_TEST_FAKE_UID}" ] && [ "${1:-}" = "-c" ] && [ "${2:-}" = "%u" ]; then
    printf '%s\n' "${BGB_TEST_FAKE_UID}"
    return 0
  fi
  command stat "$@"
}

# -----------------------------------------------------------------------------
# Sandbox
# -----------------------------------------------------------------------------

# bgb_setup - call first from every setup(). Creates the sandbox, pins every
# BGB_* global that a library reads, and loads the bats assertion helpers.
#
# shellcheck disable=SC2034  # these are consumed by the .bats files, not here
bgb_setup() {
  BGB_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BGB_LIB_DIR="${BGB_REPO_ROOT}/lib"
  BGB_SHARE_DIR="${BGB_REPO_ROOT}/share"
  BGB_BIN="${BGB_REPO_ROOT}/bin/bg-backup.sh"
  BGB_FIXTURE_DIR="${BGB_REPO_ROOT}/tests/fixtures"
  BGB_VERSION="$(tr -d ' \r\n' <"${BGB_REPO_ROOT}/VERSION" 2>/dev/null || printf '0.0.0-test')"

  BGB_TEST_TMP="$(mktemp -d "${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/bgb.XXXXXX")"

  BGB_CONFDIR="${BGB_TEST_TMP}/etc/bg-backup"
  BGB_STATE_DIR="${BGB_TEST_TMP}/var/lib/bg-backup/state"
  BGB_CACHE_DIR="${BGB_TEST_TMP}/var/lib/bg-backup/cache"
  BGB_TMP_DIR="${BGB_TEST_TMP}/var/lib/bg-backup/tmp"
  BGB_LOG_DIR="${BGB_TEST_TMP}/var/log/bg-backup"
  BGB_LOCK_ROOT="${BGB_TEST_TMP}/run/lock/bg-backup"
  mkdir -p \
    "${BGB_CONFDIR}/conf.d" "${BGB_CONFDIR}/credentials" "${BGB_CONFDIR}/excludes" \
    "${BGB_STATE_DIR}" "${BGB_CACHE_DIR}" "${BGB_TMP_DIR}" "${BGB_LOG_DIR}" "${BGB_LOCK_ROOT}"

  # Deterministic and non-interactive. Assertions are made against the exact
  # bytes these functions print, so colour must be off regardless of whether the
  # runner happens to give bats a TTY.
  BGB_COLOR="never"
  BGB_LOG_LEVEL="info"
  BGB_QUIET=0
  BGB_JSON=0
  BGB_DRY_RUN=0
  BGB_YES=0
  BGB_NO_LOCK=0
  BGB_PARALLEL_JOBS=0
  BGB_COMMAND="test"
  BGB_JOB=""
  BGB_CONFIG_FILE=""
  BGB_TEST_FAKE_UID=""

  # A fixed, non-resolvable FQDN. Never the real hostname: `forget` scoping and
  # snapshot tags are asserted literally, and a test that passes only on the
  # machine that wrote it is worse than no test.
  BGB_HOSTNAME="victim.rig.invalid"

  bgb_load_bats_libs
}

# bgb_teardown - call from every teardown().
bgb_teardown() {
  if [ -n "${BGB_TEST_TMP:-}" ] && [ -d "${BGB_TEST_TMP}" ]; then
    # chmod first: the permission-gate tests deliberately leave 0400 files and
    # 0500 directories behind, and rm would otherwise fail as a normal user.
    chmod -R u+rwX "${BGB_TEST_TMP}" 2>/dev/null || true
    rm -rf "${BGB_TEST_TMP}"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Loading
# -----------------------------------------------------------------------------

bgb_load_bats_libs() {
  local helper="${BGB_REPO_ROOT}/tests/helper" lib
  # Order is load-bearing: bats-assert and bats-file both build on the output
  # formatting primitives that bats-support defines.
  for lib in bats-support bats-assert bats-file; do
    if [ ! -r "${helper}/${lib}/load.bash" ]; then
      printf 'missing bats helper: %s\n' "${helper}/${lib}" >&2
      printf 'run: git submodule update --init --recursive\n' >&2
      return 1
    fi
    # shellcheck source=/dev/null
    . "${helper}/${lib}/load.bash"
  done
}

# bgb_load_lib <name...> - source lib/<name>.sh, in the order given.
# The caller states the dependency order explicitly (core first, always)
# because that is exactly what bin/bg-backup.sh does, and a test that loads
# modules in an order the product never uses proves nothing about the product.
bgb_load_lib() {
  local name
  for name in "$@"; do
    # shellcheck source=/dev/null
    . "${BGB_LIB_DIR}/${name}.sh"
  done
}

# bgb_skip_without <command> - skip when an optional dependency is absent.
# Used ONLY for jq. jq is a hard dependency of every command that parses
# restic's output, but not of a backup or a restore, so the suite must still be
# runnable on a machine without it.
bgb_skip_without() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || skip "requires ${cmd}"
}

# -----------------------------------------------------------------------------
# Fixtures and files
# -----------------------------------------------------------------------------

bgb_fixture() { printf '%s/%s' "${BGB_FIXTURE_DIR}" "$1"; }

# bgb_put_conf <path> [mode] - write stdin to a configuration file.
# Always sets an explicit mode: config_require_perms() reads it, and inheriting
# whatever umask the runner happened to have would make the permission tests
# non-deterministic across CI images.
bgb_put_conf() {
  local path="$1" mode="${2:-0640}" dir
  dir="$(dirname "${path}")"
  mkdir -p "${dir}"
  cat >"${path}"
  chmod "${mode}" "${path}"
}

# -----------------------------------------------------------------------------
# argv assertions
# -----------------------------------------------------------------------------
# The argv builders emit ONE ARGUMENT PER LINE so callers can mapfile them into
# an array without word-splitting a path that contains a space. These helpers
# assert against that array, never against a flattened string: `--tag job=x`
# appearing in a joined string proves nothing about whether it survived as two
# adjacent argv entries.

# bgb_argv_index <needle> <argv...> - prints the index, non-zero when absent.
bgb_argv_index() {
  local needle="$1"
  shift
  local i=0 a
  for a in "$@"; do
    if [ "${a}" = "${needle}" ]; then
      printf '%s' "${i}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# bgb_argv_has <needle> <argv...>
bgb_argv_has() { bgb_argv_index "$@" >/dev/null; }

# bgb_argv_has_pair <flag> <value> <argv...> - flag IMMEDIATELY followed by
# value. Adjacency is the whole point: `--host` and the FQDN both being present
# somewhere in the list is not the same thing as restic receiving them together.
bgb_argv_has_pair() {
  local flag="$1" value="$2"
  shift 2
  local -a argv=("$@")
  local i=0
  while [ "${i}" -lt "${#argv[@]}" ]; do
    if [ "${argv[i]}" = "${flag}" ] && [ "${argv[i + 1]:-}" = "${value}" ]; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# -----------------------------------------------------------------------------
# Secret assertions
# -----------------------------------------------------------------------------

# bgb_refute_secret <haystack> <secret...> - non-zero if any secret is present.
# Substring, not regex: a secret must not appear at all, in any framing.
bgb_refute_secret() {
  local haystack="$1"
  shift
  local s
  for s in "$@"; do
    [ -z "${s}" ] && continue
    case "${haystack}" in
      *"${s}"*)
        printf 'secret leaked into the checked text: %s\n' "${s}" >&2
        return 1
        ;;
    esac
  done
  return 0
}

# -----------------------------------------------------------------------------
# Function resolution for modules this suite does not own
# -----------------------------------------------------------------------------
# bgb_require_fn <purpose> <candidate...> - print the first candidate that is
# defined, or fail loudly naming every name that was tried.
#
# Used only by retention.bats. The retention module is written against the
# contract documented in tests/README.md; if it lands under a different function
# name the suite must say so in one line rather than silently skipping - a
# skipped safety-rail test is indistinguishable from a passing one on a
# dashboard, and these are the rails guarding the only irreversible code path in
# the tool.
bgb_require_fn() {
  local purpose="$1"
  shift
  local fn
  for fn in "$@"; do
    if declare -F "${fn}" >/dev/null 2>&1; then
      printf '%s' "${fn}"
      return 0
    fi
  done
  printf 'no function found for: %s\n' "${purpose}" >&2
  printf 'tried: %s\n' "$*" >&2
  return 1
}
