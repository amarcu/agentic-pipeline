# The Cursor review lane — 2026-09-08

An independent, non-Claude reviewer for the pipeline's pull requests, built as
`launchd-runtime/bin/cursor-review`. This document says what it is, what it needs from the
human before it can run, what has actually been verified against the real CLI, and what
has not.

## 1. Why the lane exists

Every pull request this pipeline produces has been written by Claude, reviewed by Claude and
gated by a command Claude chose to run. `pr-review-bundle` attacks that from one side: it
withholds the author's *framing* — the PR body, the commit messages, every worker comment —
so the reviewer cannot be talked into agreement. It cannot touch the other side. The reviewer
still shares the author's priors, its blind spots and its taste, because it is the same model
on the same account.

`review-pr/references/review-protocol.md` was written model-agnostic for exactly this: "any
reviewer that can read a diff, run a command and emit text can execute it." This lane is the
reviewer that file was waiting for. It reuses the bundle, hands the same protocol to a model
from a different vendor, and records the verdict in the same shape.

GitHub Copilot has been the second opinion until now. It ran out of quota mid-loop, and it
was never governed by the protocol — it commented on whatever it felt like. This lane is
governed.

## 2. What the human must do to make it live

The lane cannot run without a Cursor **User API Key**. This is not optional and not
substitutable: `cursor-agent status` reports "Login successful / Logged in" from the browser
login, and every API call still answers `Error: Authentication required`. The browser session
is not usable headless.

1. In the Cursor dashboard, open **Integrations** and create a **User API Key**.
2. Put it on disk, readable only by you:

   ```
   mkdir -p ~/.config/cursor
   umask 077
   cat > ~/.config/cursor/api-key      # paste the key, then Ctrl-D
   chmod 600 ~/.config/cursor/api-key
   ```

3. Confirm the wiring without spending anything:

   ```
   launchd-runtime/bin/cursor-review amarcu/agentic-pipeline 37 --dry-run
   ```

`cursor-review` reads `CURSOR_API_KEY` if it is set, and otherwise the first line of
`CURSOR_API_KEY_FILE` (default `~/.config/cursor/api-key`). It **refuses to run** if that file
is group- or world-readable, naming the mode it found. The key is placed in `cursor-agent`'s
environment and nowhere else: never an argument, never a log line, never echoed. A unit test
asserts the key does not appear in the child's argv, and the test mock records only whether a
key arrived, never its value.

To run the same lane on the pipeline host, the key file has to exist there too, with the same
mode. Nothing in this repository writes it, and nothing copies it between machines.

## 3. Model independence, and the rule that enforces it

Cursor's "Auto" routing cannot be pinned away from Anthropic models on an individual plan —
Cursor Router is a Teams/Enterprise feature — so independence has to come from passing an
explicit `--model`.

`cursor-agent --list-models` on this plan offers, among others:

| non-Anthropic | Anthropic |
|---|---|
| `cursor-grok-4.6-high`, `cursor-grok-4.6-xhigh`, `cursor-grok-4.5-high` | `claude-opus-5-*` |
| `gpt-5.6-sol-high`, `gpt-5.6-sol-xhigh`, `gpt-5.3-codex-high`, `gpt-5.3-codex-xhigh`, `gpt-5.2` | `claude-sonnet-5-*` |
| `gemini-3.7-flash-high`, `composer-2.5` | `claude-fable-5-*` |

The Anthropic ids sitting in the same list is precisely the failure mode this lane has to rule
out, because picking one silently restores Claude-reviews-Claude while everything else about
the run looks correct. So the model id is checked against
`claude|anthropic|opus|sonnet|haiku|fable`, case-insensitively, and a match is a refusal with
exit 6 — before the bundle is built and before any API call. The id that did run is recorded
in the verdict and in the marker on the posted review.

**The default is `cursor-grok-4.6-high`**, resolved from `--model`, then
`CURSOR_REVIEW_MODEL`, then the constant at the top of the script. It is chosen for two
reasons: it is not an Anthropic model, and it draws Cursor's own first-party pool, which on
an individual plan is far larger than the metered third-party pool the GPT and Gemini ids
draw from — so a nightly review lane does not burn through the metered allowance.
`cursor-grok-4.6-xhigh` is the same model at a deeper reasoning setting, worth passing by
hand for a PR that warrants the spend.

## 4. Reviewing the pipeline itself

