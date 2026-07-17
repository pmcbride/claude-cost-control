# claude-cost-control — repo → ~/.claude sync & lifecycle
#
# The repo folder name (claude-cost-control) is irrelevant to the install:
# install.sh resolves its source from its own location and ALWAYS installs to
# $(CLAUDE_DIR)/cost-control — every hook, settings entry, and skill references
# that fixed path, never the repo path. So clone anywhere, `make install` once,
# then `make sync` after each git pull / local edit.
#
#   make install    first-time (or full re-) install: backup, settings merge,
#                   CLAUDE.md append, version.lock seed, offline test suite
#   make dry-run    show what install would do, change nothing
#   make sync       fast update: rsync repo scripts/tests/manifest + agents/
#                   skills/output-style into place. Preserves runtime state
#                   (version.lock, .drift, .disabled, last-run.log) and NEVER
#                   touches settings.json or CLAUDE.md (that's install's job).
#                   Runs the quick test suite against the installed copy after.
#   make test       full offline suite against the REPO copy (pre-commit check)
#   make status     /cost-control status from the shell
#   make on / off   toggle the guardrails from the shell
#
# NOTE on manifest/: claims.json + CHANGELOG.md are source-controlled and sync
# repo → installed. If the cost-control-verify skill updated the INSTALLED
# copies after a Claude Code update, copy them back into the repo and commit
# BEFORE the next sync, or sync will revert them:
#   cp ~/.claude/cost-control/manifest/{claims.json,CHANGELOG.md} manifest/ && git diff

CLAUDE_DIR  ?= $(HOME)/.claude
INSTALL_DIR ?= $(CLAUDE_DIR)/cost-control
REPO_DIR    := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))

.PHONY: help install dry-run sync test quick-test status on off

help:
	@sed -n '2,30p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \{0,1\}//'

install:
	cd $(REPO_DIR) && CLAUDE_CONFIG_DIR=$(CLAUDE_DIR) ./install.sh

dry-run:
	cd $(REPO_DIR) && CLAUDE_CONFIG_DIR=$(CLAUDE_DIR) ./install.sh --dry-run

test:
	cd $(REPO_DIR) && ./tests/run-all.sh

quick-test:
	cd $(REPO_DIR) && ./tests/run-all.sh --quick

sync:
	@test -d $(INSTALL_DIR) || { echo "Not installed yet — run 'make install' first."; exit 1; }
	rsync -a --delete \
	  --exclude 'version.lock' --exclude '.drift' --exclude 'last-run.log' \
	  $(REPO_DIR)hooks $(REPO_DIR)statusline $(REPO_DIR)tests $(REPO_DIR)manifest \
	  $(INSTALL_DIR)/
	install -m 0755 $(REPO_DIR)cost-control.sh $(INSTALL_DIR)/cost-control.sh
	chmod +x $(INSTALL_DIR)/hooks/*.sh $(INSTALL_DIR)/statusline/*.sh $(INSTALL_DIR)/tests/*.sh
	rsync -a $(REPO_DIR)agents/ $(CLAUDE_DIR)/agents/
	rsync -a $(REPO_DIR)skills/ $(CLAUDE_DIR)/skills/
	rsync -a $(REPO_DIR)output-styles/terse.md $(CLAUDE_DIR)/output-styles/terse.md
	@echo "synced repo -> $(INSTALL_DIR) (+ agents/skills/output-style); settings.json untouched"
	@$(INSTALL_DIR)/tests/test-hooks.sh >/dev/null 2>&1 \
	  && echo "post-sync hook tests: PASSED" \
	  || { echo "post-sync hook tests: FAILED — run $(INSTALL_DIR)/tests/test-hooks.sh"; exit 1; }

status:
	@$(INSTALL_DIR)/cost-control.sh status

on:
	@$(INSTALL_DIR)/cost-control.sh on

off:
	@$(INSTALL_DIR)/cost-control.sh off