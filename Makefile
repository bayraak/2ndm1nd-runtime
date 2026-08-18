# 2ndm1nd (v2) sub-Makefile — included from the vault root Makefile.
# Convention: make v2-<verb>. The app binary is `2ndm1nd` (the name macOS shows
# in the Privacy & Security permission list); the ledger CLI is `brain`.

SM_DIR      := $(VAULT)/.scripts/secondmind
SM_BIN_DIR  := $(HOME)/.local/share/2ndm1nd/bin
SM_PLIST    := org.2ndm1nd.app
SM_LOG      := $(HOME)/Library/Logs/2ndm1nd/2ndm1nd.jsonl
# Stable code-signing identity. Signing with this (not ad-hoc `-`) pins the
# Designated Requirement to `identifier "org.2ndm1nd.app" and certificate leaf`,
# which is constant across rebuilds — so macOS TCC grants (Input Monitoring,
# Accessibility, Full Disk Access) survive `make v2-install`. Ad-hoc signing
# mints a new cdhash each build and silently resets those grants.
SM_SIGN_ID  ?= 2ndm1nd Code Signing

# Runtime deployed to SM_BIN_DIR — ONE list, shared by v2-install and
# v2-sync-scripts. Deliberately NOT `*.py`: graph-audit / inbox-clean /
# timeline-distill are make-only tools. Deploying them would make selftest
# byte-compare copies that v2-install never refreshes.
SM_RUNTIME_SH := brain-loop.sh await-wake.sh
SM_RUNTIME_PY := brain-prime.py day-digest.py note-lint.py co-activation.py rhythm.py \
                 register.py communities.py affect.py balance.py reconsolidation.py \
                 deltas.py coverage.py recall.py queue-builder.py selftest.py
SM_RUNTIME    := $(SM_RUNTIME_SH) $(SM_RUNTIME_PY)

.PHONY: v2-build v2-test v2-install v2-sync-scripts v2-up v2-down v2-restart v2-status v2-logs v2-doctor v2-smoke v2-signing-setup \
        v2-brain-up v2-brain-down v2-brain-restart v2-brain-status v2-brain-logs v2-brain-pause v2-brain-resume v2-brain-wake v2-brain-morph v2-links \
        proposals

v2-build: ## Build 2ndm1nd (release)
	cd $(SM_DIR) && swift build -c release

v2-timeline: ## Regenerate deep-history memory (eras + entity arcs + evidence) from git/mail
	@python3 $(SM_DIR)/timeline-distill.py

v2-graph-audit: ## Enforce the node taxonomy: set the graph filter, verify no machinery/bucket leaked in
	@python3 $(SM_DIR)/graph-audit.py

v2-lint-notes: ## Quality-lint every memory node -> Atlas/AI/Brain/quality-queue.md + trend
	@python3 $(SM_DIR)/note-lint.py

v2-selftest: ## Regression battery for all instruments (hard-fails)
	@python3 $(SM_DIR)/selftest.py

v2-queue-build: ## Mine deep evidence for entity candidates -> archive-cursor growth feed
	@python3 $(SM_DIR)/queue-builder.py

v2-coactivation: ## Hebbian PMI edge-strength -> Atlas/AI/Brain/coactivation.md (strong-unlinked + spurious)
	@python3 $(SM_DIR)/co-activation.py

v2-instruments: ## Regenerate all L1 evidence instruments (rhythm, register, communities, coactivation, lint)
	@python3 $(SM_DIR)/co-activation.py && python3 $(SM_DIR)/rhythm.py && python3 $(SM_DIR)/register.py && python3 $(SM_DIR)/communities.py && python3 $(SM_DIR)/affect.py && python3 $(SM_DIR)/balance.py && python3 $(SM_DIR)/coverage.py && python3 $(SM_DIR)/recall.py && python3 $(SM_DIR)/reconsolidation.py && python3 $(SM_DIR)/deltas.py && python3 $(SM_DIR)/note-lint.py

v2-test: ## Run SecondMindKit tests
	cd $(SM_DIR) && swift test

