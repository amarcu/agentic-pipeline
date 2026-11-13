# Environment: finding the repo, running its tools, and when not to use a worktree

Read this when a path lookup fails, when a gate command reports "not found", or when you are about
to work in the user's own checkout instead of a worktree.

## Never scan for a repo

`get_repo_path` in `launchd-runtime/repos.conf` is the only way this skill locates a repo on disk.
If it returns empty, halt with the repo name and the file to add it to. Do not fall back to a
search, do not guess a path from the repo name, and do not try alternates.

Specifically, never run any of these:

- `find $HOME …`, or any `find` rooted above the repo path
- `mdfind …` or `locate …` against the user's home

On 2026-05-10 two `find $HOME` commands spawned during a `work-on-task` run outlived the
Bash tool's two-minute timeout. They kept the launchd session alive for 8.5 hours after the work had
finished, burning tokens and producing duplicate Telegram sends. The map is the contract precisely
because a miss has to be a halt rather than a search.

Searching *inside* a repo is fine when it is bounded — for example, locating the right manifest in a
monorepo:

```bash
find "$REPO_PATH" -maxdepth 4 -name package.json -not -path "*/node_modules/*" 2>/dev/null
```

## The submodule case

`amarcu/StarBonk-backend` is checked out inside `amarcu/StarBonk` as a submodule, so its `.git` is a
file, not a directory. Test the path with `test -e "$REPO_PATH/.git"`, never `test -d`.

`repos.conf` also crosses two directory names deliberately: the GitHub repo `agent-lab` lives in
`agent-lab-client`, and `agent-lab-platform` lives in `agent-lab`. Resolve every path through
`get_repo_path` rather than deriving it from the repo name.

## PATH and Homebrew

Each Bash call runs in a fresh subshell, and the user's `.zshrc` PATH is not reliably inherited.
Tools installed by Homebrew (`npm`, `node`, `pnpm`, `mvn`, `dotnet`) live in `/opt/homebrew/bin/`
and can come back as `command not found` even though they are installed.

Two fixes, in order of preference:

```bash
export PATH="/opt/homebrew/bin:$PATH" && npm run build
/opt/homebrew/bin/npm run build
```

System binaries (`git`, `cat`, `ls`, `test`) work reliably from `/usr/bin/` and `/bin/`.

A tool that is genuinely absent on this host is not a PATH problem: that is the `could-not-run` gate
outcome in Step 7, and it stops the run rather than opening an unverified PR.

## The direct-checkout exception

Step 5 always creates a worktree. The single exception is an interactive run where **all** of these
hold:

- a human is supervising this run,
- `git status --short` in the target repo returns nothing, and
- no other agent or background process is using that checkout.

A scheduled or headless run never qualifies for it — there is no human, and concurrent dispatch is
exactly what worktrees exist to survive.

If you take the exception: `cd` into the repo first, confirm the branch is the one the issue names
(`git checkout <branch> && git pull` when the tree is clean), and stop if the tree is dirty on
another branch — the user's in-flight work outranks the task. Say in the PR body that the work was
done in the user's checkout rather than a worktree.

## The branch name is a contract

Step 5 names the branch `task/issue-<N>-<slug>` at creation rather than renaming it later, because
`pipeline-metrics` and the dispatch cap both count agent PRs by matching that prefix. A branch that
picks up the name after the fact is invisible to the cap while it exists.

## Pre-existing staged work

Step 7 requires `git diff --cached --name-only | wc -l` to print `0` before you stage anything. When
it does not, the staged files were not put there by this run: leave them staged, commit only your
own paths with `git commit <path> …`, and say in the PR body that the checkout arrived with staged
work. Never unstage someone else's changes to get a clean count.
