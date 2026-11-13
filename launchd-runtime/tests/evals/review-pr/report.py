#!/usr/bin/python3
"""Report what a review-pr eval measured.

Usage: report.py <out-dir>

Reads each `<case>-<run>/grade.json` the runner wrote, and the `result.txt` and
`gh.log` beside it. Prints one block per case: how many runs met the bar, and
for every run that did not, the grader's reason and a line quoted from that
run's own transcript.

The quote is what makes the number checkable. `met=1/3` tells a reader the skill
is unreliable; it does not tell them what the other two runs did, and a score
nobody can trace is a number nobody acts on. The line quoted is the run's
`REVIEW:` contract line where it printed one — that is the skill's own statement
of what it decided — and the first line of its final message where it did not.

Harness gaps are counted apart and never scored: the fixture owed the skill an
answer it did not have, which says nothing about the skill.
"""
import json
import os
import sys

MET = {"catch", "clean"}


def quote(run_dir):
    """One line from the run's own transcript, for a reader to check the grade against."""
    result_path = os.path.join(run_dir, "result.txt")
    if os.path.exists(result_path):
        lines = [l.strip() for l in open(result_path, encoding="utf-8", errors="replace") if l.strip()]
        for line in lines:
            if line.startswith("REVIEW:"):
                return line
        if lines:
            return lines[0][:200]
    log = os.path.join(run_dir, "gh.log")
    if os.path.exists(log):
        for line in open(log, encoding="utf-8", errors="replace"):
            if line.startswith("UNHANDLED "):
                return line.strip()[:200]
    return "(this run left no transcript)"


def collect(out_dir):
    runs = []
    for name in sorted(os.listdir(out_dir)):
        run_dir = os.path.join(out_dir, name)
        grade_path = os.path.join(run_dir, "grade.json")
        if not os.path.isfile(grade_path):
            continue
        try:
            grade = json.load(open(grade_path))
        except ValueError:
            grade = {"case": name.rsplit("-", 1)[0], "outcome": "unreadable-grade", "failures": []}
        grade["dir"] = run_dir
        grade["name"] = name
        runs.append(grade)
    return runs


def report(out_dir):
    runs = collect(out_dir)
    if not runs:
        print("EVAL: no graded runs under %s" % out_dir)
        return 2

    lines, status = [], 0
    for case in sorted({r.get("case", "?") for r in runs}):
        mine = [r for r in runs if r.get("case") == case]
        gaps = [r for r in mine if r.get("outcome") == "harness-gap"]
        scored = [r for r in mine if r.get("outcome") != "harness-gap"]
        met = [r for r in scored if r.get("outcome") in MET]
        missed = [r for r in scored if r.get("outcome") not in MET]
        label = "catches" if case == "defect" else "clean runs"
        lines.append("EVAL: case=%s %s=%d/%d harness-gaps=%d" %
                     (case, label, len(met), len(scored), len(gaps)))
        if case == "clean":
            false_findings = sum(1 for r in scored if r.get("outcome") == "false-finding")
            lines.append("EVAL: case=clean false-finding runs=%d" % false_findings)
        for run in missed + gaps:
            lines.append("  %s — %s" % (run["name"], run.get("outcome", "?")))
            for failure in run.get("failures", []):
                lines.append("      %s" % failure)
            lines.append("      transcript: %s" % quote(run["dir"]))
        if missed:
            status = 1
    print("\n".join(lines))
    return status


def main():
    if len(sys.argv) != 2:
        print("usage: report.py <out-dir>", file=sys.stderr)
        return 2
    return report(sys.argv[1])


if __name__ == "__main__":
    sys.exit(main())
