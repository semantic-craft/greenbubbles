#!/usr/bin/env bash
# Stub debugger injected via LLDBPassphraseCapture(lldbPath:).
# Platform: macOS (Helios). Never attaches to a real process / WeChat.
#
# The production capture writes the REAL LLDBCaptureScript on stdin (includes
# "process attach -p <pid>"). We record that attach line, then emit output in
# the REAL LLDBOutputParser shapes (hexdump / Process N exited / error: attach).
#
# Env:
#   GBISO_ATTACH_LOG  append attach script lines here (default /dev/null)
#   GBISO_LLDB_MODE   success | exit | attachfail | verbose  (default success)
set -u
LOG="${GBISO_ATTACH_LOG:-/dev/null}"
MODE="${GBISO_LLDB_MODE:-success}"

# Known synthetic 32-byte key (all 0xaa) — NOT a real secret.
# Hexdump shape matches LLDBOutputParser.parseByteLine.
HEXDUMP_LINE_0="0x1000: 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa"
HEXDUMP_LINE_1="0x1008: 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa"
HEXDUMP_LINE_2="0x1010: 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa"
HEXDUMP_LINE_3="0x1018: 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa 0xaa"
# 64 lowercase hex of the same synthetic key (for verbose leak checks).
SYN_HEX="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

attach_pid=""
while IFS= read -r line || [ -n "${line:-}" ]; do
  case "$line" in
    "process attach -p "*)
      attach_pid="${line##* -p }"
      printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
      ;;
    "process continue")
      break
      ;;
    "quit"|"process detach")
      exit 0
      ;;
  esac
done

case "$MODE" in
  success)
    printf '%s\n' "$HEXDUMP_LINE_0" "$HEXDUMP_LINE_1" "$HEXDUMP_LINE_2" "$HEXDUMP_LINE_3"
    ;;
  verbose)
    # Deliberately leaky raw debugger text. VerboseLineRelay.redact() must
    # replace EVERY line with "<debugger output suppressed>".
    printf '%s\n' "memory read --size 1 --count 32 --format x \$x1"
    printf '%s\n' "$HEXDUMP_LINE_0" "$HEXDUMP_LINE_1" "$HEXDUMP_LINE_2" "$HEXDUMP_LINE_3"
    printf '%s\n' "$SYN_HEX"
    printf '%s\n' "0x00010a20: de ad be ef de ad be ef de ad be ef de ad be ef  ................"
    ;;
  exit)
    # LLDBOutputParser.detectTargetExit: "Process N exited"
    pid_show="${attach_pid:-0}"
    printf 'Process %s exited with status = 0 (0x00000000)\n' "$pid_show"
    ;;
  attachfail)
    # LLDBOutputParser.detectAttachFailure: error: ... attach|Not allowed
    printf 'error: attach failed: Not allowed to attach to process\n'
    ;;
  *)
    printf '%s\n' "$HEXDUMP_LINE_0" "$HEXDUMP_LINE_1" "$HEXDUMP_LINE_2" "$HEXDUMP_LINE_3"
    ;;
esac

# Stay alive briefly so the capture loop can drain stdout before we exit.
sleep 0.3
# Drain further stdin for quit/detach without blocking forever.
while IFS= read -r -t 1 line || [ -n "${line:-}" ]; do
  case "$line" in
    "quit"|"process detach") exit 0 ;;
  esac
done
exit 0
