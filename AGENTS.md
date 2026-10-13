# AGENTS.md — router

Read before changing code here. Keep this file short; it only points elsewhere.

- Past mistakes and the rules they produced: [LESSONS.md](LESSONS.md). Check it first.
- Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). CLI: [docs/CLI_REFERENCE.md](docs/CLI_REFERENCE.md).
- Key acquisition and its limits: [docs/PASSPHRASE_ACQUISITION.md](docs/PASSPHRASE_ACQUISITION.md). Never re-sign or inject into official WeChat.
- Multiple accounts / follow the logged-in account: [docs/FAQ.md](docs/FAQ.md) and [docs/QUERY_PROFILES.md](docs/QUERY_PROFILES.md).
- Rust core: `Native/GreenBubbles` (`cargo test --release --lib`). Swift acquire: `Sources/`, `Tests/`.
- Never print, log, or copy keys off the machine. Never send WeChat messages from tests.
- Cleaning up / reporting state of acquire & comparison artifacts: enumerate from `scripts/gb_residue_report.py` (declared `STATE_ROOTS`), never guessed paths or wildcards; enforced by `scripts/test_gb_residue_report.py`. Never claim "clean" without this inventory.
