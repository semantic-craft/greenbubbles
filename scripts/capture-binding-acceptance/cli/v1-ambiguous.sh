#!/usr/bin/env bash
# Case V1 (CLI path): ambiguousTargets is surfaced by WeChatProcessLocator.uniqueProcessID,
# not by the CLI (CLI always requires --pid). This script documents that and defers to
# the Swift V1 test. Optional: if a future CLI entry calls uniqueProcessID without --pid,
# extend here.
#
# Platform: macOS. Run: ./cli/v1-ambiguous.sh
# Expected: NOT_RUN (library V1 covers the contract) unless GBISO_FORCE_CLI_V1=1.
set -u
PKG="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../common.sh
. "$PKG/common.sh"

if [ "${GBISO_FORCE_CLI_V1:-}" != "1" ]; then
  gbiso_print_not_run "cli-v1-ambiguous" \
    "CLI requires --pid; ambiguousTargets is covered by Swift V1 (uniqueProcessID). Set GBISO_FORCE_CLI_V1=1 only if a locator-without-pid CLI path exists."
  exit 0
fi

gbiso_print_not_run "cli-v1-ambiguous" "no CLI path currently surfaces ambiguousTargets without --pid"
exit 0
