#!/usr/bin/env python3
"""Catalog schema smoke test for data/choco-install/apps.json.

Mirrors the constraints enforced by tools/New-AppInstallScript.ps1:
- valid JSON array of objects
- every entry has package/description/category/defaultSelected
- package names pass the generator's choco-id regex (^[A-Za-z0-9][A-Za-z0-9._-]*$)
- package names are unique
- 'manual' entries carry a note (the generator warns + skips them)
- defaultSelected is a real boolean
Exit 0 = green.
"""
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "data" / "choco-install" / "apps.json"
PKG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

fails = []


def check(cond, name, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f" -- {detail}" if detail and not cond else ""))
    if not cond:
        fails.append(name)


try:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
except Exception as e:  # noqa: BLE001
    print(f"FAIL catalog parses as JSON -- {e}")
    sys.exit(1)
print("PASS catalog parses as JSON")

check(isinstance(data, list) and len(data) > 0, "catalog is a non-empty array", f"got {len(data)}")

required = {"package", "description", "category", "defaultSelected"}
seen = set()
for i, e in enumerate(data):
    tag = f"entry[{i}]"
    check(required <= set(e), f"{tag} has required keys", f"missing {required - set(e)}")
    check(isinstance(e.get("defaultSelected"), bool), f"{tag} defaultSelected is bool")
    pkg = str(e.get("package", ""))
    check(bool(PKG_RE.match(pkg)), f"{tag} package id '{pkg}' passes generator regex")
    check(pkg not in seen, f"{tag} package id '{pkg}' unique")
    seen.add(pkg)
    if e.get("source") == "manual":
        check(bool(e.get("note")), f"{tag} manual entry has a note")

defaults = [e["package"] for e in data if e["defaultSelected"]]
check(len(defaults) > 0, "at least one default-selected package", "generator refuses empty selection")

print(f"\n{len(data)} packages, {len(defaults)} default-selected. ", end="")
if fails:
    print(f"FAILED: {fails}")
    sys.exit(1)
print("All catalog checks green.")
