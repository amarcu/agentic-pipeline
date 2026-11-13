#!/usr/bin/python3
"""Render one review-pr eval case: the routes the recording gh answers, and
every response behind them.

Usage: render-case.py <case-dir> <repo-dir> <branch> <base-sha> <head-sha>

GitHub is never reached, so everything `review-pr` and `pr-review-bundle` ask
for is served from the seeded repository instead: the pull request's metadata,
its diff, its per-file patches, the tree at head, and the issue whose acceptance
criteria the review is judged against. The issue is the contract under review —
its second criterion is the one the planted defect breaks — so it is written
here, next to the expectations, and not in the runner.

The reviews list is served from a file the recording gh appends to, so the
skill's own Step 6 check reads back the review this run posted.
"""
import json
import os
import subprocess
import sys

REPO = "acme/evalrepo"
PR = 7
ISSUE = 7

ISSUE_BODY = """## Goal

A charge that would take the day past its cap is refused, and the ledger keeps the day's spend.

## Why now

The nightly runs have no ceiling today: a loop that charges in a retry can spend the month in a
night, and nothing stops it.

## Breakdown

- `charge()` refuses a charge that would take the total past the cap
- the refusal names the amount and the cap

## Implementation plan (advisory)

1. `src/ledger.py` — raise `CapExceeded` from `charge()` when the total would pass the cap.

## Acceptance criteria

- [ ] `charge()` raises `CapExceeded` when the total would go over the cap, and the ledger's spend is
      unchanged by the refused charge
- [ ] a charge that brings the total to exactly the cap is allowed, because the cap is a ceiling and
      not a limit below it
- [ ] `make test` passes

## Estimated size

XS — one comparison and its guard.

BASE BRANCH: main

## Reference files
- `src/ledger.py`
"""


def git(repo, *args):
    return subprocess.run(["/usr/bin/git", "-C", repo] + list(args),
                          capture_output=True, text=True, check=True).stdout


def main():
    case_dir, repo_dir, branch, base, head = sys.argv[1:6]
    os.makedirs(case_dir, exist_ok=True)

    diff = git(repo_dir, "diff", "%s..%s" % (base, head))
    open(os.path.join(case_dir, "diff.patch"), "w").write(diff)

    # files.json carries the per-file patch, which is what anchors an inline
    # comment to a line the diff actually touches.
    files = []
    for name in git(repo_dir, "diff", "--name-only", "%s..%s" % (base, head)).split("\n"):
        if not name.strip():
            continue
        patch = git(repo_dir, "diff", "%s..%s" % (base, head), "--", name)
        body = patch.split("\n@@", 1)
        files.append({
            "filename": name,
            "status": "modified",
            "patch": ("@@" + body[1]) if len(body) > 1 else "",
        })
    json.dump(files, open(os.path.join(case_dir, "files.json"), "w"), indent=1)

    # The bundle reads this with `--jq '.tree[] | select(.type=="blob") | .path'`,
    # and the recording gh applies that filter, so the file holds what GitHub
    # serves — a tree object — and not the answer the filter would produce.
    paths = [p for p in git(repo_dir, "ls-tree", "-r", "--name-only", head).split("\n") if p.strip()]
    json.dump({"sha": head, "truncated": False,
               "tree": [{"path": p, "type": "blob", "mode": "100644"} for p in paths]},
              open(os.path.join(case_dir, "tree.json"), "w"), indent=1)

    json.dump({
        "number": PR, "state": "OPEN", "isDraft": True,
        "headRefName": branch, "headRefOid": head, "baseRefName": "main",
        "changedFiles": len(files),
        "closingIssuesReferences": [{"number": ISSUE}],
        "labels": [],
    }, open(os.path.join(case_dir, "pr-view.json"), "w"), indent=1)

    json.dump({"number": ISSUE, "title": "Cap the day's spend", "body": ISSUE_BODY},
              open(os.path.join(case_dir, "issue.json"), "w"), indent=1)

    json.dump([], open(os.path.join(case_dir, "reviews.json"), "w"))
    json.dump([], open(os.path.join(case_dir, "comments.json"), "w"))
    json.dump({"id": 900001, "state": "COMMENTED"},
              open(os.path.join(case_dir, "review-posted.json"), "w"), indent=1)

    # First match wins, so the POST sits above the GET it would otherwise match.
    routes = [
        ("pr view %d .*--json .*closingIssuesReferences" % PR, 0, "pr-view.json"),
        ("pr view %d " % PR, 0, "pr-view.json"),
        ("pr diff %d " % PR, 0, "diff.patch"),
        ("api repos/%s/pulls/%d/files" % (REPO, PR), 0, "files.json"),
        ("api repos/%s/git/trees/" % REPO, 0, "tree.json"),
        ("issue view %d " % ISSUE, 0, "issue.json"),
        ("api repos/%s/pulls/%d/reviews.*(-X|--method) POST" % (REPO, PR), 0, "review-posted.json"),
        ("(-X|--method) POST.*api repos/%s/pulls/%d/reviews" % (REPO, PR), 0, "review-posted.json"),
        ("api repos/%s/pulls/%d/reviews" % (REPO, PR), 0, "reviews.json"),
        ("api repos/%s/pulls/%d/comments" % (REPO, PR), 0, "comments.json"),
        ("label create ", 0, "-"),
        ("pr edit %d " % PR, 0, "-"),
        ("auth status", 0, "-"),
        ("--version", 0, "-"),
    ]
    with open(os.path.join(case_dir, "routes.tsv"), "w") as fh:
        fh.write("# <extended regex>\\t<exit>\\t<response file, or ->\n")
        for pattern, code, response in routes:
            fh.write("%s\t%d\t%s\n" % (pattern, code, response))

    print(os.path.join(case_dir, "routes.tsv"))


if __name__ == "__main__":
    main()