v2-signing-setup: ## Create/import the stable "2ndm1nd Code Signing" identity (idempotent)
	@bash $(SM_DIR)/signing/setup-signing.sh

v2-install: v2-build v2-signing-setup ## Install binaries + sign with the stable cert identity
	@mkdir -p $(SM_BIN_DIR)
	@cp $(SM_DIR)/.build/release/2ndm1nd $(SM_BIN_DIR)/2ndm1nd.new
	@cp $(SM_DIR)/.build/release/brain    $(SM_BIN_DIR)/brain.new
	@codesign -s "$(SM_SIGN_ID)" -i org.2ndm1nd.app   -f $(SM_BIN_DIR)/2ndm1nd.new
	@codesign -s "$(SM_SIGN_ID)" -i org.2ndm1nd.brain -f $(SM_BIN_DIR)/brain.new
	@mv -f $(SM_BIN_DIR)/2ndm1nd.new $(SM_BIN_DIR)/2ndm1nd
	@mv -f $(SM_BIN_DIR)/brain.new   $(SM_BIN_DIR)/brain
	@/bin/bash -n $(SM_DIR)/brain-loop.sh || { echo "✗ brain-loop.sh fails bash -n (3.2) — NOT deploying"; exit 1; }
	@cp $(addprefix $(SM_DIR)/,$(SM_RUNTIME_PY)) $(SM_BIN_DIR)/
	@# Same .new + mv -f rule as v2-sync-scripts: `make v2-restart` runs this while
	@# the brain runner is LIVE, and a bare cp rewrites the inode that running bash
	@# still holds open — it would execute garbage from the offset it was at.
	@for f in $(SM_RUNTIME_SH); do \
	    cp $(SM_DIR)/$$f $(SM_BIN_DIR)/$$f.new && chmod +x $(SM_BIN_DIR)/$$f.new \
	      && mv -f $(SM_BIN_DIR)/$$f.new $(SM_BIN_DIR)/$$f; \
	done
	@codesign -d -r- $(SM_BIN_DIR)/2ndm1nd 2>&1 | grep -q "certificate leaf" \
	  && echo "installed + cert-signed (TCC grants persist) -> $(SM_BIN_DIR)/{2ndm1nd,brain,brain-loop.sh,await-wake.sh}" \
	  || echo "⚠️  installed but NOT cert-signed — TCC grants will reset; check: make v2-signing-setup"

v2-sync-scripts: ## Deploy runtime scripts ONLY (no Swift build, no codesign). Follow with v2-brain-restart.
	@/bin/bash -n $(SM_DIR)/brain-loop.sh || { echo "✗ brain-loop.sh fails bash -n (3.2) — NOT deploying"; exit 1; }
	@mkdir -p $(SM_BIN_DIR)
	@cp $(addprefix $(SM_DIR)/,$(SM_RUNTIME_PY)) $(SM_BIN_DIR)/
	@# .new + mv -f, never a bare cp: a live `bash brain-loop.sh` holds the file
	@# open by inode and rewriting it in place corrupts the running loop.
	@for f in $(SM_RUNTIME_SH); do \
	    cp $(SM_DIR)/$$f $(SM_BIN_DIR)/$$f.new && chmod +x $(SM_BIN_DIR)/$$f.new \
	      && mv -f $(SM_BIN_DIR)/$$f.new $(SM_BIN_DIR)/$$f; \
	done
	@echo "runtime scripts deployed -> $(SM_BIN_DIR)   NEXT: make v2-brain-restart"

v2-up: ## Load + start the app LaunchAgent
	sed -e "s|__HOME__|$(HOME)|g" -e "s|__USER__|$$(id -un)|g" $(SM_DIR)/plists/$(SM_PLIST).plist > $(HOME)/Library/LaunchAgents/$(SM_PLIST).plist
	launchctl bootstrap gui/$$(id -u) $(HOME)/Library/LaunchAgents/$(SM_PLIST).plist 2>/dev/null || true
	launchctl kickstart -k gui/$$(id -u)/$(SM_PLIST)

