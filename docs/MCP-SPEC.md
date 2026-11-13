# Converting agentic-skills to an MCP server — design spec

**Status:** Draft, 2026-05-22. Not yet implemented. Use this doc to decide *whether* to build the server before deciding *how*.

## Why this doc exists

Today our 10 skills are markdown files invoked via `/skill-name` slash commands inside Claude Code. They work — and the regression suite + BASELINE inheritance + per-routine timeouts give us decent reliability. But we've talked about MCP as a possible next layer. Before writing any code, this doc lays out:

1. What MCP-ifying skills would actually change for our workflow
2. Three viable architectures, with honest pros/cons
3. A recommended architecture (if we proceed)
4. What we'd commit to building, in what order
5. The case for *not* doing this yet

---

## Background — what a skill is today

```
agentic-skills/
└── work-on-task/
    ├── SKILL.md     # frontmatter (name, description, allowed-tools) + ~340 lines of instructions
    └── META.md      # version, status, last-assessed
```

Invocation flow:

1. User (or another skill via the `Skill` tool) types `/work-on-task <issue-num> --repo <repo>`
2. Claude Code reads `SKILL.md`, injects it into the session's system prompt
3. The same LLM session that received `/work-on-task` now executes the skill's instructions — Bash, Read, Edit, etc.
4. Done — the session continues with whatever the skill produced

**Key property:** a skill is a *prompt fragment*, not executable code. The "execution" is the LLM following instructions. The skill itself has no state, no process, no API.

**Today's distribution:** a skill is "installed" by being a directory under `~/.claude/commands/` (or anywhere Claude Code discovers slash commands). Other LLM clients (Cursor, raw API, Claude Desktop without our skills dir) can't invoke our skills.

---

## What MCP-ifying would actually change

| Today | With an MCP server |
|---|---|
| Skills discovered by Claude Code from a filesystem path | Skills discovered by any MCP client (Claude Code, Cursor, Claude Desktop, raw API) via tool listing |
| Invoked as `/skill-name` slash command | Invoked as `mcp__agentic-skills__<tool>` tool call with typed args |
| Skill content injected into the *same* session | (depending on architecture) skill content fetched as a resource OR a subprocess runs it OR the server orchestrates a flow |
| Per-invocation auth/limits handled by Claude Code | Server enforces auth/limits and can do so consistently across clients |
| Hosted only on this machine, under this user | Could be hosted as a daemon, exposed over HTTP, shared across machines |

The *interesting* changes are the last three: typed args, cross-client portability, and central enforcement. The *uninteresting* one is "discovery via tool listing" — slash commands already do that.

---

## Goals

If we build this, these are the things we'd be optimising for:

1. **Single source of truth for "what skills exist"** — accessible from any MCP client, not just Claude Code with a particular checkout.
2. **Typed, validated invocation** — `propose_tasks(repo="acme/club-site", max=5, dry_run=true)` instead of slash-command arg parsing.
3. **Central enforcement of safety rules** — every skill invocation goes through one server that can refuse, log, rate-limit, or require approval.
4. **Reusable observability** — tool calls in/out logged uniformly, regardless of which client triggered them.
5. **Optional remote use** — could expose the server over HTTPS (with auth) so a phone, a CI runner, or another machine could trigger skills.

## Non-goals (explicitly out of scope)

- Replacing slash commands inside Claude Code. They keep working. MCP is additive.
- Multi-tenant — single user, single Mac.
- High availability — local-first, daemon dies → restart it.
- Real-time pub/sub of progress (could come later via SSE).
- Making the LLM "smarter" — same model, just typed plumbing.

---

## Architecture options

Three credible shapes. Each makes different trade-offs.

### Option A — Skills as MCP **resources**

The server exposes each skill's content as a resource. Tool surface is *one* tool: `agentic_skills.invoke(name, args)` that returns the rendered prompt for the named skill.

```
client.list_resources()  →  ["agentic-skills://skill/work-on-task", ...]
client.read_resource("agentic-skills://skill/work-on-task")
  →  the full SKILL.md content with args interpolated
```

The calling LLM reads the prompt and follows it in its own session.

**Pros:** trivial to build (~100 lines). Server is stateless. Faithful to current model (skills are prompts).
**Cons:** Adds almost nothing over slash commands. Doesn't give typed validation. Doesn't enforce safety rules — the calling LLM is on the honour system. Not really "agentic", just "skill text as a service".

### Option B — Skills as MCP **tools that spawn claude-cli**

Each skill becomes one tool. The tool's implementation spawns `claude-cli -p "<skill prompt with args>"` as a subprocess, captures its output, returns it to the caller.

```
client.call_tool("agentic_skills.work_on_task", {issue: 5, repo: "acme/club-site"})
  → server runs `claude-cli -p <work-on-task prompt> --add-dir <repo path>`
  → server streams the subprocess output back
  → returns final result + PR URL
```

