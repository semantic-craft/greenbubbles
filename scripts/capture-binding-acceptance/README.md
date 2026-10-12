# capture-binding-acceptance — GreenBubbles V1–V8 binding acceptance kit

Standalone verification kit for the **current production** capture-binding patches,
run against a `greenbubbles` checkout that already has them applied. Executes on
macOS. **Touches no real WeChat / keychain / network**; it uses only a
synthetic long-lived target, a fake `db_storage`, a stub `lldb`, and an all-`0xaa`
synthetic passphrase fixture (never a real secret).

This kit vendors **no production source, no binaries, and no machine-specific paths**.

## Layout

| Path | Purpose |
|------|---------|
| `run-all.sh` | build helpers, temp-install the Swift test into the repo, run V1–V8 + CLI, clean up |
| `common.sh` | shared bash helpers (binary discovery, safe cleanup, build helpers) |
| `Tests/BindingAcceptanceV1V8Tests.swift` | Swift Testing suite V1–V8 (installed temporarily, see below) |
| `helpers/pauser.c` | **C source** of the synthetic target; compiled automatically with `cc` |
| `helpers/fake-lldb*.sh` | stub debugger scripts (success / exit / attachfail / verbose) |
| `cli/*.sh` | CLI exit-code checks (some intentionally `NOT_RUN` on a synthetic target) |

## Packaging contract (maintainable)

* **Helpers ship as C source** (`helpers/pauser.c`) and are compiled by `run-all.sh`
  with `cc`. No prebuilt binary is shipped.
* The acceptance `.swift` file is **temporarily installed** into
  `GB_REPO/Tests/GreenBubblesAcquireTests/` and **removed again by an EXIT trap**,
  so a plain `swift test` in the repo never breaks on a missing external helper.
* The runner refuses to run if the destination test path already exists, including
  a symlink. Cleanup removes its temporary test only while the bytes still match
  its private installation copy; changed files are preserved and reported.
* Helpers are located by the test via `GBISO_HELPERS` / `GBISO_PAUSER_BIN` (exported
  by `run-all.sh`). The temporary test is removed; the compiled helper remains
  ignored under `helpers/`.

## How to run (macOS)

```bash
export GB_REPO=~/path/to/greenbubbles   # patched with current production binding
export GB_CONFIG=Debug                   # or Release (used for Products/ path)
scripts/capture-binding-acceptance/run-all.sh
```

`run-all.sh` compiles helpers → verifies the production binding API shape →
temp-installs the test → `swift build` → `swift test --filter BindingAcceptanceV1V8Tests
--no-parallel` → runs `cli/` → prints `SUMMARY: pass/fail/not_run` → removes the
temp test. Expected: `fail=0`, exit 0.

Binary discovery never hardcodes `.build/debug`:
`$GBISO_ACQUIRE_BIN` → `$GB_REPO/.build/out/Products/$GB_CONFIG/greenbubbles-acquire`
→ `swift build --show-bin-path`.

## Coverage highlights

* **targetExited mid-capture** — `v5b` uses `helpers/fake-lldb-exit.sh`, which emits
  `Process <pid> exited` after the attach script is accepted → asserts
  `CaptureError.targetExited` (attach happens exactly once, no re-target).
* **Exact attachFailed** — the V7 failure case asserts `case .attachFailed` precisely
  (via `helpers/fake-lldb-attachfail.sh`) and verifies no output file is created.
* Plus V1 ambiguousTargets (no attach), V2 success (bound pid only), V3 pathMismatch,
  V4 uidMismatch, V5 no-retarget, V6 sourceRootMismatch, V7 staged-publish preserves
  old key, V8 verbose debugger output fully suppressed.

## Non-macOS note

On a non-macOS box this kit still packages, passes `bash -n`, and compiles
`helpers/pauser.c` with `cc`; the Swift/`lsof`/`proc_*` acceptance cannot run there
and is reported as `NOT_RUN`.
