#!/usr/bin/python3
"""Scan a tree for values that belong to one person: scan-personal-values.py <root> [names-file]

<root> is a git checkout (tracked files minus .gitattributes export-ignore
paths are scanned) or an exported tree with no .git (every file is). Prints
one FAIL line per hit and exits 1 when there is any. test_no_personal_values.sh
says what is checked and why.
"""
import os, re, subprocess, sys

def published():
    """Tracked files minus export-ignore paths; every file when this is an
    exported tree with no .git of its own."""
    if os.path.exists(".git"):
        files = subprocess.run(["git", "ls-files", "-z"], capture_output=True, text=True).stdout.split("\0")
        ignored = []
        if os.path.exists(".gitattributes"):
            for line in open(".gitattributes"):
                parts = line.split()
                if len(parts) >= 2 and "export-ignore" in parts[1:] and not line.startswith("#"):
                    ignored.append(parts[0])
        keep = []
        for f in files:
            if not f or any(f == p or (p.endswith("/") and f.startswith(p)) for p in ignored):
                continue
            keep.append(f)
        return keep
    out = []
    for root, dirs, names in os.walk("."):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        out.extend(os.path.join(root, n)[2:] for n in names)
    return out

CHECKS = [
    ("home path",        re.compile(r"/Users/(?!dev\b|you\b|\.\.\.|<|\$)[A-Za-z0-9_][A-Za-z0-9_.-]*")),
    ("home path",        re.compile(r"/home/(?!dev\b|you\b|runner\b|\.\.\.|<|\$)[a-z_][a-z0-9_-]*")),
    ("MAC address",      re.compile(r"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b")),
    ("tailnet name",     re.compile(r"\btail[0-9a-f]{4,}\.ts\.net")),
    ("tailnet address",  re.compile(r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b")),
    ("LAN address",      re.compile(r"\b(?:192\.168|10\.\d{1,3})\.\d{1,3}\.(?!255\b)\d{1,3}\b")),
    ("launchd label",    re.compile(r"\bcom\.(?!agentic-skills\.|apple\.|example\.)[a-z0-9-]+\.(?:routines|wakeschedule)\b")),
    ("e-mail address",   re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b")),
    ("Telegram token",   re.compile(r"\b\d{8,10}:[A-Za-z0-9_-]{35}\b")),
    ("API key",          re.compile(r"\b(?:ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-ant-[A-Za-z0-9-]{20,}|xai-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})\b")),
]
ALLOWED = {
    "MAC address":    {"02:00:00:aa:bb:cc", "00:11:22:33:44:55", "aa:bb:cc:dd:ee:ff"},
    "e-mail address": re.compile(r"@(?:example\.(?:com|org)|github\.com|users\.noreply\.github\.com|[a-z0-9-]+\.local)$|^(?:dev|pi|git|you)@", re.I),
}

os.chdir(sys.argv[1])
names = []
if len(sys.argv) > 2 and os.path.isfile(sys.argv[2]):
    names = [l.strip().lower() for l in open(sys.argv[2]) if l.strip() and not l.startswith("#")]

# The one file that plants each kind on purpose, to prove this scan sees it.
PLANTS = "launchd-runtime/tests/static/test_no_personal_values.sh"

bad = 0
for f in sorted(published()):
    if f == PLANTS:
        continue
    try:
        text = open(f, encoding="utf-8").read()
    except (UnicodeDecodeError, OSError, IsADirectoryError):
        continue
    for n, line in enumerate(text.split("\n"), 1):
        for kind, rx in CHECKS:
            for m in rx.finditer(line):
                hit = m.group(0)
                ok = ALLOWED.get(kind)
                if isinstance(ok, set) and hit.lower() in ok:
                    continue
                if ok is not None and not isinstance(ok, set) and ok.search(hit):
                    continue
                print("  FAIL: %s:%d: %s: %s" % (f, n, kind, hit))
                bad += 1
        low = line.lower()
        for name in names:
            if name in low:
                print("  FAIL: %s:%d: a name from private-names.local" % (f, n))
                bad += 1
    for name in names:
        if name in f.lower():
            print("  FAIL: %s: the file name holds a name from private-names.local" % f)
            bad += 1
sys.exit(1 if bad else 0)