**Pros:** Real typed surface (`issue: int, repo: str`). Centralised auth + rate-limits + logging. Can run long-running work via SSE. Distinct claude session per invocation so context is clean.
**Cons:** Recursion — agent calls agent. Each invocation is a fresh claude-cli process (full prompt load, full caffeinate, full token cost). Hard to reuse the calling session's context. Long-running ops (work-on-task takes minutes) need careful timeout handling.

### Option C — Skills as **granular structured tools**

Decompose each skill into small typed tool calls. Instead of one `work_on_task` tool, the server exposes:

```
issues.list_approved(repo)
issues.get_dependencies(issue_url)
worktree.create(repo, branch_name)
project.read_claude_md(repo)
plan.write(steps)
verify.run_gate(repo)
pr.create_draft(repo, head, base, title, body)
notify.telegram(message)
```

The *calling LLM* (in any client) orchestrates these atoms, guided by the skill content if any — but the skill content is now optional prompt material rather than the execution engine.

**Pros:** Most "MCP-native". Maximally inspectable (each call is a discrete event). Easiest to add safety gates at specific operations. Reusable across many skills (worktree.create is the same in every skill that uses one).
**Cons:** Biggest rewrite. Skills currently bundle "what to do" with "how to do it"; this separates them and requires re-writing every skill as orchestration prompts. The LLM in *every* client needs to learn the orchestration pattern. We lose the "skills are self-contained" property.

---

## Recommendation: **Hybrid (B + slice of C)**

A pragmatic shape:

- **Read-only / discovery skills** (`triage-repo`, `morning-triage`, `daily-summary`, `notify`) → **Option C** style. Decompose into atoms: `triage.classify_issue`, `triage.scan_repo`, `notify.send`, etc. These have no LLM-intensive work — they're mostly data-shaping.
- **Work-intensive skills** (`work-on-task`, `iterate-on-pr`, `propose-tasks`, `dispatch-tasks`) → **Option B** style. One tool per skill, spawn `claude-cli` subprocess. The LLM has to *do work* (read code, plan, edit, verify), and a fresh session is appropriate.
- **Skills that orchestrate other skills** (`dispatch-tasks` calls `work-on-task` 5×) → Option B at the outer level, with the inner calls also Option B but recognised as nested.

