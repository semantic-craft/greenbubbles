#!/usr/bin/env bash
# Template: attach-failure stub (V7 capture failure path). Platform: macOS.
DIR="$(cd "$(dirname "$0")" && pwd)"
export GBISO_LLDB_MODE=attachfail
exec "$DIR/fake-lldb.sh" "$@"
