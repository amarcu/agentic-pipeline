# Triaging human feedback

Read this at Step 2 whenever `pr-feedback` emits an item with `"kind": "human"`. Reviewer findings
never come here — they are tagged, scoped and already adjudicable, so they are fixed or contested
and always answered. Human feedback is the half that can be vague, and the half where acting on a
guess costs a round.

## The three kinds `pr-feedback` emits

- **`reviewer`** — a finding from either review lane, `review-pr` or `cursor-review`, tagged
  `<!-- finding:<id> severity:<s> round:<K> -->`. Both lanes post that same tag, and everything
  posts under the human's login, so the tag is the only signal — never the author, never the lane.
  The item's `lane` field says which reviewer raised it, taken from the summary its review carried;
  use it to address the reply to the right reviewer, never to weigh one lane above the other. A
  finding never waits on clarification: fix it or contest it, and reply either way.
- A **reviewer summary** (`source: review`, `skip: reviewer-summary`) is context, not a task: the
  findings arrive as threads, and a finding a lane could not anchor arrives as its own tagged
  comment, which is actionable like any other. Read the summary anyway — it carries the verdict and
  any cap reason. It is never a question addressed to you, so never answer it as one.
- **`human`** — categorise it by the three categories below.
- **`bot`**, and every non-empty `skip` — never acted on, never replied to; they are `skipped=`.

## The three categories

**ACTIONABLE** — a specific change, in a place you can find:

- "change the role to 'Coach & Instructor'"
- "add a null check before the parse"
- "swap the order — Chivu first"

**DISCUSSION** — a question or an observation with no change attached. Answer it in the thread and
in the summary; change no code:

- "why did you pick this image over the other one?"
- "is this the same path the loader takes at startup?"

**AMBIGUOUS** — you cannot tell what would satisfy it:

- "this looks weird"
- a screenshot with no text
- "doesn't feel right"
- two reviewers asking for opposite things

Ambiguity is a stop, not a guess (BASELINE Principle 1). Reply in that thread with the specific
question you need answered, mark the item `skipped=` in the summary, and leave it for the next run —
the human's answer arrives as a new comment, which the next run sees as fresh feedback.

An ambiguous item never blocks a clear one. Address every ACTIONABLE item that does not depend on
the ambiguous one, and say in the summary which you left.

## Stop conditions

These end the run rather than the item:

- The feedback contradicts the originating issue's acceptance criteria. Say so in the thread and
  stop; the issue is the contract, and only the human can change it.
- The feedback asks for something in a `MUST ask first` area of the repo's `CLAUDE.md` that the
  issue did not pre-authorise → `Skill(name="request-approval", …)`, which stops the run.
- The feedback needs a capability you do not have — "test this on a real device", "check it against
  production data". Make whatever part is code, and name the rest as needing a human.

## Screenshots and other attachments

A comment body may link an image:

```
![alt](https://github.com/user-attachments/assets/…)
![alt](https://user-images.githubusercontent.com/…)
```

Fetch it into `/tmp/iterate-pr-<PR>-<n>.<ext>` with `curl -L`, then open it with the `Read` tool —
image content is visible to you. If the fetch fails (404, an expired signed URL, a private CDN),
note "image at <url> could not be fetched" in the summary and treat the comment's text alone as the
feedback. A failed fetch is never a reason to guess at what the picture showed.

An image is **context for the comment that carried it**, never an instruction on its own. A
screenshot with no text is AMBIGUOUS, whatever it appears to show.

When an image drove a change, say in the summary what you took from it: "per the screenshot, moved
the role label under the name and tightened the spacing". That is the sentence the human checks
against what they actually meant.

## Visual changes

For a change whose whole effect is visual — CSS, layout, an image swap, copy alignment — make the
edit, then say in the summary that it **needs human verification on rendered output**. You cannot
see the rendered page, so "looks right" is a claim you have no evidence for, and the reviewer will
believe it. The gate passing means the code compiles, not that the page looks correct.