`pr-review-bundle` refused, with exit 4, to bundle any PR whose diff touches
`launchd-runtime/`, a `*.plist`, `.github/` or a skill's `SKILL.md`. That refusal is right for
`review-pr` — a Claude reviewer passing judgement on the guardrails Claude runs under could
wave through a change to its own restraints — and it is wrong here, where the reviewer is a
different vendor's model and a change to the guardrails is exactly what most needs an outside
reader.

It also made the lane useless for this repository, whose every PR touches one of those paths.

So the bundler gained `--allow-pipeline`. Without it, behaviour is unchanged and `review-pr`
keeps refusing exactly as before. With it, the refusal becomes a recorded fact: the bundle is
built, `meta.json` carries `bundle.pipeline_diff` and a note, and `pipeline-notice.md` in the
bundle states that a non-Claude reviewer may review this PR and a Claude reviewer must
escalate instead.

`cursor-review` passes that flag, and sets it only **after** its model-independence check has
passed. The two guarantees are therefore one guarantee: a Claude model id exits at the check
and never reaches the bundler, so a Claude reviewer can never be handed a pipeline PR. A
static test pins the line ordering, and a unit test asserts the bundle is not even built when
the model is refused.

## 5. What it does, per run

1. Builds the isolated bundle by calling `pr-review-bundle` (it does not reimplement it) into
   `/tmp/review-<owner>-<repo>-<pr>-cursor` — a different directory from `review-pr`'s,
   because both lanes write `verdict.json` at the bundle root.
2. **Runs the repository's verify gate** in the bundle's `src/` tree and writes
   `<bundle>/gate.json`. See section 5a — this is the part that lets the lane ever say `pass`.
3. Assembles a prompt: the bundle's paths, the gate outcome, the round and its finding budgets
   from `repos.conf`; from round 2, the prior rounds' findings and the replies left on their
   threads (section 6a); then `review-pr/references/review-protocol.md` verbatim, then the
   exact verdict JSON shape to answer in.
4. Runs `cursor-agent -p <prompt> --model <id> --mode ask --trust --output-format json
   --workspace <bundle>` with stdin closed and the key in the environment.
5. Extracts the verdict object from the reply, overwrites its `gate` block with `gate.json`,
   caps a `pass` the gate or the findings do not support, writes `<bundle>/verdict.json` and
   copies it to
   `~/.agentic-skills/routines/metrics/review-<owner>-<repo>-<pr>-cursor-r<K>.json`.
6. With `--post`, submits one review to the PR: `event=COMMENT`, `commit_id` pinned to the
   bundled head SHA, findings as inline threads. Without `commit_id`, GitHub attaches the
   review to whatever the PR's head is at post time — a commit nobody read, if the head moved
   while the review was running.
7. Prints one line.

```
CURSOR REVIEW: run=<id|interactive> repo=<owner/repo> pr=<N> round=<K> head=<sha7> model=<id> verdict=<pass|changes-needed|escalate|error> findings=<b>/<m>/<n> cost=unknown tokens=<in>/<out>/<cacheRead>/<cacheWrite> req=<request_id> posted=<no|inline|body|failed>
```

`--dry-run` does all of that except invoking `cursor-agent` and except posting: it prints the
resolved model and the prompt's first 40 lines, and with `--post` it renders the exact review
body and inline comment list for a verdict already on disk, or says there is none yet.

## 5a. Who runs the verify gate, and why it had to be this script

This was the lane's one open question when it was built, and live data answered it on
2026-09-08. Grok's round-2 review of PR #35 marked all three prior findings `fixed`, raised no
new ones, and still returned `changes-needed`, for a single recorded reason:

```json
"gate": {"outcome": "could-not-run", "command": null, "exit": null}
"Verdict: changes-needed — src/ has no CLAUDE.md so the verify gate could-not-run"
```

`--mode ask` cannot execute commands. The protocol caps a `could-not-run` verdict at
`changes-needed`. So the lane could never return `pass` — a reviewer that cannot ever approve
anything is a reviewer nobody can act on. Two causes, both now fixed in this PR.

**Cause one: this repository declared no gate.** There was no root `CLAUDE.md` — the repo that
defines the standard requiring every project to declare its verify gate did not declare its
own, so neither the bundler nor a reviewer could find one. `CLAUDE.md` now exists at the root,
shaped like StarBonk's, and its gate is:

```
make test
```

with `make smoke` named explicitly as *not* part of the gate, because it spends API budget.

