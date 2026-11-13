#!/usr/bin/python3
"""Grade one review-pr eval run.

Usage: grade.py <run-dir> <case: defect|clean> [--json]

What it reads, and nothing else:

  <run-dir>/result.txt      the run's final message, for the REVIEW: contract line
  <run-dir>/gh.log         one line per gh call, where a gap reads `UNHANDLED …`
  <run-dir>/gh.log.d/*.argv the NUL-separated argument vector of every gh call

Not whether the final message reads well. A reviewer that narrates a defect and
posts nothing has not reviewed anything, and one that posts a finding on the
wrong line has not found this one.

The two cases are graded against `expectations.md`, which is written before any
run and is not edited after seeing a score:

  defect  the review must carry a finding anchored to the planted line in
          src/ledger.py whose text names the comparison or the boundary, and its
          verdict must not be `pass`. A finding elsewhere in the file does not
          count: the criterion is that the reviewer found THIS defect.
  clean   the review must raise no blocker and no major. Minors are allowed and
          counted: a reviewer that always finds something fails this case, which
          is the false-finding half of the measurement.

A run whose gh log holds an UNHANDLED call is graded `harness-gap`, never as the
skill's failure: the fixture owes the skill an answer it did not have.
"""
import json
import os
import re
import sys

PLANTED_PATH = "src/ledger.py"
PLANTED_TEXT = re.compile(r">=|greater than or equal|exactly (the|at the) cap|boundary|off[- ]by[- ]one|"
                          r"equal to the cap|at the cap", re.I)
REVIEW_LINE = re.compile(
    r"^[ \t]*REVIEW:.*\bverdict=(?P<verdict>pass|changes-needed|escalate)\b.*"
    r"\bfindings=(?P<b>\d+)/(?P<m>\d+)/(?P<mi>\d+)\b", re.M)
GATE_IN_LINE = re.compile(r"\bgate=(?P<gate>passed|failed|no-gate|could-not-run)\b")
FINDING_TAG = re.compile(r"<!--\s*finding:(?P<id>\S+)\s+severity:(?P<severity>\S+)\s+round:(?P<round>\d+)\s*-->")


def read_calls(run_dir):
    """Every recording-gh call, as its argument vector."""
    calls = []
    argv_dir = os.path.join(run_dir, "gh.log.d")
    if not os.path.isdir(argv_dir):
        return calls
    for name in sorted(os.listdir(argv_dir)):
        if not name.endswith(".argv"):
            continue
        with open(os.path.join(argv_dir, name), encoding="utf-8", errors="replace") as fh:
            argv = fh.read().split("\0")
        if argv and argv[-1] == "":
            argv.pop()
        calls.append(argv)
    return calls


def gh_log(run_dir):
    path = os.path.join(run_dir, "gh.log")
    if not os.path.exists(path):
        return ""
    return open(path, encoding="utf-8", errors="replace").read()


def posted_review(calls):
    """(summary, [finding]) from the review POST, or (None, []) if none was posted."""
    for argv in calls:
        joined = " ".join(argv)
        if "/reviews" not in joined or "POST" not in joined:
            continue
        summary, findings, current = "", [], {}
        payload = next((a[len("@json:"):] for a in argv if a.startswith("@json:")), None)
        if payload is not None:
            try:
                doc = json.loads(payload)
            except ValueError:
                doc = {}
            return doc.get("body", ""), [
                {"path": c.get("path"), "line": str(c.get("line")), "body": c.get("body", "")}
                for c in doc.get("comments", [])]
        for i, arg in enumerate(argv):
            if arg.startswith("body=") and i and argv[i - 1] in ("-f", "-F", "--raw-field", "--field"):
                summary = arg[len("body="):]
            elif arg.startswith("comments[][path]="):
                if current:
                    findings.append(current)
                current = {"path": arg.split("=", 1)[1]}
            elif arg.startswith("comments[][line]="):
                current["line"] = arg.split("=", 1)[1]
            elif arg.startswith("comments[][body]="):
                current["body"] = arg.split("=", 1)[1]
        if current:
            findings.append(current)
        return summary, findings
    return None, []


def severity_of(finding):
    tag = FINDING_TAG.search(finding.get("body") or "")
    return (tag.group("severity").lower() if tag else "untagged")


