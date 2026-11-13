# BASELINE-CODING.md

Coding-level detail extending `BASELINE.md`, for skills that write code (`work-on-task`, `iterate-on-pr`). Read `BASELINE.md` first — its five principles are the contract; this file carries the detail they compress. The same inheritance rule applies: this file overrides any local skill instruction that conflicts with it.

---

## Hard halt conditions (Principle 1 — Think Before Coding)

Any one triggers a full stop, not just a flag:
- **Confidence below threshold** — the task's intent is genuinely ambiguous, or you can't see how the change should work given the codebase.
- **Permissions not granted** — the work requires a "MUST ask first" action that isn't pre-authorised in the issue.
- **Contradictory information** — the issue conflicts with `CLAUDE.md`, or two reference files disagree.
- **Capability gap** — the work needs something outside your tooling (real payments, real emails, manual UI testing).

When you halt, post a comment on the issue (if applicable) describing what's unclear with specific questions, and exit cleanly. Resolve uncertainty at the START, not mid-execution — mid-flight clarifications are expensive.

## Simplicity mechanics (Principle 2 — Simplicity First)

- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

**Scope circuit-breaker:** stop and split when the change would satisfy more than one issue's acceptance criteria. Surface it as a comment on the issue ("This is probably two issues, not one") and stop. A MUST-ask-first area is not a split: it is the *Permissions not granted* halt above. Step and file counts alone are not a reason to stop: one coherent change can touch many files. Per-run counts live in each skill, such as `iterate-on-pr`'s `MAX_THREADS`.

**Line count is not a quality signal.** A focused 400-line module that has one cohesive concern is fine; a 50-line module that mixes unrelated concerns is worse. Never propose, justify, or accept a refactor on the basis that "this file is too long" alone. Valid splitting triggers are *coupling and cohesion* — concrete things like:
- One file is touched by multiple independent concerns that change at different rates
- A specific section is duplicated across files (extract to share)
- The file has multiple unrelated responsibilities the rest of the codebase has to reason about
- A change you NEED to make is being blocked because the surrounding code is tangled

If a repo's `.cursorrules`, `CLAUDE.md`, or style guide states a hard line-count mandate, treat it as a hint for code review attention, **not** as a proposal trigger. Surface the mismatch ("file X exceeds the stated limit but has a single cohesive concern — propose to relax the rule, not split the file") rather than auto-generating split tasks.

## Surgical mechanics (Principle 3 — Surgical Changes)

- If you notice unrelated dead code, mention it in the PR body as "Noted (not changed)" — don't delete it.
- Remove imports/variables/functions that YOUR changes made unused. Don't remove pre-existing dead code unless asked.

## `replace_all` discipline (Principle 3 — Surgical Changes)

Use `replace_all=true` only when you've verified that every matching occurrence should change identically. The same string often means different things in different contexts (translations sharing English text, variables sharing names across scopes, gendered/declined forms in i18n, comments that happen to match code). When in doubt, prefer N targeted Edits with surrounding context.

## Verify gate & retry budget (Principle 4 — Goal-Driven Execution)

Transform tasks into verifiable goals:

| Instead of... | Transform to... |
|--------------|-----------------|
| "Add validation" | "Write tests for invalid inputs, then make them pass" |
| "Fix the bug" | "Write a test that reproduces it, then make it pass" |
| "Refactor X" | "Ensure tests pass before and after" |

For multi-step tasks, state a brief plan with per-step verify checks:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Run the project's verify gate (from `CLAUDE.md`) before declaring done. **Retry budget: 2 attempts.** After two failed retries, stop and report — don't keep flailing.

**Never** to make a verify "pass": disable tests, comment out failing code, downgrade types, `// @ts-ignore`, `// eslint-disable`, or skip type-check / lint. If the verify can't pass cleanly, the change is wrong — stop and reconsider.

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.
