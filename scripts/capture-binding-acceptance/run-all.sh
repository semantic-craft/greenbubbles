#!/usr/bin/env bash
# =============================================================================
# run-all.sh — FINAL capture-binding acceptance kit (V1-V8 + CLI).
#
# Platform: macOS (Helios) with Swift 6 / Xcode toolchain.
# Run:  export GB_REPO=/path/to/patched/greenbubbles
#       export GB_CONFIG=Debug           # or Release; used for Products/ path
#       scripts/capture-binding-acceptance/run-all.sh
#
# Expected: SUMMARY fail=0 (exit 0). Each line prints RAN/NOT_RUN + exit.
#
# Packaging contract (maintainable; see README):
#   * Helpers ship as C SOURCE (helpers/pauser.c) and are compiled here with cc.
#   * The Swift acceptance file is TEMPORARILY installed into GB_REPO's test
#     target and removed again on exit by a trap, so a plain `swift test` in the
#     repo never breaks on a missing external helper.
#   * If the destination test path already exists in ANY form (regular file,
#     symlink, dangling symlink, directory) we REFUSE to run. No marker-based
#     re-claiming; move the file aside yourself and re-run.
#   * Cleanup deletes the installed file only if it is still byte-identical
#     (cmp -s) to the private copy of the bytes this run installed; otherwise it
#     is kept and the run reports an error. INT/TERM exit 130/143 after cleanup.
#   * No production sources, binaries, or machine-specific paths are vendored.
#
# Requires: GB_REPO already has the CURRENT production binding patches applied
#   (ProcessTargetBinding, uniqueProcessID, capture(binding:) no-retarget,
#    all-salt verify, SecretOutputWriter staged publish, CLI --pid/--executable-path/--db-root).
# Does NOT touch real WeChat. Does NOT invent production secrets.
# =============================================================================
set -u
PKG="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
. "$PKG/common.sh"

echo "== GB capture-binding acceptance (V1-V8 + CLI) =="
echo "pkg: $PKG"
echo "date: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# ---- build helpers from C source (always; cheap, verifiable on Linux too) ----
echo "== build helpers (C pauser + chmod stubs) =="
gbiso_build_helpers
export GBISO_HELPERS="$PKG/helpers"
export GBISO_PAUSER_BIN="$PKG/helpers/gbiso-pauser"
echo "helpers: $GBISO_HELPERS"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "NOT_RUN all :: this runner is $(uname -s); Swift V1-V8 require macOS (Helios)"
  echo "Helpers C compile was checked locally (cc)."
  echo "SUMMARY: pass=0 fail=0 not_run=8 (non-macOS box cannot execute Swift acceptance)"
  exit 0
fi

if [ -z "${GB_REPO:-}" ] || [ ! -d "${GB_REPO}/Sources/GreenBubblesAcquire" ]; then
  echo "error: set GB_REPO to a patched greenbubbles checkout" >&2
  exit 2
fi
GB_REPO="$(cd "$GB_REPO" && pwd)"
GB_CONFIG="${GB_CONFIG:-Debug}"
echo "GB_REPO=$GB_REPO"
echo "GB_CONFIG=$GB_CONFIG"

# ---- ensure production binding types present (API shape guards) ----
echo "== ensure production binding types present =="
for f in ProcessTargetBinding.swift WeChatProcessLocator.swift LLDBPassphraseCapture.swift SecretOutputWriter.swift; do
  if [ ! -f "$GB_REPO/Sources/GreenBubblesAcquire/$f" ]; then
    echo "missing Sources/GreenBubblesAcquire/$f - apply current production patches first" >&2
    exit 2
  fi
done
if ! grep -q 'uniqueProcessID(exactName' "$GB_REPO/Sources/GreenBubblesAcquire/WeChatProcessLocator.swift"; then
  echo "error: WeChatProcessLocator.uniqueProcessID(exactName:) not found" >&2; exit 2
fi
if ! grep -q 'binding: ProcessTargetBinding' "$GB_REPO/Sources/GreenBubblesAcquire/LLDBPassphraseCapture.swift"; then
  echo "error: LLDBPassphraseCapture.capture(binding:) not found" >&2; exit 2
fi
if grep -q 'waiting to re-attach to the new process' "$GB_REPO/Sources/GreenBubblesAcquire/LLDBPassphraseCapture.swift"; then
  echo "error: rejected round-2 re-attach loop still present; refuse to run" >&2; exit 2
fi
if grep -R -q 'anyDatabaseVerifies' "$GB_REPO/Sources/GreenBubblesAcquire" "$GB_REPO/Sources/GreenBubblesAcquireCLI" 2>/dev/null; then
  echo "error: rejected anyDatabaseVerifies policy still present; refuse to run" >&2; exit 2
fi

