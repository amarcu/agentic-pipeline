#!/bin/bash
# Builds the fixture repository both review-pr eval cases are reviewed against.
#
# Usage: seed-repo.sh <dir>
#
# One base commit, then two branches from it that differ in a single character:
#
#   defect/cap-charge   `spent + amount >= cap` — refuses a charge that lands
#                       exactly on the cap, which the issue's second acceptance
#                       criterion requires to be allowed
#   clean/cap-charge    `spent + amount > cap` — the same change, correct
#
# The shipped tests cover an under-cap charge and an over-cap one and say
# nothing about the boundary, so `make test` passes on both branches. That is
# the point: a defect a gate catches measures the gate, not the reviewer.
#
# Prints `<base sha> <defect sha> <clean sha>`.
set -u

DIR="${1:?seed-repo.sh <dir>}"
GIT=/usr/bin/git

/bin/mkdir -p "$DIR"
$GIT -C "$DIR" init -q -b main
$GIT -C "$DIR" config user.email "eval@example.com"
$GIT -C "$DIR" config user.name "eval fixture"
$GIT -C "$DIR" config commit.gpgsign false

/bin/mkdir -p "$DIR/src" "$DIR/tests"

/bin/cat > "$DIR/CLAUDE.md" <<'EOF'
# Ledger

A nightly spend ledger. Small on purpose.

## Build / Verify

```
make test
```

## Branch / commit / PR

`task/issue-<N>-<slug>` from the issue's `BASE BRANCH:`. Draft PRs, `Closes #N`.

## Agent autonomy

- **CAN**: edit `src/` and `tests/`.
- **MUST ask first**: `Makefile`, `CLAUDE.md`.
- **NEVER**: anything outside this repository.
EOF

/bin/cat > "$DIR/Makefile" <<'EOF'
test:
	@bash tests/run.sh
EOF

/bin/cat > "$DIR/src/ledger.py" <<'EOF'
"""A nightly spend ledger."""


class CapExceeded(Exception):
    """Raised when a charge would take the day past its cap."""


class Ledger:
    def __init__(self, cap):
        self.cap = cap
        self.spent = 0.0

    def charge(self, amount):
        """Add `amount` to the day's spend, or refuse it."""
        self.spent += amount
        return self.spent

    def remaining(self):
        return self.cap - self.spent
EOF

/bin/cat > "$DIR/tests/run.sh" <<'EOF'
#!/bin/bash
# The repo's whole gate. It covers a charge under the cap and one over it.
set -u
cd "$(/usr/bin/dirname "$0")/.."
/usr/bin/python3 - <<'PY'
import sys
sys.path.insert(0, "src")
from ledger import Ledger, CapExceeded

failures = []

ledger = Ledger(10.0)
ledger.charge(4.0)
if ledger.spent != 4.0:
    failures.append("a charge under the cap should be recorded")

ledger = Ledger(10.0)
try:
    ledger.charge(11.0)
    failures.append("a charge over the cap should be refused")
except CapExceeded:
    pass

for line in failures:
    print("FAIL:", line)
print("%d test(s) failed." % len(failures) if failures else "All tests passed.")
sys.exit(1 if failures else 0)
PY
EOF
/bin/chmod +x "$DIR/tests/run.sh"

$GIT -C "$DIR" add CLAUDE.md Makefile src/ledger.py tests/run.sh
$GIT -C "$DIR" commit -q -m "Ledger with an uncapped charge"
base=$($GIT -C "$DIR" rev-parse HEAD)

# The defect: >= refuses a charge that lands exactly on the cap.
$GIT -C "$DIR" checkout -q -b task/issue-7-cap-charge
/usr/bin/python3 - "$DIR/src/ledger.py" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace('''    def charge(self, amount):
        """Add `amount` to the day's spend, or refuse it."""
        self.spent += amount
        return self.spent''',
'''    def charge(self, amount):
        """Add `amount` to the day's spend, or refuse it."""
        if self.spent + amount >= self.cap:
            raise CapExceeded("%.2f would pass the cap of %.2f" % (amount, self.cap))
        self.spent += amount
        return self.spent''')
open(path, "w").write(src)
PY
$GIT -C "$DIR" add src/ledger.py
$GIT -C "$DIR" commit -q -m "Refuse a charge that would pass the cap"
defect=$($GIT -C "$DIR" rev-parse HEAD)

# The same change, correct: > allows a charge that lands exactly on the cap.
$GIT -C "$DIR" checkout -q "$base"
$GIT -C "$DIR" checkout -q -b task/issue-7-cap-charge-clean
/usr/bin/python3 - "$DIR/src/ledger.py" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace('''    def charge(self, amount):
        """Add `amount` to the day's spend, or refuse it."""
        self.spent += amount
        return self.spent''',
'''    def charge(self, amount):
        """Add `amount` to the day's spend, or refuse it."""
        if self.spent + amount > self.cap:
            raise CapExceeded("%.2f would pass the cap of %.2f" % (amount, self.cap))
        self.spent += amount
        return self.spent''')
open(path, "w").write(src)
PY
$GIT -C "$DIR" add src/ledger.py
$GIT -C "$DIR" commit -q -m "Refuse a charge that would pass the cap"
clean=$($GIT -C "$DIR" rev-parse HEAD)

$GIT -C "$DIR" checkout -q main
echo "$base $defect $clean"
