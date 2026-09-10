#!/usr/bin/env python3
"""test-generate-unattend.py -- regression tests for the answer-file generators.

Runs scripts/generate_unattend.py (the stdlib reference implementation) with
fixed options into a temp dir in /tmp -- NEVER the repo, the filled file
carries passwords and win-install/staging/ is gitignored -- and asserts the
output contract: well-formed XML, all 7 passes, required components,
token-free output, no default/empty passwords, proven Schneegans obfuscation
vectors, locale + telemetry options, the --options-json path, and clean
failure modes.

Usage: python3 tests/unattend/test-generate-unattend.py   (exit 0 = all green)
"""
import base64
import json
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GEN = REPO / "scripts" / "generate_unattend.py"
NS = "{urn:schemas-microsoft-com:unattend}"

PASS = 0
FAIL = 0
FAILED = []


def ok(name):
    global PASS
    PASS += 1
    print("  PASS: %s" % name)


def bad(name, why=""):
    global FAIL
    FAIL += 1
    FAILED.append(name)
    print("  FAIL: %s%s" % (name, " -- " + why if why else ""))


def obscure(pw):
    return base64.b64encode((pw + "Password").encode("utf-16-le")).decode("ascii")


def gen(out, **kw):
    args = [sys.executable, str(GEN), "--output", str(out), "--force",
            "--generated-at", "2026-09-10T14:00:00Z"]
    for k, v in kw.items():
        args.append("--" + k.replace("_", "-"))
        args.append(str(v))
    return subprocess.run(args, capture_output=True, text=True)


BASE = dict(computer_name="TEST-PC", username="testadmin", password="S3cret!Test",
            standard_username="testuser", standard_password="G2pass!Test")

print("== generate_unattend.py regression ==")
tmp = Path(tempfile.mkdtemp(prefix="phoenix-unattend-test-"))

# G1: happy path, two accounts
r = gen(tmp / "two.xml", **BASE)
if r.returncode == 0:
    ok("generator exits 0 (two accounts)")
else:
    bad("generator exits 0 (two accounts)", r.stderr.strip()[:200])
content = (tmp / "two.xml").read_text(encoding="utf-8")

# G2: well-formed
try:
    root = ET.fromstring(content)
    ok("output is well-formed XML")
except ET.ParseError as e:
    root = None
    bad("output is well-formed XML", str(e)[:120])

# G3: all 7 passes present
if root is not None:
    passes = [s.get("pass") for s in root.findall(NS + "settings")]
    want = ["offlineServicing", "windowsPE", "generalize", "specialize",
            "auditSystem", "auditUser", "oobeSystem"]
    if passes == want:
        ok("all 7 configuration passes present")
    else:
        bad("all 7 configuration passes present", str(passes))

    # G4: required components
    def has(pass_name, comp):
        for s in root.findall(NS + "settings"):
            if s.get("pass") == pass_name:
                return any(c.get("name") == comp for c in s.findall(NS + "component"))
        return False
    if has("windowsPE", "Microsoft-Windows-Setup"):
        ok("Microsoft-Windows-Setup in windowsPE")
    else:
        bad("Microsoft-Windows-Setup in windowsPE")
    if has("oobeSystem", "Microsoft-Windows-Shell-Setup"):
        ok("Microsoft-Windows-Shell-Setup in oobeSystem")
    else:
        bad("Microsoft-Windows-Shell-Setup in oobeSystem")
    if "<UserAccounts>" in content and "<AutoLogon>" in content:
        ok("UserAccounts + AutoLogon present in oobeSystem")
    else:
        bad("UserAccounts + AutoLogon present in oobeSystem")

# G5: token-free
if re.search(r"\{\{[A-Z_]+\}\}", content):
    bad("output is token-free", "unfilled {{...}} remains")
else:
    ok("output is token-free")

# G6: no default/empty passwords in output
if re.search(r"<Value>\s*</Value>", content):
    bad("no empty passwords", "empty <Value> element found")
else:
    ok("no empty password values")
for default_pw in ("password", "Password1", "123456", "admin", "changeme"):
    if obscure(default_pw) in content:
        bad("no default passwords", "obfuscated default %r present" % default_pw)
        break
else:
    ok("no well-known default passwords")

# G7: proven Schneegans obfuscation vectors (match the PS suite's hashes)
if obscure("123456789abcdefghi") == \
        "MQAyADMANAA1ADYANwA4ADkAYQBiAGMAZABlAGYAZwBoAGkAUABhAHMAcwB3AG8AcgBkAA==":
    ok("obfuscation matches proven admin hash vector")
else:
    bad("obfuscation matches proven admin hash vector")
if obscure("abcdefghi123456789") == \
        "YQBiAGMAZABlAGYAZwBoAGkAMQAyADMANAA1ADYANwA4ADkAUABhAHMAcwB3AG8AcgBkAA==":
    ok("obfuscation matches proven standard-user hash vector")
else:
    bad("obfuscation matches proven standard-user hash vector")
if obscure(BASE["password"]) in content and obscure(BASE["standard_password"]) in content:
    ok("both account passwords land obfuscated in the file")
else:
    bad("both account passwords land obfuscated in the file")