v2-down: ## Stop + unload the app LaunchAgent
	launchctl bootout gui/$$(id -u)/$(SM_PLIST) 2>/dev/null || true

v2-restart: v2-install v2-down v2-up ## Rebuild, reinstall, restart

# --- The living brain (a KeepAlive shift-runner daemon, not a cron) ---
v2-brain-up: ## Start the living-brain shift runner (launchd org.2ndm1nd.brain, KeepAlive)
	sed -e "s|__HOME__|$(HOME)|g" -e "s|__USER__|$$(id -un)|g" $(SM_DIR)/plists/org.2ndm1nd.brain.plist > $(HOME)/Library/LaunchAgents/org.2ndm1nd.brain.plist
	@launchctl bootout gui/$$(id -u)/org.2ndm1nd.brain 2>/dev/null || true
	@# bootout is ASYNC: a fixed `sleep 3` still lost the race and left the brain
	@# DOWN with "Bootstrap failed: 5" (2026-07-30). Poll until the label is gone,
	@# then retry the bootstrap itself — never leave the runner unloaded.
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
	    launchctl print gui/$$(id -u)/org.2ndm1nd.brain >/dev/null 2>&1 || break; sleep 2; \
	done
	@for i in 1 2 3 4 5; do \
	    if launchctl bootstrap gui/$$(id -u) $(HOME)/Library/LaunchAgents/org.2ndm1nd.brain.plist 2>/dev/null; then break; fi; \
	    echo "  bootstrap retry $$i…"; sleep 3; \
	done
	@launchctl list | grep -q org.2ndm1nd.brain \
	  && echo "brain runner loaded" \
	  || { echo "✗ BRAIN IS DOWN — bootstrap failed; run: launchctl bootstrap gui/$$(id -u) ~/Library/LaunchAgents/org.2ndm1nd.brain.plist"; exit 1; }
	@echo "living brain running — one claude session per ~24h shift. logs: make v2-brain-logs"

# State dir (outside the git vault). SENTINEL uniquely marks OUR session so we
# never touch another project's `claude -p` (e.g. polymorph's).
SM_STATE := $(HOME)/Library/Application Support/2ndMind/brain-runtime
SM_SENTINEL := 2NDM1ND-BRAIN-SESSION

v2-brain-down: ## Stop the living-brain runner + its current session (ours ONLY)
	launchctl bootout gui/$$(id -u)/org.2ndm1nd.brain 2>/dev/null || true
	@pkill -f "$(SM_SENTINEL)" 2>/dev/null && echo "stopped our shift session" || true
	@echo "living brain stopped (capture continues; other projects' claude sessions untouched)"

v2-brain-restart: v2-brain-down v2-brain-up ## Restart the living-brain runner

v2-brain-status: ## Show the runner + OUR shift session (never matches other projects)
	@launchctl list | grep org.2ndm1nd.brain || echo "org.2ndm1nd.brain: not loaded"
	@pgrep -fl "brain-loop.sh" || echo "runner: not running"
	@pgrep -fl "$(SM_SENTINEL)" || echo "our shift session: idle/none"
	@tail -n 3 $(HOME)/Library/Logs/2ndm1nd/brain-loop.log 2>/dev/null || true

v2-brain-logs: ## Tail the brain runner log
	tail -n 40 -f $(HOME)/Library/Logs/2ndm1nd/brain-loop.log

v2-brain-wake: ## Nudge the living session to run a cycle now (instead of idling)
	@mkdir -p "$(SM_STATE)" && touch "$(SM_STATE)/wake" && echo "wake signal sent"

v2-brain-morph: ## Force a METAMORPHOSIS cycle (LEARNINGS compression + SELF.md rewrite) on the next pass
	@rm -f "$(SM_STATE)/morph-done-$$(date +%Y%m)"
	@mkdir -p "$(SM_STATE)" && touch "$(SM_STATE)/wake"
	@echo "METAMORPHOSIS armed + wake sent — fires on the next pass (needs today's DREAM done first)"

