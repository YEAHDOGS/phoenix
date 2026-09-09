#!/usr/bin/env python3
"""
Validate-UsbConfig.py — dependency-free validator for phoenix-config.json.

Usage:
    python3 tools/Validate-UsbConfig.py [--schema config/usb-config.schema.json] <config.json>

Exit codes: 0 = valid (prints "OK: <path>"), 2 = invalid (prints each error),
            3 = usage / file errors.

Stdlib only (json, re, sys, pathlib). Runs anywhere python3 exists — including
the Phoenix Linux rescue side (SystemRescue ships python3), so the boot side can
validate the config headlessly before acting on it. The Windows side twin is a
future port; GUI writes get validated in CI and by this tool.

Validation = (1) a JSON Schema draft-2020-12 subset read straight from the
schema file (type, required, enum, const, pattern, min/maxLength, minimum,
maximum, minItems, uniqueItems, properties, items, additionalProperties,
allOf/if/then) + (2) cross-field safety rules from docs/CONFIG-SCHEMA.md §6
that JSON Schema cannot express.
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SCHEMA = REPO_ROOT / "config" / "usb-config.schema.json"

TYPEMAP = {
    "object": dict, "array": list, "string": str,
    "integer": int, "boolean": bool, "number": (int, float),
}


def type_ok(value, tname):
    if tname == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if tname == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, TYPEMAP[tname])


def jpath(base, key):
    return f"{base}.{key}" if base else str(key)


class Validator:
    def __init__(self):
        self.errors = []

    def err(self, path, msg):
        self.errors.append(f"{path or '<root>'}: {msg}")

    def validate(self, value, schema, path=""):
        tname = schema.get("type")
        if tname and not type_ok(value, tname):
            self.err(path, f"expected {tname}, got {type(value).__name__}")
            return  # further checks would be noise
        if "enum" in schema and value not in schema["enum"]:
            self.err(path, f"value {value!r} not in enum {schema['enum']}")
        if "const" in schema and value != schema["const"]:
            self.err(path, f"value {value!r} != const {schema['const']!r}")
        if isinstance(value, str):
            if "minLength" in schema and len(value) < schema["minLength"]:
                self.err(path, f"too short (min {schema['minLength']})")
            if "maxLength" in schema and len(value) > schema["maxLength"]:
                self.err(path, f"too long (max {schema['maxLength']})")
            if "pattern" in schema and not re.search(schema["pattern"], value):
                self.err(path, f"does not match pattern {schema['pattern']}")
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if "minimum" in schema and value < schema["minimum"]:
                self.err(path, f"below minimum {schema['minimum']}")
            if "maximum" in schema and value > schema["maximum"]:
                self.err(path, f"above maximum {schema['maximum']}")
        if isinstance(value, list):
            if "minItems" in schema and len(value) < schema["minItems"]:
                self.err(path, f"fewer than minItems {schema['minItems']}")
            if schema.get("uniqueItems"):
                seen = set()
                for i, item in enumerate(value):
                    key = json.dumps(item, sort_keys=True)
                    if key in seen:
                        self.err(jpath(path, str(i)), "duplicate item")
                    seen.add(key)
            item_schema = schema.get("items")
            if item_schema:
                for i, item in enumerate(value):
                    self.validate(item, item_schema, f"{path}[{i}]" if path else f"[{i}]")
        if isinstance(value, dict):
            props = schema.get("properties", {})
            for req in schema.get("required", []):
                if req not in value:
                    self.err(path, f"missing required property {req!r}")
            for key, sub in value.items():
                if key in props:
                    self.validate(sub, props[key], jpath(path, key))
                elif schema.get("additionalProperties") is False:
                    self.err(path, f"unknown property {key!r} (additionalProperties: false)")
            self._allof_if_then(value, schema, path)

    def _allof_if_then(self, value, schema, path):
        for clause in schema.get("allOf", []):
            if "if" in clause and "then" in clause:
                probe = Validator()
                probe.validate(value, clause["if"], path)
                if not probe.errors:
                    self.validate(value, clause["then"], path)

    def cross_field_rules(self, cfg):
        """Safety rules from docs/CONFIG-SCHEMA.md §6 — structural, not advisory."""
        boot = cfg.get("boot_entries", {})
        safety = cfg.get("safety", {})
        disks = cfg.get("target_disks", [])
        if boot.get("nuke"):
            if not safety.get("require_image_proof", True):
                self.err("safety.require_image_proof",
                         "must be true when boot_entries.nuke is true "
                         "(runbook invariant 1: verified image or no wipe)")
            if not disks:
                self.err("target_disks",
                         "must list at least one allowlisted serial when "
                         "boot_entries.nuke is true (never nuke without an explicit allowlist)")
        if boot.get("backup") and not cfg.get("backup_target"):
            self.err("backup_target", "required when boot_entries.backup is true")


def main(argv):
    schema_path = DEFAULT_SCHEMA
    config_path = None
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--schema" and args:
            schema_path = Path(args.pop(0))
        elif a in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        elif a.startswith("-"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 3
        else:
            config_path = Path(a)
    if config_path is None:
        print("usage: Validate-UsbConfig.py [--schema PATH] <config.json>", file=sys.stderr)
        return 3
    for p, label in ((schema_path, "schema"), (config_path, "config")):
        if not p.is_file():
            print(f"{label} file not found: {p}", file=sys.stderr)
            return 3
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    try:
        cfg = json.loads(config_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"INVALID: {config_path}: not valid JSON: {e}")
        return 2
    v = Validator()
    v.validate(cfg, schema)
    v.cross_field_rules(cfg)
    if v.errors:
        print(f"INVALID: {config_path}")
        for e in v.errors:
            print(f"  - {e}")
        return 2
    print(f"OK: {config_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
