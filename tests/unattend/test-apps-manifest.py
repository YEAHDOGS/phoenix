#!/usr/bin/env python3
"""test-apps-manifest.py -- schema validation for config/apps.json.

Usage: python3 tests/unattend/test-apps-manifest.py   (exit 0 = all green)
"""
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MANIFEST = REPO / "config" / "apps.json"

PASS = 0
FAIL = 0


def ok(name):
    global PASS
    PASS += 1
    print("  PASS: %s" % name)


def bad(name, why=""):
    global FAIL
    FAIL += 1
    print("  FAIL: %s%s" % (name, " -- " + why if why else ""))


print("== config/apps.json schema ==")
try:
    catalog = json.loads(MANIFEST.read_text(encoding="utf-8"))
    ok("valid JSON")
except (OSError, json.JSONDecodeError) as e:
    bad("valid JSON", str(e)[:120])
    print("PASS: %d  FAIL: %d" % (PASS, FAIL))
    sys.exit(1)

if isinstance(catalog, list) and catalog:
    ok("manifest is a non-empty array (%d entries)" % len(catalog))
else:
    bad("manifest is a non-empty array")

ids = []
for i, e in enumerate(catalog):
    tag = "entry[%d]" % i
    if not isinstance(e, dict):
        bad(tag, "not an object")
        continue
    for field in ("package", "description", "category", "defaultSelected"):
        if field not in e:
            bad(tag, "missing field %r" % field)
    pkg = e.get("package", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", str(pkg)):
        bad(tag, "bad package id %r" % pkg)
    else:
        ids.append(pkg)
    if not isinstance(e.get("defaultSelected"), bool):
        bad(tag, "defaultSelected must be boolean")
    if not e.get("category"):
        bad(tag, "empty category")
    if e.get("source", "chocolatey") not in ("chocolatey", "manual"):
        bad(tag, "unknown source %r" % e.get("source"))
    if e.get("source") == "manual" and not e.get("note"):
        bad(tag, "manual-source entry needs a note explaining the manual step")

if len(ids) == len(set(ids)):
    ok("no duplicate package ids")
else:
    bad("no duplicate package ids")

defaults = [e["package"] for e in catalog if e.get("defaultSelected")]
if defaults:
    ok("%d default-selected packages" % len(defaults))
else:
    bad("at least one default-selected package")

# the mission's headline apps must be present
for want in ("GoogleChrome", "Steam", "VSCode", "7zip", "VLC"):
    if want in ids:
        ok("manifest includes %s" % want)
    else:
        bad("manifest includes %s" % want)
if "Ableton" in ids and catalog[ids.index("Ableton")].get("source") == "manual":
    ok("Ableton flagged as manual-source (not on Chocolatey)")
else:
    bad("Ableton flagged as manual-source (not on Chocolatey)")

print("PASS: %d  FAIL: %d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
