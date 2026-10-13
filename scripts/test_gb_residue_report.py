"""Prove the residue inventory catches exactly the 2026-10-13 miss.

The real past mistake: a cleanup used `find ~ -maxdepth 3 -iname "WeChat.app"`,
which (a) capped depth too shallow and (b) matched only the exact name, so the
resigned copy `WeChat-trial.app` at depth 4 and the nested run dir with raw key
material were never found, and the workspace was wrongly declared "clean".

These tests build a fixture that reproduces that layout and assert the new
enumeration finds the artifacts the old command missed.
"""
import os
from pathlib import Path
import gb_residue_report as m


def _build_fixture(tmp: Path) -> Path:
    # mirror ~/.local/state/greenbubbles/comparison-XXXX/...
    root = tmp / ".local" / "state" / "greenbubbles"
    run = root / "comparison-20261012" / "run-20261012-201558"
    run.mkdir(parents=True)
    # depth-4 resigned copy that `-maxdepth 3 -iname WeChat.app` cannot see
    app = root / "comparison-20261012" / "WeChat-trial.app" / "Contents"
    app.mkdir(parents=True)
    (app / "Info.plist").write_text("x")
    # raw key material in the run dir
    (run / "greenbubbles-passphrase.txt").write_text("0" * 64)
    (run / "all_keys.json").write_text("{}")
    # a container snapshot
    snap = run / "container-before-trial" / "Data"
    snap.mkdir(parents=True)
    (snap / "big.bin").write_text("y" * 1000)
    return root


def test_inventory_finds_depth4_app_and_key_material(tmp_path):
    root = _build_fixture(tmp_path)
    items = m.find_residue([str(root)])
    paths = {Path(a.path).name: a.kind for a in items}
    assert paths.get("WeChat-trial.app") == "app-bundle", "must find the depth-4 resigned copy"
    assert paths.get("greenbubbles-passphrase.txt") == "key-material"
    assert paths.get("all_keys.json") == "key-material"
    assert any(a.kind == "container-snapshot" for a in items), "must flag the container snapshot"


def test_old_shallow_exact_name_find_would_miss(tmp_path):
    # Behavioral proof the OLD approach failed: emulate `find <root> -maxdepth 3 -iname 'WeChat.app'`
    root = _build_fixture(tmp_path)
    base_depth = len(root.parts)
    old_hits = []
    for dp, _dn, _fn in os.walk(root):
        depth = len(Path(dp).parts) - base_depth
        if depth > 3:
            continue
        for d in _dn:
            if (Path(dp) / d).name.lower() == "wechat.app":  # exact name only
                old_hits.append(d)
    assert old_hits == [], "old command finds nothing (reproduces the miss)"
    # new enumeration DOES find it
    assert any(Path(a.path).name == "WeChat-trial.app" for a in m.find_residue([str(root)]))


if __name__ == "__main__":
    import tempfile, traceback
    fails = 0
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            with tempfile.TemporaryDirectory() as d:
                try:
                    fn(Path(d))
                    print(f"PASS {name}")
                except Exception:
                    fails += 1
                    print(f"FAIL {name}")
                    traceback.print_exc()
    raise SystemExit(1 if fails else 0)
