#!/usr/bin/env bash
# Case V2 (CLI path): full CLI capture requires root + real preflight (lldb, hardening).
# Synthetic pauser cannot satisfy WeChat preflight. Library V2 covers capture(binding:).
#
# Platform: macOS. Run: ./cli/v2-success.sh
# Expected: NOT_RUN (library V2 is the acceptance path for synthetic targets).
set -u
PKG="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../common.sh
. "$PKG/common.sh"

gbiso_print_not_run "cli-v2-success" \
  "CLI capture preflight requires WeChat hardening checks; synthetic V2 is Swift capture(binding:)+stub lldb"
exit 0
