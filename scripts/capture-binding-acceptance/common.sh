#!/usr/bin/env bash
# Shared helpers for V1–V8 acceptance scripts.
# Platform: macOS (Helios). Sourced by run-all.sh and cli/*.sh.
set -u

gbiso_pkg_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# Refuse to delete anything that is not a unique $TMPDIR/gbiso-<id>/ we created.
gbiso_safe_rm() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo "cleanup refused: empty path" >&2
    return 2
  fi
  local resolved
  resolved="$(cd "$target" 2>/dev/null && pwd -P)" || resolved="$target"
  local tmp="${TMPDIR:-/tmp}"
  tmp="$(cd "$tmp" 2>/dev/null && pwd -P)" || tmp="/tmp"
  local base
  base="$(basename "$resolved")"
  case "$resolved" in
    ""|"/"|"$tmp")
      echo "cleanup refused: unsafe path '$resolved'" >&2
      return 2
      ;;
  esac
  case "$base" in
    gbiso-*) ;;
    *)
      echo "cleanup refused: missing gbiso marker in '$resolved'" >&2
      return 2
      ;;
  esac
  case "$resolved" in
    "$tmp"/gbiso-*) ;;
    *)
      echo "cleanup refused: not under TMPDIR/gbiso- ('$resolved')" >&2
      return 2
      ;;
  esac
  rm -rf "$resolved"
}

# Discover greenbubbles-acquire. Never hardcode .build/debug.
# Prefers Xcode new-build-system Products/$GB_CONFIG, then swift build --show-bin-path.
gbiso_find_acquire_bin() {
  local repo="${GB_REPO:-}"
  local config="${GB_CONFIG:-Debug}"
  if [ -n "${GBISO_ACQUIRE_BIN:-}" ] && [ -x "${GBISO_ACQUIRE_BIN}" ]; then
    printf '%s\n' "$GBISO_ACQUIRE_BIN"
    return 0
  fi
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    return 1
  fi
  local cand
  for cand in \
    "$repo/.build/out/Products/$config/greenbubbles-acquire" \
    "$repo/.build/out/Products/Debug/greenbubbles-acquire" \
    "$repo/.build/out/Products/Release/greenbubbles-acquire"
  do
    if [ -x "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  # Map GB_CONFIG Debug|Release → swift -c debug|release
  local swift_cfg
  case "$config" in
    [Rr]elease) swift_cfg=release ;;
    *) swift_cfg=debug ;;
  esac
  local bin_path
  if bin_path="$(cd "$repo" && swift build --show-bin-path -c "$swift_cfg" 2>/dev/null)"; then
    cand="$bin_path/greenbubbles-acquire"
    if [ -x "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  fi
  return 1
}

gbiso_build_helpers() {
  local root
  root="$(gbiso_pkg_root)"
  local helpers="$root/helpers"
  if [ ! -x "$helpers/gbiso-pauser" ] || [ "$helpers/pauser.c" -nt "$helpers/gbiso-pauser" ]; then
    cc -O0 -o "$helpers/gbiso-pauser" "$helpers/pauser.c"
  fi
  chmod +x "$helpers"/fake-lldb*.sh
  export GBISO_HELPERS="$helpers"
  export GBISO_PAUSER_BIN="$helpers/gbiso-pauser"
}

# Print RAN result. Optional 4th arg is PASS|FAIL; otherwise derive from rc==0.
# For expected non-zero CLI exits, pass PASS when rc matches want (see missing-args.sh).
gbiso_print_ran() {
  local id="$1" rc="$2" note="${3:-}" verdict="${4:-}"
  if [ -z "$verdict" ]; then
    if [ "$rc" -eq 0 ]; then verdict=PASS; else verdict=FAIL; fi
  fi
  echo "RAN $id exit=$rc $verdict${note:+ :: $note}"
}

gbiso_print_not_run() {
  local id="$1" reason="$2"
  echo "NOT_RUN $id :: $reason"
}
