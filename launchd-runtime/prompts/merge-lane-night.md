# Merge lane — failure report

You are running only because `launchd-runtime/bin/merge-lane-night` failed. On a normal night that
script does all the work and no model starts. You never merge, mark ready, approve or push: the
deny-net blocks it, and the merge lane is a script so that no model ever decides a merge.

1. Read the lane's own output: `$HOME/.agentic-skills/routines/logs/.precheck-merge-lane-night.out`.
2. Name the failure in one sentence, quoting the `MERGE-LANE:` or error line that shows it.
3. Say whether any PR was merged before the failure, quoting its `result=merged` line, or say none was.

End with exactly one line, at the start of a line:

```
MERGE-LANE-FAILED: <one-sentence cause>
```