This keeps:
- Skills as a unit (Option A's spirit) for the work-intensive ones
- Atomic typed surface (Option C's spirit) for the structured data work
- Reasonable build cost — maybe 1-2 weeks of part-time work, not a quarter

---

## Proposed tool surface

Naming convention: `mcp__agentic_skills__<verb>_<noun>` or `<skill_name>`.

**Read-only data tools (C-style):**
- `repos.list()` → 9 tracked repos with paths and workspaces
- `repos.path(repo)` → on-disk path for a given repo
- `issues.list_open(repo, label?)` → typed issue array
- `issues.dependencies(issue_url)` → parsed DEPENDS ON refs
- `prs.list_open(repo, draft_only?, ready_only?)` → typed PR array
- `routines.status()` → last-run state of every launchd routine
- `notify.send(message, attach_issue?)` → Telegram + optional GitHub issue

**Work-intensive tools (B-style — spawn claude-cli):**
- `work_on_task(issue_number, repo)` → opens draft PR, returns URL
- `iterate_on_pr(pr_number, repo)` → addresses review feedback, returns commits pushed
- `propose_tasks(repo, max?)` → creates N proposed issues, returns URLs
- `dispatch_tasks(per_repo_max?, total_max?, dry_run?)` → runs full dispatch, returns digest
- `daily_summary()` → produces evening digest
- `triage_repo(repo)` → classified report
- `morning_triage()` → multi-repo digest

**Orchestrator tools (special — invoke other tools):**
- `dispatch.run_cycle(...)` → like dispatch_tasks but with explicit progress streaming

Each work-intensive tool accepts:
- All the typed args the slash command does today
- Optional `effort` (low/medium/high/xhigh) — passed through to claude-cli
- Optional `dry_run` (where the skill supports it)

Each tool returns:
- `status`: one of `success | halted | failed`
- `summary`: short human-readable
- `artifacts`: array of URLs (PRs created, issues opened, etc.)
- `log_tail`: last N lines of the underlying claude-cli log
- `duration_ms`, `tokens_used` (when available)

---

## Schemas — example

`work_on_task` request:
```json
{
  "issue_number": 8,
  "repo": "acme/club-site",
  "from_branch": "main",
  "effort": "high",
  "skip_ac_check": false
}
```

`work_on_task` response (success):
```json
{
  "status": "success",
  "summary": "PR #10 opened",
  "artifacts": [
    {"type": "pr", "url": "https://github.com/acme/club-site/pull/10"},
    {"type": "worktree", "path": "~/code/club-site/.claude/worktrees/issue-8-..."}
  ],
  "log_tail": "...",
  "duration_ms": 187432,
  "tokens_used": 142883
}
```

`work_on_task` response (halted — common case):
```json
{
  "status": "halted",
  "summary": "Pre-flight clarification needed (BASELINE Principle 1)",
  "reason": "Issue body lacks acceptance criteria; comment posted on issue #8",
  "artifacts": [{"type": "comment", "url": "..."}]
}
```

---

## Execution model — how each tool actually runs

### Read-only data tools

Pure Go/Python/Node — no LLM involved. Call the underlying API (`gh`, filesystem, pmset), shape the result, return. Sub-millisecond to a few seconds.

### Work-intensive tools

The server spawns `claude-cli -p "<prompt>" --add-dir <repo path> --dangerously-skip-permissions --effort <effort>` as a subprocess. Same protections as today's `_run.sh`:

- AC-power precheck
- `caffeinate -s -d -i -w <child_pid>`
- Wall-clock watchdog (per-tool timeout)
- `kill_tree` on timeout

Critical differences from today's `_run.sh`:

- The MCP server holds the subprocess handle, can stream stdout to the caller via SSE
- Tool returns *only* when the subprocess exits (or watchdog kills it)
- No Telegram emitted by default (the caller decides whether to surface to a human; the launchd-runtime would set a `notify_on_completion` flag)

We can literally call into `_run.sh` from the MCP server — that keeps the runner as the source of truth for the agentic execution discipline, and the server is a thin RPC wrapper.

---

## State and concurrency

**State:** the server is stateless across invocations except for:
- A per-invocation log directory (`~/.agentic-skills/sessions/<uuid>/`)
- A queue of running work-intensive subprocesses (in-memory, lost on restart)

**Concurrency caps** (per the BASELINE Scope Circuit Breaker philosophy):
- At most 1 concurrent `work_on_task` invocation across all repos (the rationale: each holds a worktree, opens a PR, runs `npm install` — running two in parallel risks port conflicts, npm cache races, GitHub rate limits)
- At most 1 concurrent `dispatch_tasks` invocation
- Read-only tools: no limits

**Queue behaviour:** if a second `work_on_task` arrives while one is running, the server either (a) returns 429 Busy, (b) queues, or (c) cancels the running one. Default: (a) Busy. The caller decides whether to wait or move on.

---

## Auth and secrets

Three secrets in play:

| Secret | Today's source | MCP server source |
|---|---|---|
| Telegram bot token | `~/.claude/settings.json` `.env` block | Same — server reads it at startup |
| GitHub token | `gh` CLI (OAuth) | Same — server shells out to `gh auth token` |
| Anthropic auth | claude-cli's OAuth state | Same — claude-cli inherits when spawned |

No new secret storage introduced. Server has read access to `~/.claude/settings.json` (or an env-var-injected token, if exposed remotely).

**If we ever expose the server over HTTPS** (out of scope for v1): use OAuth via the MCP protocol's auth flow, scope tokens to specific tool subsets, log every tool call with the calling identity.

---

## Observability

Every tool invocation produces a structured log line:

```json
{
  "ts": "2026-05-22T10:32:19Z",
  "tool": "work_on_task",
  "request_id": "wt-2026-05-22-abc123",
  "client": "claude-code/2.1.139",
  "args": {"issue_number": 8, "repo": "acme/club-site"},
  "status": "success",
  "duration_ms": 187432,
  "exit_code": 0,
  "tokens_used": 142883,
  "artifacts": [{"type": "pr", "url": "..."}]
}
```

Logs go to `~/.agentic-skills/audit.jsonl` (append-only). The existing `routines-status` CLI gets extended to read this file in addition to the per-routine log files.

A `tools-status` command (sibling to `routines-status`) shows:
- How many invocations of each tool in the last day / week
- Average duration
- Failure rate

---

## Distribution

Three viable shapes:

**1. `npx @amarcu/agentic-skills-mcp` — npm package**
Easy to consume from any MCP client. The user runs `npx -y @amarcu/agentic-skills-mcp` once and it's available. Requires publishing to npm (free for public packages).

**2. Local Go/Node binary**
Build a single binary, drop it in `~/.local/bin/`. Like the standalone `claude` binary. No npm dependency, but no auto-update.

**3. Git-clone-and-build**
`agentic-skills/mcp/` directory in this repo. `make install-mcp` builds + symlinks the binary. Same model as our current `launchd-runtime/bin/install.sh`. **Recommended for v1** — matches our existing convention.

---

## Migration plan (phased)

If we go ahead, this is the order:

### Phase 1 — Build read-only tools (1-2 days)

Implement these tools — all pure data-shaping, no LLM:
- `repos.list`, `repos.path`
- `issues.list_open`, `issues.dependencies`
- `prs.list_open`
- `routines.status`
- `notify.send` (already pure shell — easy port)

Server is a thin wrapper over `gh`, filesystem reads, and the existing `repos.conf`.

Test: dogfood from a few interactive Claude Code sessions.

### Phase 2 — Wrap one work-intensive skill (2-3 days)

Pick `propose-tasks` (lowest risk — only creates issues, never opens PRs). Implement `propose_tasks` tool that spawns `claude-cli` per current skill prompt.

Test: invoke from claude-code and from a script. Compare output to current slash-command invocation.

### Phase 3 — Migrate remaining work-intensive skills (3-5 days)

Wrap `work-on-task`, `iterate-on-pr`, `dispatch-tasks`, `morning-triage`, `triage-repo`, `daily-summary` the same way.

Each wrapping is mechanical: tool spec + schema + spawn `_run.sh <skill>`. The skill prompt is the unit of work, not a new piece of code.

### Phase 4 — Replace launchd-runtime invocations with MCP calls (1-2 days)

Today, `_run.sh` spawns `claude-cli`. After Phase 3, `_run.sh` could *instead* connect to the MCP server over stdio and call the tool. Trade-off: adds a layer. Probably not worth it unless we get something out of having all invocations flow through the central server (uniform audit log, single concurrency control, etc.).

### Phase 5 — Optional remote exposure (not yet planned)

If we ever want phone/CI/colleague triggers, expose the server over HTTPS with proper auth. Big design step; deferred until there's a real use case.

---

## Open questions

These need answering before we'd commit:

1. **What language?** Node (npm-distributable, mature MCP SDK) vs Go (single binary, what github-mcp-server uses) vs Python (smallest LOC). The npm SDK is the most mature; Go is the most operationally clean. Recommendation: Node + TypeScript, using `@modelcontextprotocol/sdk`.

2. **Where does the binary live in our repo?** Adding a `mcp/` or `mcp-server/` directory at the repo root is natural. Or vendor under `launchd-runtime/mcp/`. Probably top-level `mcp/`.

3. **How does the server discover skill prompts?** Today they're under `agentic-skills/<name>/SKILL.md`. The server would read them at startup and surface as tool descriptions. Skill changes → server restart, or hot reload.

4. **Versioning.** The SKILL.md files have `version: x.y.z` in META. Does the MCP tool surface expose this? If so, breaking changes bump major; tooling can pin to a version.

5. **Telegram receipt path.** Today the launchd runner sends failure Telegrams. If MCP tools are invoked from a non-routine path (e.g., an interactive session), the *user is already there* — Telegram would be noise. Default behaviour: only the launchd runner sends Telegrams; MCP-direct invocations return errors structured to the caller.

---

## Honest take — do we need this yet?

This stack today has:
- One human user
- One Mac
- One MCP client of interest (Claude Code)
- 10 skills, all of which work
- 33-test regression suite catching the bug classes that mattered

The benefits MCP would unlock:
- ✅ Typed args — would catch quoting/escaping bugs
- ✅ Cross-client portability — could use skills from Cursor, IDE, etc.
- ✅ Central enforcement — could add per-tool rate limits, audit log

The costs:
- ❌ A new piece of software to maintain (the server itself)
- ❌ Two ways to invoke the same skill (slash command + MCP) → drift risk
- ❌ Migration effort: rewriting each skill's invocation path
- ❌ Tests have to cover both invocation paths

**Honest verdict:** the typed-args benefit is the most valuable, but most of the bugs we've hit (sleep states, dock disconnects, jq+emoji parsing) aren't typed-args bugs. They're system / environmental. MCP wouldn't have prevented them.

The clearest *real* use cases for our stack:
- We want a colleague to invoke our dispatch from their Mac
- We want a phone interface (web UI that triggers `propose_tasks`)
- We want to drive skills from a non-Claude IDE (Cursor specifically)

If none of those are on your roadmap, **defer**. If one of them is, **build Phase 1+2** (~3 days), see how it feels, then decide on Phase 3+.

The work isn't wasted either way — Phase 1 (typed data tools) is useful even if we never migrate the work-intensive ones, because it gives any future Claude Code session a clean way to query our system without remembering `gh` flags.

---

## What this doc is NOT

- A commitment. This is "if we did it, here's how" — not "we're doing it next week."
- A complete protocol spec. The MCP protocol is at <https://modelcontextprotocol.io>. This doc only covers our server's design *within* that protocol.
- A replacement for thinking. Reading this is ~15 min; designing the actual server is days; building it is weeks. Don't skip the design step.

## Next step (if we proceed)

1. Decide language (recommend: Node + TypeScript).
2. Build Phase 1 — read-only tools — in a feature branch.
3. Dogfood for a week.
4. Decide on Phase 2.