# ---- temporarily install the acceptance test into GB_REPO, restore on exit ----
DEST_DIR="$GB_REPO/Tests/GreenBubblesAcquireTests"
if [ ! -d "$DEST_DIR" ]; then
  echo "error: $DEST_DIR not found - is this the right GB_REPO?" >&2; exit 2
fi
DEST_TEST="$DEST_DIR/BindingAcceptanceV1V8Tests.swift"
INSTALLED_TEST=0
ORIG_COPY=""

# Refuse if the destination path exists in any form (incl. dangling symlink).
# No marker/header-based "this is ours" re-claiming, no idempotent overwrite.
if [ -e "$DEST_TEST" ] || [ -L "$DEST_TEST" ]; then
  echo "error: refusing to run: destination already exists: $DEST_TEST" >&2
  echo "       move it aside (or delete it yourself) and re-run." >&2
  exit 2
fi

# Remove the installed test only if it is still byte-identical to what this run
# installed. Returns non-zero if something had to be left in place.
cleanup() {
  local crc=0
  if [ "$INSTALLED_TEST" = "1" ]; then
    if [ -L "$DEST_TEST" ]; then
      echo "cleanup: ERROR: $DEST_TEST is now a symlink; left in place" >&2; crc=1
    elif [ -f "$DEST_TEST" ] && [ -n "$ORIG_COPY" ] && cmp -s "$DEST_TEST" "$ORIG_COPY"; then
      rm -f "$DEST_TEST" && echo "cleanup: removed temporarily installed $DEST_TEST" || crc=1
    elif [ -e "$DEST_TEST" ]; then
      echo "cleanup: ERROR: $DEST_TEST changed since install; left in place" >&2; crc=1
    else
      echo "cleanup: note: $DEST_TEST already gone"
    fi
    INSTALLED_TEST=0
  fi
  if [ -n "$ORIG_COPY" ]; then rm -f "$ORIG_COPY"; ORIG_COPY=""; fi
  return "$crc"
}
on_exit() {
  local rc=$?
  trap - EXIT
  set +e
  cleanup || { [ "$rc" -eq 0 ] && rc=1; }
  exit "$rc"
}
on_signal() {
  local code=$1
  trap - EXIT INT TERM
  set +e
  cleanup
  exit "$code"
}
trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

echo "== install acceptance test (temporary) =="
ORIG_COPY="$(mktemp "${TMPDIR:-/tmp}/gbiso-installed-test.XXXXXX")" || { echo "error: mktemp failed" >&2; exit 2; }
cp "$PKG/Tests/BindingAcceptanceV1V8Tests.swift" "$ORIG_COPY" || { echo "error: cannot stage test copy" >&2; exit 2; }
# noclobber: creation fails if the path appeared meanwhile (incl. a symlink).
if ! ( set -C; cat "$ORIG_COPY" > "$DEST_TEST" ); then
  echo "error: could not create $DEST_TEST exclusively (appeared meanwhile?); not touching it" >&2
  exit 2
fi
INSTALLED_TEST=1
echo "installed (temp): $DEST_TEST"

# ---- build + run ----
echo "== build package (GB_CONFIG=$GB_CONFIG) =="
swift_cfg=debug
case "$GB_CONFIG" in [Rr]elease) swift_cfg=release ;; esac
( cd "$GB_REPO" && swift build -c "$swift_cfg" --product greenbubbles-acquire ) || { echo "BUILD FAILED"; exit 1; }

ACQUIRE_BIN="$(gbiso_find_acquire_bin)" || ACQUIRE_BIN=""
if [ -n "$ACQUIRE_BIN" ]; then
  export GBISO_ACQUIRE_BIN="$ACQUIRE_BIN"; echo "acquire bin: $GBISO_ACQUIRE_BIN"
else
  echo "note: greenbubbles-acquire binary not found via Products/ or show-bin-path; CLI checks will NOT_RUN"
fi

pass=0; fail=0; not_run=0

echo "== Swift Testing V1-V8 =="
export GBISO_HELPERS GBISO_PAUSER_BIN
set +e
( cd "$GB_REPO" && swift test --filter BindingAcceptanceV1V8Tests --no-parallel )
swift_rc=$?
set -e
if [ "$swift_rc" -eq 0 ]; then gbiso_print_ran "swift-V1-V8" 0; pass=$((pass + 1));
else gbiso_print_ran "swift-V1-V8" "$swift_rc"; fail=$((fail + 1)); fi

echo "== CLI checks =="
for script in missing-args.sh binding-fail.sh v1-ambiguous.sh v2-success.sh; do
  set +e; out="$("$PKG/cli/$script" 2>&1)"; rc=$?; set -e
  echo "$out"
  if echo "$out" | grep -q '^NOT_RUN'; then not_run=$((not_run + 1))
  elif [ "$rc" -eq 0 ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); fi
done

echo "----"
echo "SUMMARY: pass=$pass fail=$fail not_run=$not_run"
[ "$fail" -eq 0 ] && exit 0 || exit 1