**Cause two: nobody ran the gate.** `pr-review-bundle` says "the reviewer has to run the
repo's gate … for itself", which is true for `review-pr` — Claude has a shell — and impossible
here. Giving Cursor execution would mean `--force`, which this lane forbids for the reason in
the previous section.

So `cursor-review` now runs the gate itself, before invoking the reviewer: it reads the command
from `src/CLAUDE.md`'s `## Build / Verify` section, runs it from `src/` under a timeout
(`CURSOR_REVIEW_GATE_TIMEOUT`, 600 seconds as written here and **raised to 2400 on 2026-09-14**,
after strategy-game's gate was measured at 1,179 s and StarBonk's was found to pass a larger inner
timeout than this outer one allowed), and writes `<bundle>/gate.json`:

```json
{"ran": true, "command": "make test", "exit": 0, "outcome": "passed",
 "first_error_line": null, "duration_s": 41.2, "reason": ""}
```

The four outcomes are the protocol's own. `passed` and `failed` come from the exit code;
`no-gate` from the `NO GATE — verify by reading` wording; `could-not-run` from no `src/`, no
`CLAUDE.md`, no command in the section, a missing tool (shell exit 127), or the timeout.
`first_error_line` is only extracted on a failure — a passing run's output can contain the word
"error" in perfectly happy prose, and quoting that as evidence would be a finding built on
nothing.

The prompt hands the reviewer that outcome and tells it to treat `gate.json` as authoritative,
quote it verbatim as evidence, and never claim it ran anything itself. The verdict's `gate`
block is then overwritten from `gate.json` rather than taken from the reply: a session that
cannot execute has nothing to report, so its own gate block is a guess, and replacing it is
bookkeeping rather than judgement.

**The verdict is capped where it contradicts the evidence.** The protocol puts two conditions
on `pass`: the gate reported success, *and* no blocker or major is open. Both were written down
and left to the reviewer's good faith. Neither needs judgement to check — the gate result is
this script's own, and whether a verdict contradicts the reviewer's own findings list is
arithmetic — so both are now applied in code:

- a gate outcome of `failed`, `no-gate` or `could-not-run` caps a `pass` to `changes-needed`;
- so does any finding of severity `blocker` or `major` whose `state` is not `fixed`.

`verdict_capped` records what the reviewer originally answered, why it was capped, and its own
stated reason, and the posted review body says a cap was applied and names the gate outcome or
the open finding that caused it. Nothing about the findings themselves is touched — only the
verdict the evidence does not support. What remains the reviewer's alone is whether a finding
is real and how severe it is.

**Trust.** Stated plainly, because the first version of this section understated it: what
happens here is that **an untrusted file decides what this machine executes, in a process that
holds a credential.** The command comes from `src/CLAUDE.md` at the head SHA of the pull
request under review, and it is arbitrary shell running as the user. That is the same trust the
pipeline already extends to a repo's gate — `work-on-task` runs it in a worktree, `review-pr`
in this same `src/` tree — but two things make it sharper here, and Grok's round-1 review of
PR #37 raised both:

- **The credential.** The gate now runs with `CURSOR_API_KEY`, `CURSOR_AUTH_TOKEN` and
  `CURSOR_API_KEY_FILE` stripped from its environment. It previously inherited them: the
  comment claiming otherwise held only when the key came from the key *file*, and an operator
  who exported `CURSOR_API_KEY` handed it straight to the gate. This is not a sandbox — shell
  running as this user can read the key file directly — but the credential is no longer given
  away by default to a command that might log its own environment. A test exports the key and
  asserts the gate child cannot see it.
- **The file itself.** A pull request editing any `CLAUDE.md` is now a pipeline change, because
  it changes what this lane executes. `pr-review-bundle`'s self-modification guard matches
  `CLAUDE.md` for that reason, so such a PR is refused for `review-pr` and reaches this lane
  only under `--allow-pipeline` with the notice recorded. It previously matched only
  `launchd-runtime/`, a `*.plist`, `.github/` and `*/SKILL.md`, so a `CLAUDE.md`-only diff
  changed the executed command while counting as an ordinary product change.

The exact string is recorded in `gate.json`, so what ran is never a question afterwards. It
never runs under `--dry-run`, and a test pins that by declaring a gate that would leave a
marker file if it were ever executed.

With both causes fixed, a clean PR with a passing gate and no findings can return `pass`.

### Why `--trust` is passed and `--force` never is

