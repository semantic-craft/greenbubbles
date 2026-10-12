#!/usr/bin/env bash
# Template: target-exit stub. Platform: macOS. See fake-lldb.sh.
DIR="$(cd "$(dirname "$0")" && pwd)"
export GBISO_LLDB_MODE=exit
exec "$DIR/fake-lldb.sh" "$@"
