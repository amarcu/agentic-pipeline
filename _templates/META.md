---
domain: universal|<a domain>|meta
kind: coding|readonly|meta
version: 1.0.0
status: active|experimental|deprecated
last-assessed: YYYY-MM-DD
---

## Purpose
One paragraph. What does this skill do and why does it exist?

## Model / budget
Which `model:` and `effort:` the skill declares in its own frontmatter, why those, and what a
typical run costs. Recording the observed cost is the point — a routing change needs a before.
- Model: `claude-opus-4-8` — because <what this skill needs the model for>
- Effort: `medium` — because <what makes a lower or higher level wrong here>
- Typical run: <duration>, <cost>, measured on <date>

## Dependencies
List tools, env vars, running services, or other skills required.
- `gh` CLI
- `TELEGRAM_BOT_TOKEN` env var
- a service the skill needs, with its address

## Known Issues
None — or describe limitations, edge cases, known broken assumptions.

## Changelog
- YYYY-MM-DD: Initial version