`cursor-agent` refuses to work in a directory it has not seen before: it prints a "Workspace
Trust Required" block and exits with no JSON at all, whatever `--output-format` says. Every
bundle directory is new, so the lane cannot run without `--trust`. That is safe only because
the session runs `--mode ask`, which cannot edit. `--force` and `--yolo` — the flags that let
the agent apply changes — are never passed, and both a unit test (on the recorded argv) and a
static test (on the source) pin that.

`cursor-review`'s own `--force` flag is unrelated: it means "post again even though this head
SHA already has a review", and is never forwarded to `cursor-agent`.

## 6. The trail on the pull request

`--post` submits **one** review per round through `gh api repos/<owner>/<repo>/pulls/<n>/reviews`
with `event=COMMENT`. Never `APPROVE`, never `REQUEST_CHANGES`, never `gh pr ready`, never a
merge. A `pass` verdict is posted as a comment saying it passed; the human merges. A static
test asserts `APPROVE` and `REQUEST_CHANGES` never appear in the script at all.

Everything posts under the repository owner's own GitHub login, because that is the only
account the CLI has. **The marker on the review body's first line is the only thing that tells
a Cursor review from one the human wrote:**

```
<!-- cursor-review repo=<owner/repo> pr=<N> round=<K> head=<sha> model=<id> verdict=<v> request_id=<id> -->
```

It is followed by a heading naming the model in plain words, a paragraph saying this is
deliberately not a Claude review and what the reviewer was and was not shown, the verdict and
its reason, and an index of the findings. The body closes with the repository's usual
attribution marker, `<!-- agentic-skills: script=cursor-review … -->`.

Each inline comment ends with `<!-- finding:<id> severity:<s> round:<K> -->` — byte-for-byte
what `iterate-on-pr/scripts/pr-feedback`'s `FINDING_RE` matches, so the existing fixer
consumes a Cursor finding with no change to it. A static test compares the two.

**Idempotence** is the head SHA: before posting, the PR's existing reviews are scanned for a
`cursor-review` marker carrying this `head=`. If one is there, the run prints
`already-posted head=<sha7>` and exits 0 *before* paying for a review — `--force` overrides.
The round number is the highest round seen in the PR's own markers or in the local metrics
files, plus one, so the PR is the durable record and a lost metrics file cannot restart the
count.

**When GitHub rejects the anchors**, which it does with a 422 for an inline comment on a line
the diff does not contain, the same review is posted again with the findings written out in
full in the body and a sentence saying why they are not inline. Nothing is dropped.

One deliberate subtlety in that fallback. `pr-feedback` classifies a review body carrying a
finding tag as `reviewer` and skips it as `reviewer-summary` — context for the threads, not a
thing to fix. So the tags appear in the summary index only when *every* finding went up
inline; the moment one lives in the body instead, the tags come out and the body stays
actionable. Duplicated feedback is a tolerable failure; a dropped finding is not.

## 6a. Adjudicating a prior round

The protocol says round 2 onwards adjudicates each earlier finding as `fixed`, `still-open` or
`contested`. Grok's round-2 finding f5 on PR #37 pointed out that this was unsatisfiable here:
the assembled prompt carried neither the prior findings nor the replies on their threads, so
the reviewer could only re-review from scratch, and any `state: fixed` it emitted was inference
from the diff rather than adjudication of anything.

From round 2, the prompt now carries a *Prior rounds* block built from two sources, matched by
finding id:

- **the findings** from this lane's own verdict files in the metrics directory, one per round.
  These are always written, so this half survives a run that never posted anything;
- **the replies** from the pull request's review comments — a root comment carrying the
  `<!-- finding:… -->` tag, and every comment answering it via `in_reply_to_id`.

Each entry shows the finding's id, severity, originating round, anchor and claim, then every
reply verbatim, or "No reply on this thread." where there is none — stating the absence rather
than letting it look like agreement. The block is followed by an instruction to adjudicate each
one with evidence, and by the explicit note that the per-round budget caps **new** findings
only, so adjudication can never be squeezed out by the cap.

## 7. Verified, and not verified

**Verified against the real CLI** (one probe, 2026-09-08):

- `cursor-agent` 2026.06.29 is installed at `~/.local/bin/cursor-agent` on this host and on
  the pipeline host.
- The browser login is not usable headless. A User API Key is required.
- `--trust` is required in a fresh directory, or no JSON comes back at all.
- The working invocation shape, with `CURSOR_API_KEY` in the environment and stdin closed.
- The envelope keys: `type, subtype, is_error, duration_ms, duration_api_ms, result,
  session_id, request_id, usage`, where `usage` is
  `{inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}`.
