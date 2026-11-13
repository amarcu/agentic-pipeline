---
name: use-machine
description: Puts one job on the right machine — M2 by default, the desktop's Ubuntu side for GPU work, its Windows side for Windows builds — waking and booting the desktop when the job needs it and powering it off afterwards only if this run woke it. Use when a task needs a GPU, a Windows build, or any machine other than the pipeline host.
argument-hint: "<gpu|windows-build|default> -- <command…> [--dry-run]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/machine:*), Read
model: claude-sonnet-5
effort: medium
---

# Use Machine

You place one job on the machine that suits it and hand the machine back as you found it. You produce one `MACHINE:` line per action and the job's own output. You never power, wake or reboot anything but the desktop, never take a machine from someone using it, and never change how the desktop boots by default.

## Limits

- The roster, hosts and the desktop's wake and boot settings live in `launchd-runtime/machines.conf`; the rules the script enforces are in the header of `launchd-runtime/bin/machine`. Neither is restated here.
- One job per invocation, one machine per job.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its five principles throughout.

## Arguments

`$ARGUMENTS`

- `gpu` — CUDA work: training, inference, the video_app pipeline. Runs on `desktop-ubuntu`.
- `windows-build` — a Windows player or editor build (GameTwo). Runs on `desktop-windows`.
- `default` — anything else. Runs here, on the pipeline host (`machine run local`); nothing is woken.
- `-- <command…>` — the command to run there, as one argument list.
- `--dry-run` — every check, and what would happen; no packet, reboot or command.

## Contract

- **Refuses when**: the script refuses (exit 3) — someone is logged in, the machine is not on the tailnet, the Windows boot entry is unset, or the pipeline has no login there. Print its line and stop; never retry around it.
- **Writes**: a wake packet, one BootNext and reboot, the job's command, and a power-off — each only when the job needs it.
- **Halts**: on a timeout (exit 4) or failure (exit 1). A desktop that was powered by this run is released before halting.
- **Budget**: one wake, one command, and at most two reboots: one into the job's OS and one back to Ubuntu (Step 4).

## Steps

### Step 1 — Note the state before touching anything

```bash
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/machine status desktop-ubuntu
```

Record whether the desktop was already up on Ubuntu. That decides Step 4: a machine that was already on is handed back on, and on Ubuntu.

→ verify: one `MACHINE: status` line was printed.

### Step 2 — Bring the target up

- `gpu` → `machine boot desktop ubuntu`
- `windows-build` → `machine boot desktop windows`
- `default` → nothing.

Add `--dry-run` if it was passed.

→ verify: the line says `result=ok`. Any other result follows the Contract.

### Step 3 — Run the job

```bash
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/machine run <desktop-ubuntu|desktop-windows|local> -- <command…>
```

→ verify: the command's exit code is reported with its output.

### Step 4 — Hand it back

- Step 1 found the desktop down → `machine release <the side this job used>`.
- Step 1 found Ubuntu up and the job used Windows → `machine boot desktop ubuntu`.
- Otherwise leave it as it is.

A refusal here means someone sat down while the job ran; leave the machine as it is and say so.

→ verify: a `MACHINE: release` or `MACHINE: boot` line, or the stated reason none was sent.

## Output contract

```
MACHINE: <status|wake|boot|release> <name> result=<ok|refused|timeout|failed> <detail>
USED: <machine> job=<gpu|windows-build|default> exit=<n> handed-back=<released|ubuntu|as-found|refused>
```

## Hard rules

- Never power the Macs, the laptop or the Pi; `bin/machine` refuses, and so do you.
- Never reboot or release a machine someone is logged in to.
- Never wake the desktop for a job `default` can run.
- Never change the default boot order or use GRUB; Windows is BootNext only.
- A denied command is a stop signal — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/references/setup.md` — the one-time setup each machine needs before this works. Read it when a line says a machine is not set up.
