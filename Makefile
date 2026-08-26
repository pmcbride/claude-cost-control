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
#   make sync       fast update: rsync repo scripts/tests/manifest, the
#                   reference docs + snippets ($(SYNC_DOCS)), dashboard/ and
#                   project-templates/, plus agents/skills/output-style into
#                   place. Preserves runtime state (version.lock, .drift,
#                   .disabled, last-run.log) and NEVER touches settings.json or
#                   CLAUDE.md (that's install's job). Runs the quick test suite
#                   against the installed copy after.
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

# Reference docs + snippets that ship INTO the installed bundle. The
# cost-control-verify skill patches several of these at the installed path
# (ADR, README, CLAUDE.snippet, session-topology, dashboard/README), so they
# have to be there. Deliberately excluded: Makefile, CLAUDE.md and .gitignore
# are repo-development files with no meaning inside $(INSTALL_DIR).
SYNC_DOCS := README.md ADR-claude-code-cost-control.md CLAUDE.snippet.md \
             HANDOFF-claude-code.md session-topology-and-controls.md \
             settings.snippet.json managed-settings.snippet.json \
             REVIEW-2026-07-16-fable.md _REVIEW-INDEX.md install.sh

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
	rsync -a --delete $(REPO_DIR)dashboard $(REPO_DIR)project-templates $(INSTALL_DIR)/
	@# Ship the source dirs inside the bundle (--delete = replaced wholesale, so
	@# the in-bundle copies can never drift from the repo). Keeps the installed
	@# tree a complete install source with a self-contained offline suite. The
	@# ACTIVE runtime copies still live under $(CLAUDE_DIR) and are synced below.
	rsync -a --delete $(REPO_DIR)agents $(REPO_DIR)skills $(REPO_DIR)output-styles $(INSTALL_DIR)/
	rsync -a $(addprefix $(REPO_DIR),$(SYNC_DOCS)) $(INSTALL_DIR)/
	install -m 0755 $(REPO_DIR)cost-control.sh $(INSTALL_DIR)/cost-control.sh
	chmod +x $(INSTALL_DIR)/hooks/*.sh $(INSTALL_DIR)/statusline/*.sh $(INSTALL_DIR)/tests/*.sh $(INSTALL_DIR)/install.sh
	rsync -a $(REPO_DIR)agents/ $(CLAUDE_DIR)/agents/
	rsync -a $(REPO_DIR)skills/ $(CLAUDE_DIR)/skills/
	rsync -a $(REPO_DIR)output-styles/terse.md $(CLAUDE_DIR)/output-styles/terse.md
	@echo "synced repo -> $(INSTALL_DIR) (docs, snippets, dashboard, templates, in-bundle agents/skills/output-styles + active copies under $(CLAUDE_DIR)); settings.json untouched"
	@$(INSTALL_DIR)/tests/test-hooks.sh >/dev/null 2>&1 \
	  && echo "post-sync hook tests: PASSED" \
	  || { echo "post-sync hook tests: FAILED — run $(INSTALL_DIR)/tests/test-hooks.sh"; exit 1; }

status:
	@$(INSTALL_DIR)/cost-control.sh status

on:
	@$(INSTALL_DIR)/cost-control.sh on

off:
	@$(INSTALL_DIR)/cost-control.sh off