# G8: telemetry=off injects the AllowTelemetry blocks; basic does not
if content.count("AllowTelemetry") == 2 and "DataCollection" in content:
    ok("telemetry=off injects AllowTelemetry=0 reg blocks")
else:
    bad("telemetry=off injects AllowTelemetry=0 reg blocks")
r = gen(tmp / "basic.xml", **{**BASE, "telemetry": "basic"})
c_basic = (tmp / "basic.xml").read_text(encoding="utf-8")
if "AllowTelemetry" not in c_basic:
    ok("telemetry=basic leaves the template untouched")
else:
    bad("telemetry=basic leaves the template untouched")

# G9: locale options land in the XML and in the Schneegans regen URL
r = gen(tmp / "locale.xml", **{**BASE, "input_locale": "0407:00000407",
                               "system_locale": "de-DE", "ui_language": "de-DE",
                               "user_locale": "de-DE"})
c_loc = (tmp / "locale.xml").read_text(encoding="utf-8")
if ("<InputLocale>0407:00000407</InputLocale>" in c_loc
        and "<UILanguage>de-DE</UILanguage>" in c_loc):
    ok("locale options replace the template's hardcoded values")
else:
    bad("locale options replace the template's hardcoded values")
m = re.search(r"<!--https://schneegans.*?-->", c_loc, re.S)
if m and "Keyboard=00000407" in m.group(0) and "UILanguage=de-DE" in m.group(0) \
        and "{{" not in m.group(0):
    ok("Schneegans regen URL rewritten for locale + token-free")
else:
    bad("Schneegans regen URL rewritten for locale + token-free")

# G10: single-account mode drops the second account cleanly
r = gen(tmp / "single.xml", computer_name="TEST-PC", username="testadmin",
        password="S3cret!Test")
c_single = (tmp / "single.xml").read_text(encoding="utf-8")
if r.returncode == 0 and "AccountPassword1" not in c_single \
        and not re.search(r"\{\{[A-Z_]+\}\}", c_single):
    ok("single-account mode drops the second account cleanly")
else:
    bad("single-account mode drops the second account cleanly", r.stderr.strip()[:160])

# G11: --options-json path (the Tauri GUI contract)
opts_file = tmp / "machine.json"
opts_file.write_text(json.dumps({
    "computer_name": "JSON-PC", "username": "jsonadmin", "password": "J4son!Test",
    "timezone": "Pacific Standard Time", "telemetry": "basic",
}), encoding="utf-8")
r = subprocess.run([sys.executable, str(GEN), "--options-json", str(opts_file),
                    "--output", str(tmp / "json.xml"), "--force",
                    "--generated-at", "2026-09-10T14:00:00Z"],
                   capture_output=True, text=True)
c_json = (tmp / "json.xml").read_text(encoding="utf-8") if r.returncode == 0 else ""
if r.returncode == 0 and "<ComputerName>JSON-PC</ComputerName>" in c_json \
        and "<TimeZone>Pacific Standard Time</TimeZone>" in c_json \
        and "AllowTelemetry" not in c_json:
    ok("--options-json drives the generator (GUI contract)")
else:
    bad("--options-json drives the generator (GUI contract)", r.stderr.strip()[:160])

# G12: failure modes -- all fail closed, no partial write
def expect_fail(name, **kw):
    out = tmp / (name + ".xml")
    rr = gen(out, **kw)
    if rr.returncode != 0 and not out.exists():
        ok("fails closed: %s" % name)
    else:
        bad("fails closed: %s" % name, "rc=%d wrote=%s" % (rr.returncode, out.exists()))

expect_fail("empty-password", computer_name="TEST-PC", username="testadmin", password="")
expect_fail("bad-computer-name", computer_name="bad name!", username="testadmin", password="x")
expect_fail("same-accounts", computer_name="TEST-PC", username="same",
            password="x", standard_username="same", standard_password="y")
expect_fail("bad-product-key", computer_name="TEST-PC", username="testadmin",
            password="x", product_key="not-a-key")

# existing output without --force refuses
out = tmp / "noforce.xml"
gen(out, **BASE)
r2 = subprocess.run([sys.executable, str(GEN), "--output", str(out),
                     "--computer-name", "TEST-PC", "--username", "u", "--password", "p"],
                    capture_output=True, text=True)
if r2.returncode != 0:
    ok("fails closed: existing output without --force")
else:
    bad("fails closed: existing output without --force")

# G13: no personal data in the new scripts/docs (name/debt rule)
new_files = [REPO / "scripts" / "generate_unattend.py",
             REPO / "scripts" / "Generate-Unattend.ps1",
             REPO / "scripts" / "Install-Apps.ps1",
             REPO / "scripts" / "install_apps.sh",
             REPO / "config" / "apps.json",
             REPO / "docs" / "UNATTEND-GENERATOR.md"]
leak = False
for f in new_files:
    txt = f.read_text(encoding="utf-8")
    for needle in ("Brandon Wellacruz", "wellacruz", "Captain Brando"):
        if needle.lower() in txt.lower():
            bad("no personal identifiers in %s" % f.name, "found %r" % needle)
            leak = True
            break
if not leak:
    ok("no personal identifiers in new files")

print("PASS: %d  FAIL: %d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
