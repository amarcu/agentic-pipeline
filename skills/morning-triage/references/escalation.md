# The escalation recipe

Read this before the first write in Step 4. It is the only autonomous write `morning-triage` makes,
and it lives here rather than in `SKILL.md` because most mornings take neither branch — a hard
blocker has to sit untouched for two days to qualify.

Every value below is substituted **literally** from the run: no `$VAR`, no `$(date …)`, no
assignment. `VAR=$(...)` is permission-denied in a headless run, so a variable referenced here
would expand to nothing and the issue would be created against an empty repo name with an empty
title. That is not hypothetical: the pre-2026-09-03 version of this recipe used `"$BLOCKER_REPO"`,
`"$BLOCKER_URL"` and `$(date -u '+%Y-%m-%d')`, none of which was ever assigned.

The examples use `amarcu/StarBonk` issue 12, the run id `morning-triage-1756880000-4821` and the
date `2026-09-03`. Replace all four with the run's own values.

## 1. Create the label

`--label` fails outright on a label the repo has never seen, and `--force` makes the call
idempotent, so this runs every time rather than being conditional on a lookup:

```bash
gh label create escalated --repo amarcu/StarBonk --color d73a4a --force
```

## 2. Check for a predecessor

Idempotence (S7) is by the original item's URL, which the body's first line always carries:

```bash
gh issue list --repo amarcu/StarBonk --label escalated --state open --search "in:body https://github.com/amarcu/StarBonk/issues/12" --json number --jq length
```

A non-zero count means a previous run already escalated this item. Skip it and move on — do not
comment on the existing issue, and do not re-open a closed one. A human closing an escalation is
that human saying the matter is handled.

The URL is the key rather than the title because a title can be edited on the original item, and an
escalation that stops deduplicating is an escalation that arrives every single morning.

## 3. Write the body

```bash
cat > /tmp/morning-triage-escalation.txt << 'EOF'
Escalated by morning-triage run 2026-09-03 (morning-triage-1756880000-4821): https://github.com/amarcu/StarBonk/issues/12

Labels at escalation: blocker, bug. Unmoved for 4 days. Resolve the original or drop its priority,
then close this.

<!-- agentic-skills: skill=morning-triage repo=amarcu/StarBonk issue=12 routine=morning-triage run=morning-triage-1756880000-4821 model=claude-sonnet-5 -->
EOF
```

The first line is the attribution a human reads at 09:00 when they want to know which run wrote
this; the last is the S6 marker a later run greps. `routine=` and `run=` are the values Step 1
printed, with the word `interactive` in place of a run id of `none`. `issue=` is the **original**
item's number — the escalation issue's own number does not exist yet, and the marker's job is to
point back at what was escalated.

## 4. Create the issue

```bash
gh issue create --repo amarcu/StarBonk --title "Escalation: Loader crashes on boot" --label "escalated,automated" --body-file /tmp/morning-triage-escalation.txt
```

The title is exactly `Escalation: ` followed by the original's title, unedited. Two labels,
`escalated` and `automated`: the first is what step 2's search filters on, the second is what tells
a human at a glance that no person opened this.

Nothing is written to the original item — no label, no comment. Its labels are the human's
signal and the classification reads them; writing back would make the next run's input depend on
the last run's output.
