#!/usr/bin/env bash
# Case: CLI missing required args → exit 2
# Platform: macOS (Helios). Touches NO WeChat.
# Run:  GB_REPO=/path/to/patched/greenbubbles ./cli/missing-args.sh
# Expected exit of this wrapper: 0 if all subchecks match; 1 otherwise.
# Subcheck expected CLI exit codes: 2 (missing args / invalid option).
set -u
PKG="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../common.sh
. "$PKG/common.sh"

BIN="$(gbiso_find_acquire_bin)" || {
  gbiso_print_not_run "cli-missing-args" "set GB_REPO (patched) or GBISO_ACQUIRE_BIN"
  exit 0
}

fail=0
run() {
  local name="$1" want="$2"
  shift 2
  "$BIN" "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$want" ]; then
    gbiso_print_ran "$name" "$rc" "want $want" PASS
  else
    gbiso_print_ran "$name" "$rc" "want $want" FAIL
    fail=1
  fi
}

run cli-missing-pid    2 capture --executable-path /nope --db-root /tmp/gbiso-never/db_storage --output /tmp/gbiso-never/out
run cli-missing-output 2 capture --pid 999999 --executable-path /nope --db-root /tmp/gbiso-never/db_storage
run cli-unknown-option 2 capture --bogus-switch
run cli-help           0 help

exit "$fail"
