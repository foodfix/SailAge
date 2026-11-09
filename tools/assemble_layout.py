#!/usr/bin/env python3
"""Assembles `data/ui_layout.json` from the per-screen capture fragments
(docs/IMPLEMENT-Phase12.md §4 — one shared file, master assembles at
each merge gate).

Usage:
    python3 tools/assemble_layout.py --only <screen[,screen...]> [--check]

Builds the v2 document `{"version": 2, "screens": {...}}` from the
named screens' `data/layout_fragments/<screen>.json` tables (each
`{"elements": {...}, "lists": {...}}`), merged over whatever the
current file already holds, and writes it in the canonical bytes
(sorted keys, 2-space indent, trailing newline — the group-14 byte
rule). `--only` names the CONVERTED screens whose fragments are final
— pre-conversion fragments carry flow-era rects that fail the canvas
bounds, so the assembly is scoped per merge gate (W2-A: the port
eight; W4: the full 32).

`--check` verifies the committed file equals the assembly (byte-stable
gate) and exits 1 on drift.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
FRAGMENT_DIR = DATA_DIR / "layout_fragments"
LAYOUT_FILE = DATA_DIR / "ui_layout.json"


def build(only: list[str]) -> dict:
    current: dict = {}
    if LAYOUT_FILE.is_file():
        current = json.loads(LAYOUT_FILE.read_text(encoding="utf-8"))
    screens: dict = dict(current.get("screens", {}))
    for screen in only:
        path = FRAGMENT_DIR / f"{screen}.json"
        if not path.is_file():
            print(f"assemble_layout: no fragment for '{screen}' "
                  f"({path})")
            raise SystemExit(1)
        fragment = json.loads(path.read_text(encoding="utf-8"))
        screens[screen] = {
            "elements": fragment.get("elements", {}),
            "lists": fragment.get("lists", {}),
        }
    return {"version": 2, "screens": screens}


def canonical(doc: dict) -> str:
    return json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--only", default="",
                    help="comma-separated converted screens to assemble")
    ap.add_argument("--check", action="store_true",
                    help="verify the committed file equals the assembly")
    args = ap.parse_args()
    only = [s for s in args.only.split(",") if s]
    if not only:
        print("assemble_layout: --only is required (the converted "
              "screens of this merge gate)")
        return 1
    doc = build(only)
    text = canonical(doc)
    if args.check:
        current = LAYOUT_FILE.read_text(encoding="utf-8")
        if current != text:
            print("assemble_layout: DRIFT — data/ui_layout.json differs "
                  "from the fragment assembly")
            return 1
        print(f"assemble_layout: OK ({len(doc['screens'])} screens, "
              "bytes canonical)")
        return 0
    LAYOUT_FILE.write_text(text, encoding="utf-8")
    n_elements = sum(
        len(s.get("elements", {})) for s in doc["screens"].values())
    print(f"assemble_layout: wrote {len(doc['screens'])} screens "
          f"({n_elements} elements) -> data/ui_layout.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
