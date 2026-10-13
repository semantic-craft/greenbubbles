#!/usr/bin/env python3
"""Enumerate every GreenBubbles artifact on disk from one declared source of truth.

Why this exists: on 2026-10-13 an agent declared the WeChat-key workspace
"cleaned" after checking only ~/.greenbubbles-acquire, and a prior incident
wildcard-deleted unrelated /tmp files. Both failures share a root cause:
cleanup/state claims were based on *guessed* locations instead of a complete,
authoritative enumeration. This module makes "where GreenBubbles writes" a
single list (STATE_ROOTS) and produces the artifact inventory by walking it in
full. It NEVER deletes anything; it only reports. Deletion is a separate,
human-approved step that must consume this inventory's exact paths.
"""
from __future__ import annotations
import os, sys, json
from dataclasses import dataclass, asdict
from pathlib import Path

# Single source of truth: every root GreenBubbles tooling may write to.
# Add here when a new tool writes somewhere new; do not scatter guesses.
STATE_ROOTS = [
    "~/.greenbubbles",            # live config + query profiles + keys
    "~/.greenbubbles-acquire",    # acquire default output
    "~/.local/state/greenbubbles",# acquire/compare harness state (large)
]

KEY_NAME_HINTS = ("passphrase", "all_keys.json", ".key")

@dataclass
class Artifact:
    path: str
    bytes: int
    kind: str  # app-bundle | key-material | container-snapshot | dir | file

def _dir_size(p: Path) -> int:
    total = 0
    for dp, _dn, fn in os.walk(p, onerror=lambda e: None):
        for f in fn:
            fp = Path(dp) / f
            try:
                total += fp.lstat().st_size
            except OSError:
                pass
    return total

def _classify(p: Path) -> str:
    name = p.name
    if name.endswith(".app"):
        return "app-bundle"            # any name, not just WeChat.app
    if any(h in name for h in KEY_NAME_HINTS):
        return "key-material"
    if name == "container-before-trial" or "container" in name.lower() and p.is_dir():
        return "container-snapshot"
    return "dir" if p.is_dir() else "file"

def find_residue(roots=None):
    """Return the full inventory under every declared root.

    Walks each root with NO depth cap and matches .app bundles by suffix (not an
    exact filename), so copies like WeChat-trial.app at any depth are found.
    """
    roots = roots if roots is not None else STATE_ROOTS
    out: list[Artifact] = []
    for r in roots:
        root = Path(os.path.expanduser(r))
        if not root.exists():
            continue
        for dp, dns, fns in os.walk(root, onerror=lambda e: None):
            dpath = Path(dp)
            # record .app bundles and container snapshots as whole units, don't descend
            pruned = []
            for d in list(dns):
                full = dpath / d
                kind = _classify(full)
                if kind in ("app-bundle", "container-snapshot"):
                    out.append(Artifact(str(full), _dir_size(full), kind))
                    pruned.append(d)
            for d in pruned:
                dns.remove(d)
            for f in fns:
                full = dpath / f
                kind = _classify(full)
                if kind == "key-material":
                    try:
                        sz = full.lstat().st_size
                    except OSError:
                        sz = 0
                    out.append(Artifact(str(full), sz, kind))
    return out

def _human(n: int) -> str:
    f = float(n)
    for unit in ("B","K","M","G","T"):
        if f < 1024 or unit == "T":
            return f"{f:.0f}{unit}" if unit == "B" else f"{f:.1f}{unit}"
        f /= 1024
    return f"{f:.1f}T"

def main(argv=None):
    argv = argv or sys.argv[1:]
    as_json = "--json" in argv
    items = find_residue()
    if as_json:
        print(json.dumps({"roots": STATE_ROOTS, "artifacts": [asdict(a) for a in items]}, indent=2))
        return 0
    print("GreenBubbles residue inventory (read-only; this NEVER deletes).")
    print("Roots scanned (source of truth):")
    for r in STATE_ROOTS:
        rp = Path(os.path.expanduser(r))
        print(f"  {'[present]' if rp.exists() else '[absent] '} {r}")
    print()
    if not items:
        print("No app bundles, key material, or container snapshots found under the declared roots.")
    else:
        for a in sorted(items, key=lambda x: -x.bytes):
            print(f"  {_human(a.bytes):>8}  {a.kind:<18}  {a.path}")
    print()
    print("To act on these, pass the EXACT paths above to a human-approved delete step.")
    print("Do not wildcard-delete and do not claim 'clean' without this inventory attached.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
