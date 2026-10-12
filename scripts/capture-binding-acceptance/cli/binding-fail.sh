#!/usr/bin/env bash
# Case: CLI binding failure → exit 4 (pathMismatch / processGone / etc.)
# Platform: macOS (Helios). Uses synthetic pauser — NEVER WeChat.
# Run:  GB_REPO=... ./cli/binding-fail.sh
# Expected: CLI exit 4; this wrapper exit 0 on PASS.
set -u
PKG="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../common.sh
. "$PKG/common.sh"

BIN="$(gbiso_find_acquire_bin)" || {
  gbiso_print_not_run "cli-binding-fail" "set GB_REPO (patched) or GBISO_ACQUIRE_BIN"
  exit 0
}

gbiso_build_helpers

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gbiso-cliXXXXXX")"
# mktemp may not include gbiso- prefix depending on template; normalize:
if [[ "$(basename "$WORKDIR")" != gbiso-* ]]; then
  NEW="${TMPDIR:-/tmp}/gbiso-cli-$(basename "$WORKDIR")"
  mv "$WORKDIR" "$NEW"
  WORKDIR="$NEW"
fi
PID=""
cleanup() {
  if [ -n "${PID:-}" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  gbiso_safe_rm "$WORKDIR" || true
}
trap cleanup EXIT

mkdir -p "$WORKDIR/db_storage"
DB="$WORKDIR/db_storage/message_0.db"
printf 'x\n' >"$DB"
EXE="$WORKDIR/gbiso-target"
cp "$GBISO_PAUSER_BIN" "$EXE"
chmod 755 "$EXE"

"$EXE" "$DB" &
PID=$!
sleep 0.5

# Wrong executable path → pathMismatch → exit 4. No debugger attach (preflight/bind fails first).
OUT="$WORKDIR/should-not-exist.secret"
CLI_OUT="$WORKDIR/cli-binding.out"
CLI_ERR="$WORKDIR/cli-binding.err"
set +e
"$BIN" capture \
  --pid "$PID" \
  --executable-path "$GBISO_PAUSER_BIN" \
  --db-root "$WORKDIR/db_storage" \
  --output "$OUT" >"$CLI_OUT" 2>"$CLI_ERR"
rc=$?
set -e

if [ -f "$OUT" ]; then
  gbiso_print_ran "cli-binding-fail" 1 "output file was created (must not)" FAIL
  exit 1
fi

# Exit 4 = ProcessBindingError (non-ambiguous). Also accept 1 if preflight blocked first
# after a successful bind — but with wrong path, bind must fail with 4.
err="$(cat "$CLI_ERR" 2>/dev/null || true)"
if [ "$rc" = "4" ] && echo "$err" | grep -q "pathMismatch"; then
  gbiso_print_ran "cli-binding-fail" 0 "CLI exit=4 pathMismatch" PASS
  exit 0
fi
gbiso_print_ran "cli-binding-fail" 1 "CLI exit=$rc (want 4 pathMismatch); err=$err" FAIL
exit 1
