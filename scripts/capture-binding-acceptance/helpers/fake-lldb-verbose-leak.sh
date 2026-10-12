#!/usr/bin/env bash
# Template: verbose leak stub (synthetic 64-hex + hexdump). Platform: macOS.
DIR="$(cd "$(dirname "$0")" && pwd)"
export GBISO_LLDB_MODE=verbose
exec "$DIR/fake-lldb.sh" "$@"
