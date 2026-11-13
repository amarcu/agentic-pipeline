---
domain: universal
kind: coding
version: 0.1.0
status: experimental
last-assessed: 2026-09-27
---

## Purpose
Puts a job on the machine that suits it. The pipeline ran everything on M2 while the desktop PC —
a GPU box that dual-boots Ubuntu and Windows — sat idle most of the day. video_app needs its
GPU, and GameTwo's Windows builds need its Windows side. `launchd-runtime/bin/machine` holds the
mechanics and the rules (only the desktop is ever powered; nothing reboots under a logged-in person;
Windows through a one-time firmware BootNext); this skill decides which machine a job needs and
leaves a desktop it woke switched off again.

## Model / budget
- Model: `claude-sonnet-5` — the decisions are a lookup (job kind → machine) and reading exit codes;
  the rules that matter are enforced by the script, not by judgement.
- Effort: `medium` — it chains up to four state-changing steps and must stop on the first refusal.
- Typical run: not yet measured; no job has run through it. Record it after the first real one.

`kind: coding` — it wakes, reboots and powers off a machine, so it is not `readonly`.

## Dependencies
- `launchd-runtime/bin/machine` and `launchd-runtime/machines.conf`
- Tailscale on the calling host (M2), for `status` and `list`
- The one-time setup in `references/setup.md`: SSH keys from M2, a narrow sudoers rule on Ubuntu,
  the Windows Boot Manager entry recorded in `machines.conf`, OpenSSH and Tailscale on the Windows
  side

## Known Issues
- `boot desktop windows` refuses until `DESKTOP_WINDOWS_BOOT_ENTRY` is recorded, and cannot confirm
  Windows came up until the Windows side is on the tailnet with a pipeline login.
- The wake packet is sent from the calling host's LAN. It works from M2, which shares the desktop's
  LAN; from any other network it will not reach the desktop.
- `who` sees desk and terminal sessions, not a remote-desktop session a display manager does not
  register.

## Changelog
- 2026-09-27: Initial version