proposals: ## List the brain's open proposals awaiting YOUR decision (the doorbell)
	@echo "── Proposals from the brain (Atlas/Mind/proposals) ──"
	@found=0; \
	for f in $(HOME)/Projects/2ndm1nd/Atlas/Mind/proposals/*.md; do \
	    [ -f "$$f" ] || continue; \
	    st=$$(grep -i -m1 '^status:' "$$f" | sed 's/^[Ss]tatus: *//' | tr -d '\r'); \
	    ti=$$(grep -i -m1 '^title:' "$$f" | sed 's/^[Tt]itle: *//' | tr -d '"' | cut -c1-72); \
	    age=$$(( ( $$(date +%s) - $$(stat -f %m "$$f") ) / 86400 )); \
	    case "$$st" in \
	      open|Open|OPEN) found=$$((found+1)); printf "  \033[0;31m● OPEN\033[0m  %3dd  %s\n         %s\n" "$$age" "$$ti" "$$f" ;; \
	      *) printf "  \033[0;32m✓ %s\033[0m  %3dd  %s\n" "$$st" "$$age" "$$ti" ;; \
	    esac; \
	done; \
	echo; \
	if [ $$found -gt 0 ]; then \
	    echo "  $$found open. These are the brain's own diagnoses of its rails — it CANNOT apply them"; \
	    echo "  (the sandbox denies it write access to its runner, by design). Nothing happens until you decide."; \
	else echo "  Nothing open."; fi

v2-links: ## Create _local/{logs,state,bin} symlinks for VS Code visibility (gitignored)
	@mkdir -p "$(HOME)/Projects/2ndm1nd/_local"
	@ln -sfn "$(HOME)/Library/Logs/2ndm1nd"                    "$(HOME)/Projects/2ndm1nd/_local/logs"
	@ln -sfn "$(HOME)/Library/Application Support/2ndMind"     "$(HOME)/Projects/2ndm1nd/_local/state"
	@ln -sfn "$(HOME)/.local/share/2ndm1nd/bin"               "$(HOME)/Projects/2ndm1nd/_local/bin"
	@echo "_local/{logs,state,bin} -> OS locations. Browse them in VS Code (see .vscode/settings.json)."

v2-brain-pause: ## Pause the brain between shifts (capture keeps running)
	@mkdir -p "$(SM_STATE)" && touch "$(SM_STATE)/paused" && echo "brain paused (current shift finishes, no new one starts)"

v2-brain-resume: ## Resume the brain
	@rm -f "$(SM_STATE)/paused" && echo "brain resumed"

v2-status: ## Show app + ledger status
	@launchctl list | grep $(SM_PLIST) || echo "$(SM_PLIST): not loaded"
	@pgrep -fl "$(SM_BIN_DIR)/2ndm1nd" || echo "2ndm1nd: not running"
	@ls -lh "$(HOME)/Library/Application Support/2ndMind/brain.db" 2>/dev/null || echo "ledger: not created yet"

v2-logs: ## Tail the app log
	tail -n 40 -f $(SM_LOG)

v2-smoke: ## Live ClaudeRunner smokes (text + tools)
	$(SM_BIN_DIR)/2ndm1nd claude-smoke
	$(SM_BIN_DIR)/2ndm1nd claude-tools-smoke

v2-doctor: ## Health checks
	@echo "=== 2NDM1ND (v2) ==="
	@[ -x $(SM_BIN_DIR)/2ndm1nd ] && echo "✓ 2ndm1nd binary" || echo "✗ 2ndm1nd missing (make v2-install)"
	@[ -x $(SM_BIN_DIR)/brain ] && echo "✓ brain binary" || echo "✗ brain missing"
	@pgrep -q -f "$(SM_BIN_DIR)/2ndm1nd$$" && echo "✓ app running" || echo "! app not running (make v2-up)"
	@tail -5 $(SM_LOG) 2>/dev/null | grep -q '"level":"error"' && echo "! recent errors in log" || echo "✓ no recent log errors"