def planted_line(run_dir):
    """The line the defect sits on, read from the case's own diff."""
    patch = os.path.join(run_dir, "case", "diff.patch")
    if not os.path.exists(patch):
        return None
    line_no, current = None, None
    for line in open(patch, encoding="utf-8", errors="replace"):
        hunk = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)", line)
        if hunk:
            current = int(hunk.group(1))
            continue
        if current is None:
            continue
        if line.startswith("+"):
            if ">=" in line:
                line_no = current
            current += 1
        elif not line.startswith("-"):
            current += 1
    return line_no


def grade(run_dir, case):
    result_path = os.path.join(run_dir, "result.txt")
    result = open(result_path, encoding="utf-8", errors="replace").read() if os.path.exists(result_path) else ""
    calls = read_calls(run_dir)
    out = {"case": case, "run": os.path.basename(run_dir.rstrip("/")), "failures": []}

    # The recording gh writes UNHANDLED into the log, not into the argv file:
    # that file holds the call's own arguments, exactly as it made them.
    unhandled = [line for line in gh_log(run_dir).split("\n") if line.startswith("UNHANDLED ")]
    if unhandled:
        out["outcome"] = "harness-gap"
        out["failures"].append("the fixture had no answer for: %s" % unhandled[0][len("UNHANDLED "):])
        return out

    match = REVIEW_LINE.search(result)
    if not match:
        out["outcome"] = "no-contract-line"
        out["failures"].append("the final message carries no REVIEW: line with a verdict and findings")
        return out
    gate = GATE_IN_LINE.search(match.group(0))
    out["verdict"] = match.group("verdict")
    out["gate"] = gate.group("gate") if gate else "(absent)"
    out["counts"] = {"blocker": int(match.group("b")), "major": int(match.group("m")),
                     "minor": int(match.group("mi"))}

    summary, findings = posted_review(calls)
    out["posted"] = summary is not None
    out["findings"] = [{"path": f.get("path"), "line": f.get("line"), "severity": severity_of(f)}
                       for f in findings]

    if summary is None:
        out["outcome"] = "fail"
        out["failures"].append("no review was posted, so nothing reached the pull request")
        return out

    if case == "defect":
        target = planted_line(run_dir)
        out["planted_line"] = target
        hit = None
        for finding in findings:
            if finding.get("path") != PLANTED_PATH:
                continue
            if target is not None and str(finding.get("line")) != str(target):
                continue
            if PLANTED_TEXT.search(finding.get("body") or ""):
                hit = finding
                break
        out["outcome"] = "catch" if hit else "miss"
        if not hit:
            out["failures"].append(
                "no finding anchored to %s:%s names the comparison or the boundary"
                % (PLANTED_PATH, target))
        if out["verdict"] == "pass":
            out["outcome"] = "miss"
            out["failures"].append("verdict=pass on a pull request that breaks its second criterion")
    else:
        loud = [f for f in out["findings"] if f["severity"] in ("blocker", "major")]
        out["outcome"] = "clean" if not loud else "false-finding"
        for finding in loud:
            out["failures"].append(
                "raised a %s on %s:%s in a pull request that meets its criteria"
                % (finding["severity"], finding["path"], finding["line"]))
        if out["counts"]["blocker"] or out["counts"]["major"]:
            if out["outcome"] == "clean":
                out["outcome"] = "false-finding"
                out["failures"].append(
                    "the REVIEW: line counts %d blocker and %d major with no such finding posted"
                    % (out["counts"]["blocker"], out["counts"]["major"]))
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().split("\n")[2], file=sys.stderr)
        return 2
    run_dir, case = sys.argv[1], sys.argv[2]
    if case not in ("defect", "clean"):
        print("grade.py: case is defect or clean, got %r" % case, file=sys.stderr)
        return 2
    out = grade(run_dir, case)
    if "--json" in sys.argv[3:]:
        print(json.dumps(out, indent=1))
    else:
        print("GRADE: case=%s outcome=%s verdict=%s gate=%s findings=%s" % (
            out["case"], out["outcome"], out.get("verdict", "-"), out.get("gate", "-"),
            len(out.get("findings", []))))
        for failure in out["failures"]:
            print("  - %s" % failure)
    return 0 if out["outcome"] in ("catch", "clean") else 1


if __name__ == "__main__":
    sys.exit(main())
