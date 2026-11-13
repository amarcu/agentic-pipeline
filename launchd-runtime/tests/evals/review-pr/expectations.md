# What each case must do

Written 2026-09-14, before the first run, and not edited after seeing a score. A score that argues
for a softer bar belongs in the report, as a finding about the bar.

Both cases review the same pull request against the same issue. The only difference is one character
in `src/ledger.py`, and the repository's own gate passes either way — a defect a gate catches
measures the gate, not the reviewer.

## The contract under review

The issue's acceptance criteria, in full:

1. `charge()` raises `CapExceeded` when the total would go over the cap, and the ledger's spend is
   unchanged by the refused charge.
2. A charge that brings the total to exactly the cap is allowed, because the cap is a ceiling and not
   a limit below it.
3. `make test` passes.

## Case `defect`

`src/ledger.py` refuses at `spent + amount >= cap`, so a charge landing exactly on the cap is
refused. Criterion 2 is broken. The shipped tests cover an under-cap charge and an over-cap one and
say nothing about the boundary, so `make test` passes.

**A run counts as a catch when all of these hold:**

- a finding is posted as an inline comment on `src/ledger.py`, anchored to the line the diff adds the
  comparison on;
- that finding's text names the comparison or the boundary — `>=`, "exactly the cap", "at the cap",
  "off by one", "equal to the cap";
- the verdict is not `pass`.

Anything else is a miss, including: a verdict of `changes-needed` with no finding on that line, a
finding that says the code is "risky" without naming what is wrong, and a finding on the right file
but the wrong line. Naming the file is not finding the defect.

## Case `clean`

The same change with `>`. Every criterion is met.

**A run counts as clean when no blocker and no major finding is raised** — neither posted as an
inline comment nor counted on the `REVIEW:` line. Minor findings are allowed and reported, because a
reviewer that always finds something is what this case is for.

## What is not graded

- Whether the prose reads well.
- Whether the verdict on `clean` is `pass` rather than `changes-needed`: the gate's own outcome can
  cap a verdict, and that is the protocol working, not a judgment error.
- Anything about cost or duration. They are recorded in the report and set no bar.

## Reporting

Both cases run `RUNS` times. The report states, per case, how many runs met the bar and quotes the
failure line from each that did not. A skill that catches the defect in one run of three is reported
as unreliable, not as passing: the number of runs is part of the result, never a single verdict.

A run whose recording `gh` logged an `UNHANDLED` call is a harness gap. It is excluded from the
score and named, because the fixture owed the skill an answer it did not have.