- **The `result` string carries prose before the answer.** The probe returned narration and
  then its finding. The parser therefore extracts the last self-contained JSON object
  containing a `verdict` key, skipping braces inside strings, and fails loudly with the raw
  first 500 characters when there is none. It never treats prose containing the word "pass"
  as a verdict.
- The model ids listed in section 3.

- **`--mode ask` cannot run the repo's gate.** Confirmed by Grok's round-2 verdict on PR #35,
  which recorded `could-not-run` with a null command. Section 5a is the resolution.

- **The lane reviewed itself, twice, and found six real defects.** Round 1 raised four `major`
  findings against this code — the gate inheriting the Cursor credential, a posted review with
  no `commit_id`, the unenforced pass cap, and a `CLAUDE.md`-only diff not counting as a
  pipeline change. Round 2, over a passing gate and with no regressions, raised two more: the
  prompt never carrying the prior round's findings, so the protocol's adjudication step was
  unsatisfiable (section 6a); and the pass cap covering only the gate half of the rule
  (section 5a). All six were valid and all six are fixed. One of them — f6 — closed an open
  question in this very document by disagreeing with it, which is the clearest evidence yet
  that the lane does what it was built for: none of the six would have been caught by the model
  that wrote the code.

**Verified by test, not by a live call**: everything else. Thirty-six tests cover a
well-formed verdict parsed and recorded, an unreadable answer failing loudly, every Anthropic
id spelling refused, a missing key, a group- or world-readable key file, `--dry-run` invoking,
posting and gating nothing, the posted review's event, marker and `commit_id`, the 422
fallback, idempotence on a repeat run, the pipeline opt-in in both directions, all four gate
outcomes, the gate's environment holding no credential, the pass cap under each of the three
gate outcomes that trigger it and under an unfixed blocker, and the round-2 prior-round block
built both from posted threads and from the local verdict files alone.

**Not verified:**

- No end-to-end run has yet exercised the gate step against a real pull request. Rounds 1 and 2
  on PR #35 ran before it existed. The immediate next step is re-running this lane against the
  repository's own open PRs, now that a gate can actually report `passed`.
- Whether the gate that `cursor-review` now runs behaves the same on the pipeline host as it
  does here. `make test` is hermetic and should, but it has only been exercised on this
  machine.
- Whether the reviewer honours the per-round finding budgets it is given. They are stated in
  the prompt; nothing enforces them on the way out.

## 8. Open questions

- **Cost per review is not reported.** The CLI returns token counts and no dollar figure —
  Cursor prices a request server-side — so the line says `cost=unknown` and carries the four
  token counts and the `request_id`. Reconciling spend means matching those request ids
  against the Cursor dashboard by hand. Until someone does that once, the marginal cost of a
  review on this plan is unknown, and `routine-cost` cannot include this lane.
- **The summary body is classified `human` by `pr-feedback` when any finding is not inline.**
  That is the deliberate choice described in section 6, and its cost is that `iterate-on-pr`
  may see the summary as one more actionable item alongside the threads. The one-line fix —
  adding `"<!-- cursor-review "` beside `REVIEW_SUMMARY_MARKER` in `pr-feedback` — is deferred
  because two open PRs are already editing `iterate-on-pr`.
- **Nothing gates on the verdict.** Like `review-pr`, this lane reviews and stops. Whether a
  Cursor `changes-needed` should block a merge, feed `iterate-on-pr`, or simply be read by the
  human is a decision that has not been made.
- ~~**Verdict self-consistency is half enforced.**~~ **Closed** by Grok's round-2 finding f6 on
  PR #37. I had written that a reviewer returning `pass` alongside an open blocker was taken at
  its word, "since counting its own findings is judgement rather than bookkeeping". That was
  wrong, and the review said so: the verdict JSON already carries `findings[]` with a
  `severity` and a `state`, so "`pass` while a `blocker` or `major` is not `fixed`" is a
  contradiction the parser can see without forming any opinion. The judgement I was protecting
  is whether a finding is real and how severe it is, and that still belongs to the reviewer.
  Both halves of the rule are now enforced in code — see section 5a.
- **One round per lane, counted separately.** Cursor's rounds and `review-pr`'s
  `review-round-<N>` labels are independent counts of the same PR. Neither gates the other,
  and `REVIEW_ROUND_MAX` applies to each separately, so a PR can receive three of each.
