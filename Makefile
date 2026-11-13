# agentic-skills — common entry points
#
# Self-documenting. Run `make` or `make help` to list targets.
# Tab-indented (Make requires tabs, not spaces).

.DEFAULT_GOAL := help

REPO_ROOT := $(shell pwd)
RUNTIME   := $(REPO_ROOT)/launchd-runtime

# The anchor component (phone-driven sessions) is optional: its targets live
# beside it and load only where the folder exists.
-include anchor/anchor.mk
AGENTIC_HOME ?= $(or $(AGENTIC_SKILLS_HOME),$(HOME)/.agentic-skills)

# ─── Help ─────────────────────────────────────────────────────────────────

.PHONY: help
help:  ## Show this help (default).
	@printf "agentic-skills — make targets\n"
	@printf "─────────────────────────────────────────────────────────────────\n"
	@awk 'BEGIN {FS = ":.*?## "} \
	     /^[a-zA-Z0-9_%-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' \
	     $(MAKEFILE_LIST)
	@printf "\nDaily-driver shortcuts (also work as bare commands once on PATH):\n"
	@printf "  routines-status, issues-status, wake-schedule, claude-cli\n"

# ─── Tests ────────────────────────────────────────────────────────────────

.PHONY: test
test:  ## Run the full regression suite (the gate).
	@$(RUNTIME)/tests/run.sh
	@if [ -x anchor/tests/run.sh ]; then echo ""; anchor/tests/run.sh; fi

.PHONY: test-unit
test-unit:  ## Run only the runner / repos.conf unit tests.
	@$(RUNTIME)/tests/run.sh unit

.PHONY: test-static
test-static:  ## Run only cross-file consistency / BASELINE checks (<1s).
	@$(RUNTIME)/tests/run.sh static

.PHONY: test-clean
test-clean:  ## Kill any test zombies left over from interrupted runs.
	@ps aux | grep -E "mock-claude-cli|mock-telegram-server|/_run\.sh test|tests/run\.sh" \
	     | grep -v grep | awk '{print $$2}' \
	     | xargs -I{} kill -9 {} 2>/dev/null; \
	echo "  cleaned up test processes"

# ─── Install ──────────────────────────────────────────────────────────────

.PHONY: install
install:  ## Symlink scripts + bootstrap user-level LaunchAgents (no sudo).
	@bash $(RUNTIME)/bin/install.sh

.PHONY: install-dry-run
install-dry-run:  ## Show what `make install` would do, without doing it.
	@bash $(RUNTIME)/bin/install.sh --dry-run

.PHONY: install-skills
install-skills:  ## Symlink every skill dir into ~/.claude/skills (no launchd).
	@bash $(RUNTIME)/bin/install.sh --skills-only

.PHONY: install-system
install-system:  ## Install the wake-schedule LaunchDaemon (requires sudo).
	@sudo bash $(RUNTIME)/system/install.sh

# ─── Status / inspection ──────────────────────────────────────────────────

.PHONY: status
status:  ## Show last-run status for every launchd routine.
	@$(REPO_ROOT)/launchd-runtime/bin/routines-status

.PHONY: doctor
doctor:  ## Can this host do the work? Checks every ACTIVE_REPOS agent/requirements.conf.
	@$(RUNTIME)/bin/check-requirements --all --quiet

# The bare repo name only: make splits a target on `/` before matching a
# pattern rule, so `doctor-acme/GameTwo` matches nothing and dies with "No rule
# to make target". The owner comes from the roster, which is where a repo's
# full name lives. For a repo the roster does not list, call the script:
# check-requirements <owner/repo>.
.PHONY: doctor-%
doctor-%:  ## Same for one repo, with the per-requirement detail (e.g. make doctor-GameTwo).
	@repo=$$(/bin/bash -c '. "$$1" && for r in "$${REPOS_BY_PRIORITY[@]}"; do [ "$${r##*/}" = "$$2" ] && echo "$$r"; done' _ \
	    "$(or $(REPOS_CONF),$(RUNTIME)/repos.conf)" "$*" | /usr/bin/head -1); \
	if [ -z "$$repo" ]; then echo "doctor: no repo named '$*' in the roster ($(or $(REPOS_CONF),$(RUNTIME)/repos.conf))" >&2; exit 2; fi; \
	$(RUNTIME)/bin/check-requirements "$$repo"

.PHONY: issues
issues:  ## Show open issues + PRs across all tracked repos.
	@$(REPO_ROOT)/launchd-runtime/bin/issues-status

.PHONY: funnel
funnel:  ## Pipeline funnel metrics: proposal->approval->PR->merge rates per repo.
	@$(REPO_ROOT)/launchd-runtime/bin/pipeline-metrics

