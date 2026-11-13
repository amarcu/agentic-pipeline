# The assessment output

One template, read at Step 3. Nothing in `SKILL.md` restates it.

The parsable line leads so a log grep never has to read the prose. Everything below it is for a
human skimming the routine log.

```
ASSESS: run=<id> checkout=<sha7> skills=<n> findings=<f> issues=<i>

Skill Assessment — <YYYY-MM-DD>

ACTION REQUIRED (<n>):
  <skill> — <what is wrong> → <what to fix>
ADVISORY (<n>):
  <the WARN line, verbatim from the suite>
ALL GOOD (<n>):
  <skill>, <skill>, …
```

## The fields

- `run` — `$ROUTINE_RUN_ID`, or `skill-assess-<YYYY-MM-DD>` when unset (an interactive run).
- `checkout` — `git rev-parse --short HEAD`. Two runs that disagree are two different trees, which
  is the first thing to check when a finding cannot be reproduced.
- `skills` — the roster size after `--skill` narrowing.
- `findings` — the Action required count. Not the issue count: a finding already filed does not
  get a second issue.
- `issues` — issues actually created this run. `0` on every run without `--update`, and `0` on an
  `--update` run where every finding was already filed.

## The sections

Print a section only when it has entries, except `ALL GOOD`, which prints even empty so the output
always says how many skills were clean.

- **ACTION REQUIRED** — a `FAIL:` line from the static suite, a path or command in a body that no
  longer resolves, or a `description` that no longer describes the body. These are what `--update`
  files issues for.
- **ADVISORY** — a `WARN:` line from the suite, quoted as printed. Never filed and never counted in
  `findings`; a wording nit is a human's call, not a ticket.
- **ALL GOOD** — everything else, named on one wrapped line rather than one line each.

## The Telegram, when Action required is above zero

Counts and links only — the prose stays on stdout, which is auditable and free.

```
Skill Assessment — <YYYY-MM-DD>

<n> skills reviewed, <f> findings.
Action required: <n> — <skill>, <skill>

Issues: <url>, <url>
```
