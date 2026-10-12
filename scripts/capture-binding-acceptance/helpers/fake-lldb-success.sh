#!/usr/bin/env bash
# Template: success stub. Platform: macOS. See fake-lldb.sh.
DIR="$(cd "$(dirname "$0")" && pwd)"
export GBISO_LLDB_MODE=success
exec "$DIR/fake-lldb.sh" "$@"
