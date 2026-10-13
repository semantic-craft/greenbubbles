# LESSONS

Format: one-line rule — reason — evidence — Seen N×.

- **Map EPERM/EACCES on the WeChat container to a permission error, never to "wrong key".** — A shell without macOS Full Disk Access got "could not be opened with the supplied access material" for a valid key, which invites a needless (and risky) key re-capture. — branch `fix/permission-denied-not-wrong-key`, this PR; live check on Helios 2026-10-13. — Seen 1×.
  - Checks not run: full `cargo test` suite (only `--lib live_query`), Swift tests, and a positive read from a Full-Disk-Access context with the new binary.
