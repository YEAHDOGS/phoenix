#!/usr/bin/env python3
"""
Read-UsbConfig.py -- boot-side reader for phoenix-config.json.

The boot side (Phoenix WinPE startup hook, Invoke-Nuke.sh, answer-file
pipeline) reads the config HEADLESS: no GUI, no interactivity. This tool
is the single reader implementation both sides of the USB share:

  1. Validate the config FULLY -- the JSON Schema at
     config/usb-config.schema.json plus the structural safety rules in
     docs/CONFIG-SCHEMA.md section 6 (reused from
     tools/Validate-UsbConfig.py). A config that fails validation is a
     hard refusal, never a silent fallback to defaults.
  2. Print the nuke-relevant policy in a machine-consumable form.

Usage:
    python3 tools/Read-UsbConfig.py --shell <config.json>
        Prints shell assignments (values shlex-quoted) -- safe to `eval`
        in bash. Keys:
            CFG_NUKE_ENABLED            1 when boot_entries.nuke is true
            CFG_REQUIRE_IMAGE_PROOF     1 when safety.require_image_proof is true
            CFG_ALLOW_SKIP_IMAGE_GATE   1 when safety.allow_skip_image_gate is true
            CFG_ABORT_COUNTDOWN         safety.abort_countdown_seconds (integer)
            CFG_ALLOW_SERIAL_COUNT      number of allowlisted target_disks serials
            CFG_ALLOW_SERIAL_<i>        allowlisted serial, uppercased + trimmed
    python3 tools/Read-UsbConfig.py --json <config.json>
        The same policy as a JSON object (serials under "allow_serials").

Exit codes: 0 = valid (policy printed), 2 = invalid config (reasons on
stderr), 3 = usage / file errors.

Stdlib only (json, re, shlex, sys, pathlib, importlib). The Phoenix Linux
rescue side ships python3, and the stager copies tools/ onto the stick,
so this runs wherever the boot side runs.
"""

import importlib.util
import json
import shlex
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
DEFAULT_SCHEMA = REPO_ROOT / "config" / "usb-config.schema.json"


def load_validator_module():
    """Reuse the Validator + cross-field rules from Validate-UsbConfig.py."""
    validator_path = TOOLS_DIR / "Validate-UsbConfig.py"
    spec = importlib.util.spec_from_file_location(
        "phoenix_usbconfig_validator", validator_path
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def extract_policy(cfg):
    """Nuke-relevant policy from a validated config.

    Serials are normalized (uppercased, whitespace trimmed) exactly as the
    schema describes them, so a GUI that wrote 'satatest001' still matches
    the 'SATATEST001' the boot side enumerates.
    """
    boot = cfg.get("boot_entries", {})
    safety = cfg.get("safety", {})
    disks = cfg.get("target_disks", [])
    serials = []
    for entry in disks:
        serial = entry.get("serial", "").strip().upper()
        if serial:
            serials.append(serial)
    return {
        "nuke_enabled": bool(boot.get("nuke", False)),
        "require_image_proof": bool(safety.get("require_image_proof", True)),
        "allow_skip_image_gate": bool(safety.get("allow_skip_image_gate", False)),
        "abort_countdown": int(safety.get("abort_countdown_seconds", 5)),
        "allow_serials": serials,
    }


def validate_config(config_path, schema_path):
    """Full validation (schema + CONFIG-SCHEMA.md section 6). Returns
    (cfg, errors) -- errors is a list of human-readable strings."""
    mod = load_validator_module()
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, [f"cannot read schema {schema_path}: {exc}"]
    try:
        cfg = json.loads(config_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return None, [f"not valid JSON: {exc}"]
    validator = mod.Validator()
    validator.validate(cfg, schema)
    validator.cross_field_rules(cfg)
    return cfg, list(validator.errors)


def print_shell(policy):
    print("CFG_NUKE_ENABLED=%s" % ("1" if policy["nuke_enabled"] else "0"))
    print("CFG_REQUIRE_IMAGE_PROOF=%s" % ("1" if policy["require_image_proof"] else "0"))
    print("CFG_ALLOW_SKIP_IMAGE_GATE=%s" % ("1" if policy["allow_skip_image_gate"] else "0"))
    print("CFG_ABORT_COUNTDOWN=%d" % policy["abort_countdown"])
    serials = policy["allow_serials"]
    print("CFG_ALLOW_SERIAL_COUNT=%d" % len(serials))
    for i, serial in enumerate(serials):
        print("CFG_ALLOW_SERIAL_%d=%s" % (i, shlex.quote(serial)))


def print_json(policy):
    print(json.dumps(
        {
            "nuke_enabled": policy["nuke_enabled"],
            "require_image_proof": policy["require_image_proof"],
            "allow_skip_image_gate": policy["allow_skip_image_gate"],
            "abort_countdown": policy["abort_countdown"],
            "allow_serials": policy["allow_serials"],
        },
        indent=2,
    ))


def main(argv):
    args = list(argv)
    mode = None
    config_path = None
    schema_path = DEFAULT_SCHEMA
    while args:
        arg = args.pop(0)
        if arg in ("--shell", "--json"):
            mode = arg
        elif arg == "--schema" and args:
            schema_path = Path(args.pop(0))
        elif arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        elif arg.startswith("-"):
            print(f"unknown option: {arg}", file=sys.stderr)
            return 3
        else:
            config_path = Path(arg)
    if mode is None or config_path is None:
        print("usage: Read-UsbConfig.py (--shell|--json) <config.json>",
              file=sys.stderr)
        return 3
    if not config_path.is_file():
        print(f"config file not found: {config_path}", file=sys.stderr)
        return 3
    cfg, errors = validate_config(config_path, schema_path)
    if errors:
        print(f"INVALID: {config_path}", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 2
    policy = extract_policy(cfg)
    if mode == "--shell":
        print_shell(policy)
    else:
        print_json(policy)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
