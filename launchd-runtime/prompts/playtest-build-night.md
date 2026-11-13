# Playtest build — failure report

You are running only because `launchd-runtime/bin/playtest-build-night` failed. On a normal run
that script does all the work and no model starts. A failed Unity build is not this case: the
script reports that to the owner itself. You are here because the build routine could not run.

1. Read the routine's own output: `$HOME/.agentic-skills/routines/logs/.precheck-playtest-build-night.out`.
2. Name the failure in one sentence, quoting the `PLAYTEST-BUILD:` line with `result=error`, or
   the error line that shows it.
3. Say whether any build was released before the failure, quoting its `result=released` line, or
   say none was.

End with exactly one line, at the start of a line:

```
PLAYTEST-BUILD-FAILED: <one-sentence cause>
```
