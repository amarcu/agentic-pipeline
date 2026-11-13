# requirements-templates/

Manifests written for a project whose checkout was **not clean enough to commit into** on the day
they were written. A manifest belongs in the project's own repo, at `agent/requirements.conf`, so it
travels with the code and the project owns it. These are the same files, staged here until someone
can put each one in its own PR.

`check-requirements` **reads them**, as a fallback: the target checkout's own
`agent/requirements.conf` first, and `<owner>-<repo>.conf` from this directory when it has none.
Every line reporting such a repo carries `(template)`, so nobody debugs a result against a file that
was not consulted.

The fallback exists because the two repos this whole feature was built for — GameTwo and StarBonk
— are exactly the two whose manifests could not be committed. A checker that only ever read the
checkout covered neither of the gaps that motivated it, and both repos reported `no-manifest` while
their manifests sat here unread.

A template is never a shadow: the project's own file always wins, and a template is deleted the
moment its manifest lands in the project.

Installing one, from this repo's root:

```bash
mkdir -p ~/code/GameTwo/agent
cp launchd-runtime/requirements-templates/acme-GameTwo.conf \
   ~/code/GameTwo/agent/requirements.conf

mkdir -p ~/code/StarBonk/agent
cp launchd-runtime/requirements-templates/amarcu-StarBonk.conf \
   ~/code/StarBonk/agent/requirements.conf

# The same for any other repo with a staged manifest:
mkdir -p ~/code/video_app/agent
cp launchd-runtime/requirements-templates/acme-video_app.conf \
   ~/code/video_app/agent/requirements.conf

mkdir -p ~/code/strategy-game/agent
cp launchd-runtime/requirements-templates/acme-strategy-game.conf \
   ~/code/strategy-game/agent/requirements.conf
```

A template answers the requirements question only. `strategy-game` additionally
has **no root `CLAUDE.md`**, and `work-on-task` Step 1 refuses `no-claude-md`
before any requirement is checked — there is no template fallback for a
`CLAUDE.md`, so that one still needs a commit in a clean checkout before the
repo can be dispatched at all.

Then commit each in that repo, on its own branch, and delete the template. Nothing needs removing
from [`../tests/static/requirements-exceptions.txt`](../tests/static/requirements-exceptions.txt):
a repo covered by a template is already declared, so it carries no exception, and a static test
fails one that does.

The filename is `<owner>-<repo>.conf` and a static test checks that it names a repo `repos.conf` can
resolve — a template nobody can place is a template nobody will place.