.PHONY: review-rollup
review-rollup:  ## Review rounds per agent PR: clean passes, rounds, findings, merges on an unpassed commit.
	@$(REPO_ROOT)/launchd-runtime/bin/review-rollup
.PHONY: trace
trace:  ## One run's tool calls as a timeline (make trace ROUTINE=dispatch-tasks-night, or RUN=<run id>; neither lists runs).
	@if [ -n "$(RUN)" ]; then \
	    $(REPO_ROOT)/launchd-runtime/bin/run-trace "$(RUN)"; \
	elif [ -n "$(ROUTINE)" ]; then \
	    $(REPO_ROOT)/launchd-runtime/bin/run-trace --last "$(ROUTINE)"; \
	else \
	    $(REPO_ROOT)/launchd-runtime/bin/run-trace --runs | /usr/bin/tail -20; \
	fi

.PHONY: cost
cost:  ## Per-routine spend over the last 7 days (runs, cost, median, p95, errors).
	@$(REPO_ROOT)/launchd-runtime/bin/routine-cost

.PHONY: cost-30
cost-30:  ## Same rollup over the last 30 days.
	@$(REPO_ROOT)/launchd-runtime/bin/routine-cost --days 30

.PHONY: issues-approved
issues-approved:  ## Only show issues with the `approved` label.
	@$(REPO_ROOT)/launchd-runtime/bin/issues-status -l approved

.PHONY: issues-proposed
issues-proposed:  ## All `proposed` issues (incl. already-approved).
	@$(REPO_ROOT)/launchd-runtime/bin/issues-status -l proposed

.PHONY: review
review:  ## Issues awaiting your approval (proposed but not yet approved).
	@$(REPO_ROOT)/launchd-runtime/bin/issues-status -l proposed -L approved --issues

.PHONY: merge
merge:  ## PRs ready for your review + merge (non-draft, open).
	@$(REPO_ROOT)/launchd-runtime/bin/issues-status --ready-only

.PHONY: pr-review
pr-review:  ## Draft PRs awaiting your review (the agent's WIP, to mark ready).
	@$(REPO_ROOT)/launchd-runtime/bin/issues-status --draft-only

# Read-only: `status` alone. Requesting a review and waiting for one are the
# loop's business (iterate-on-pr --review-rounds), not a convenience target.
REVIEW_REPO ?= amarcu/agentic-pipeline

.PHONY: review-round
review-round:  ## Copilot verdict + unanswered findings for one PR (make review-round PR=35).
	@test -n "$(PR)" || { echo "  usage: make review-round PR=<number> [REVIEW_REPO=owner/repo]"; exit 2; }
	@$(REPO_ROOT)/launchd-runtime/bin/pr-review-round status $(REVIEW_REPO) $(PR) \
	    || { echo "  not green — the findings above are unanswered, or the verdict is not 🟢"; exit 1; }

.PHONY: wake-status
wake-status:  ## Show wake-schedule pause state + queued pmset wakes.
	@$(REPO_ROOT)/launchd-runtime/bin/wake-schedule status

# ─── Smoke / debug ────────────────────────────────────────────────────────

# NOT part of `make test`: these spend real API calls.

.PHONY: smoke
smoke:  ## Headless read-only run of EVERY routine, asserting its contract (spends API budget).
	@$(RUNTIME)/tests/smoke/run-smoke.sh

.PHONY: smoke-%
smoke-%:  ## Same, for one routine (e.g. make smoke-morning-triage).
	@$(RUNTIME)/tests/smoke/run-smoke.sh $*

.PHONY: live-digest
live-digest:  ## Fire wake-status-digest for REAL now; expect a Telegram in ~60s.
	@$(AGENTIC_HOME)/routines/_run.sh wake-status-digest

.PHONY: log
log:  ## Tail today's most-recent routine log (override: make log ROUTINE=name).
	@routine_dir=$(AGENTIC_HOME)/routines/logs; \
	if [ -n "$(ROUTINE)" ]; then \
	    file=$$routine_dir/$(ROUTINE)-$$(date +%Y-%m-%d).log; \
	else \
	    file=$$(ls -t $$routine_dir/*-$$(date +%Y-%m-%d).log 2>/dev/null | head -1); \
	fi; \
	if [ -z "$$file" ] || [ ! -f "$$file" ]; then \
	    echo "  No log for today found."; \
	    ls $$routine_dir 2>/dev/null | head; \
	    exit 1; \
	fi; \
	echo "── $$file ──"; \
	tail -30 "$$file"
