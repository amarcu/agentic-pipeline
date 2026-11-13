# Distributing this repo as a Claude Code plugin

Until now the only way to get these skills onto a machine was `make install-skills`, which
symlinks every `skills/<name>/` directory into `~/.claude/skills/`. That works when the
machine has a checkout of this repo at a known path and you are willing to run whatever is
on the branch you happen to have checked out. It does not work for a second person, and it
gives nobody a way to say "I want the version from last Tuesday".

`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` make the same repo
installable as a versioned Claude Code plugin. The manifest names the sixteen directories
under `skills/` in its `skills` array, so the plugin loader and `install.sh` read the
identical layout — see "Why an explicit array" below.

## Installing (a teammate, or a second machine)

Two commands. The first registers this repo as a marketplace; the second installs the
plugin from it.

```bash
claude plugin marketplace add amarcu/agentic-pipeline
claude plugin install agentic-skills@amarcu-skills
```

Restart Claude Code. The skills arrive **namespaced**: `/agentic-skills:work-on-task`,
not `/work-on-task`. That is the one behavioural difference from the symlink install and
it matters — see "Known gaps" below.

Confirm what landed:

```bash
claude plugin list
claude plugin details agentic-skills    # component inventory + projected token cost
```

To try a branch or a local checkout before committing to it, point the marketplace at a
directory instead of at GitHub — `claude plugin marketplace add /path/to/agentic-skills`
— or skip installation entirely and load it for one session with
`claude --plugin-dir /path/to/agentic-skills`.

## Pinning and updating

Because the marketplace entry's source is `"./"` — the plugin *is* the marketplace repo —
pinning happens at the marketplace level, and the version a consumer sees is the `version`
field in `plugin.json`.

| Intent | Command |
|---|---|
| Track `main` | `claude plugin marketplace add amarcu/agentic-pipeline` |
| Pin to a release | `claude plugin marketplace add amarcu/agentic-pipeline@agentic-skills--v1.0.0` |
| Pull newer manifests | `claude plugin marketplace update amarcu-skills` |
| Move to the new version | `claude plugin update agentic-skills@amarcu-skills` |
| Back out | `claude plugin uninstall agentic-skills` |

`claude plugin update` compares the installed version string against the resolved one and
does nothing if they match. **This is why the version bump is not optional:** push new
commits without bumping `version` in `plugin.json` and consumers keep serving the cached
copy, having been told they are up to date.

## Cutting a release

1. Bump `version` in `.claude-plugin/plugin.json` (semver).
2. `make test` — all green.
3. Commit and merge to `main` as usual.
4. `claude plugin tag --push` from the repo root. It reads the version out of
   `plugin.json`, checks that the marketplace entry agrees, and creates and pushes the
   tag `agentic-skills--v<version>`. Add `--dry-run` first to see what it would do.

Consumers on `main` then run `claude plugin marketplace update amarcu-skills` followed by
`claude plugin update agentic-skills@amarcu-skills`. Consumers who pinned re-add the
marketplace at the new tag.

## How this relates to `install.sh`

The two mechanisms are independent and both can be live on the owner's machine, but they
must not both own the same skill name.

| | `make install-skills` (symlinks) | The plugin |
|---|---|---|
| Where skills land | `~/.claude/skills/<name>` → the checkout | `~/.claude/plugins/cache/` (a copy) |
| Invoked as | `/work-on-task` | `/agentic-skills:work-on-task` |
| Tracks | whatever the checkout has right now | the installed version |
| Also installs | LaunchAgents, `_run.sh`, `claude-cli`, the `bin/` helpers | nothing — skills only |

`install.sh` remains the mechanism the **pipeline host** uses, and it has to. The plugin
ships skills and only skills; it does not carry `launchd-runtime/`, the LaunchAgents, the
`repos.conf` caps, or `~/.agentic-skills/routines/_run.sh` (itself a symlink into the
checkout). A host that runs the scheduled routines needs the checkout regardless, and the
routine prompts invoke skills by their bare `/<name>`, which is the symlink form.

So: **the pipeline host keeps the symlinks; the plugin is for everyone else.** Installing
the plugin on the pipeline host as well is safe — the namespaced copies sit alongside the
bare ones rather than replacing them — but it doubles the always-on token cost of the
skill descriptions (~1.1k tokens for the set) for no benefit there, so don't.

## Why an explicit array

The skills live under `skills/`, which the plugin loader would also find by itself. The
manifest lists the sixteen explicitly anyway, so that what a consumer installs is a
reviewed list and not whatever folder happens to hold a `SKILL.md`. `_templates/`, the
skeleton new skills are copied from, sits outside `skills/` for the same reason: it has a
`SKILL.md` and must never ship as a live seventeenth skill.

The cost of the array is that it can drift from the directories on disk.
`launchd-runtime/tests/static/test_plugin_manifest.sh` closes that: adding or removing a
skill directory without moving the manifest with it fails the static suite.

## How a skill finds the shared baseline

Every skill cites `${CLAUDE_SKILL_DIR}/BASELINE.md`, and each skill directory carries that file as
a relative symlink to the repository root's copy (`BASELINE.md -> ../BASELINE.md`); the four skills
that write code carry `BASELINE-CODING.md` the same way. One form serves both install layouts.
`${CLAUDE_SKILL_DIR}` resolves to the skill's own directory wherever the skill is installed, and the
plugin cache preserves a symlink that resolves within the plugin's own directory.

`${CLAUDE_PLUGIN_ROOT}/BASELINE.md` is the documented choice for files shared between a plugin's
skills, but Claude Code substitutes it only for plugin installs, and the pipeline host installs the
skills as symlinks in `~/.claude/skills`. `${CLAUDE_SKILL_DIR}/../BASELINE.md` fails through those
symlinks: the Read tool normalises the path as text, so it names a file that does not exist.

## Known gaps

One thing still stops the plugin from being genuinely portable. It is follow-up work,
deliberately not bundled into the packaging change.

**Namespacing.** Under the plugin, skills are `/agentic-skills:<name>`. The routine
prompts in `launchd-runtime/prompts/` invoke `/<name>`, and skills that call each other
(`Skill(name="notify")`) use the bare name too. Those references are correct for the
symlink install and would need a second form to work under the plugin.
