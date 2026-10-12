# cc-ender-miner - local build, test and release helpers
#
#   make check                  lint, format check and tests
#   make build                  copy the programs into dist/
#   make release                check, build, push the branch, tag v$(VERSION),
#                               push the tag and create a GitHub release
#
# The GitHub release is created with the GitHub CLI when it is logged in or
# GH_TOKEN / GITHUB_TOKEN is set. Otherwise the release page opens in the
# browser with tag, title and notes filled in; only the files from dist/ have
# to be dropped in. RELEASE_MODE=gh or RELEASE_MODE=browser forces one way.
#
# The version is read from src/miner.lua and must match the other programs
# and manifest.json, and have an entry in CHANGELOG.md. The auto updater on
# the turtles reads manifest.json from the main branch, so a release is
# picked up as soon as it is pushed there.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

LUA      ?= lua
LUACHECK ?= luacheck
STYLUA   ?= stylua
GH       ?= gh
REMOTE   ?= origin
BRANCH   ?= main
# auto, gh or browser, see the header
RELEASE_MODE ?= auto

SRC_DIR  := src
DIST_DIR := dist
SOURCES  := $(SRC_DIR)/miner.lua $(SRC_DIR)/minermon.lua $(SRC_DIR)/follower.lua \
            $(SRC_DIR)/station.lua $(SRC_DIR)/update.lua $(SRC_DIR)/install.lua

VERSION     := $(shell sed -n 's/^local VERSION = "\(.*\)"/\1/p' $(SRC_DIR)/miner.lua)
# Every program and the manifest must carry the same version
VERSIONED   := $(SRC_DIR)/minermon.lua $(SRC_DIR)/follower.lua $(SRC_DIR)/station.lua \
               $(SRC_DIR)/update.lua
TAG         := v$(VERSION)
NOTES       := $(DIST_DIR)/RELEASE_NOTES.md
# GitHub limits the length of a URL, longer notes are not put into the link
MAX_URL_LEN := 7000

# Sets $$mode to gh or browser, depending on RELEASE_MODE and the gh login
define resolve_mode
mode="$(RELEASE_MODE)"; \
if [ "$$mode" = auto ]; then \
	if command -v $(GH) >/dev/null && $(GH) auth status --hostname github.com >/dev/null 2>&1; then \
		mode=gh; else mode=browser; fi; \
fi; \
case "$$mode" in \
	gh) command -v $(GH) >/dev/null || { echo "error: GitHub CLI '$(GH)' not found" >&2; exit 1; }; \
	    $(GH) auth status --hostname github.com >/dev/null 2>&1 || { \
		echo "error: RELEASE_MODE=gh but '$(GH)' is not logged in and no GH_TOKEN is set" >&2; exit 1; } ;; \
	browser) ;; \
	*) echo "error: RELEASE_MODE must be auto, gh or browser, not '$$mode'" >&2; exit 1 ;; \
esac
endef

.PHONY: help lint format format-check test check build clean version-check release-check tag \
        publish release

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "} {printf "  %-14s %s\n", $$1, $$2}'

lint: ## Run luacheck
	$(LUACHECK) $(SRC_DIR) tests

format: ## Format all Lua files with StyLua
	$(STYLUA) $(SRC_DIR) tests

format-check: ## Verify formatting without changing files
	$(STYLUA) --check $(SRC_DIR) tests

test: ## Run the offline simulation tests
	$(LUA) tests/run.lua

check: lint format-check test ## Lint, format check and tests

build: check ## Copy the programs into dist/
	@rm -rf $(DIST_DIR)
	@mkdir -p $(DIST_DIR)
	cp $(SOURCES) manifest.json $(DIST_DIR)/
	@echo "Built $(TAG) into $(DIST_DIR)/"

clean: ## Remove build output
	rm -rf $(DIST_DIR)

version-check: ## Verify version numbers and changelog entry
	@if [ -z "$(VERSION)" ]; then echo "error: no VERSION found in $(SRC_DIR)/miner.lua" >&2; exit 1; fi
	@for f in $(VERSIONED); do \
		v=$$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' $$f); \
		if [ "$$v" != "$(VERSION)" ]; then \
			echo "error: miner.lua is $(VERSION) but $$f is $$v" >&2; exit 1; fi; \
	done
	@if ! grep -q '"version": "$(VERSION)"' manifest.json; then \
		echo "error: manifest.json does not list version $(VERSION)" >&2; exit 1; fi
	@if ! grep -q "^## \[$(VERSION)\]" CHANGELOG.md; then \
		echo "error: CHANGELOG.md has no entry for $(VERSION)" >&2; exit 1; fi
	@echo "Version $(VERSION) OK"

release-check: ## Show how the GitHub release will be created
	@$(resolve_mode); \
	if [ "$$mode" = gh ]; then echo "Release via GitHub CLI"; \
	else echo "Release via browser: GitHub CLI not logged in and no GH_TOKEN set"; fi

tag: version-check ## Push the branch, create and push the git tag v$(VERSION)
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: working tree is not clean, commit first" >&2; exit 1; fi
	@if [ "$$(git branch --show-current)" != "$(BRANCH)" ]; then \
		echo "error: releases are made from $(BRANCH), not from '$$(git branch --show-current)'" >&2; exit 1; fi
	@if git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null; then \
		echo "error: tag $(TAG) exists already, bump VERSION first" >&2; exit 1; fi
	git push $(REMOTE) "$(BRANCH)"
	git tag -a "$(TAG)" -m "Release $(TAG)"
	git push $(REMOTE) "$(TAG)"

publish: ## Create the GitHub release for the pushed tag v$(VERSION)
	@if [ ! -f "$(DIST_DIR)/manifest.json" ]; then \
		echo "error: $(DIST_DIR)/ is empty, run 'make build' first" >&2; exit 1; fi
	@awk '/^## \[$(VERSION)\]/{flag=1; next} /^## \[/{flag=0} flag' CHANGELOG.md > $(NOTES)
	@$(resolve_mode); \
	if [ "$$mode" = gh ]; then \
		$(GH) release create "$(TAG)" $(DIST_DIR)/*.lua $(DIST_DIR)/manifest.json \
			--title "$(TAG)" --notes-file $(NOTES); \
		exit 0; \
	fi; \
	remote=$$(git remote get-url $(REMOTE)); \
	repo=$$(printf '%s' "$$remote" | sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$$##'); \
	if [ "$$repo" = "$$remote" ] || [[ "$$repo" != */* ]]; then \
		echo "error: remote '$(REMOTE)' is not a GitHub repository: $$remote" >&2; exit 1; fi; \
	urlencode() { $(LUA) -e 'io.write((io.read("*a"):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end)))'; }; \
	url="https://github.com/$$repo/releases/new?tag=$$(printf '%s' "$(TAG)" | urlencode)&title=$$(printf '%s' "$(TAG)" | urlencode)"; \
	body=$$(urlencode < $(NOTES)); \
	if [ $$(( $${#url} + $${#body} )) -le $(MAX_URL_LEN) ]; then \
		url="$$url&body=$$body"; notes_hint="filled in"; \
	else \
		notes_hint="too long for the link, paste them from $(NOTES)"; \
		if command -v pbcopy >/dev/null; then pbcopy < $(NOTES); notes_hint="$$notes_hint (copied to the clipboard)"; fi; \
	fi; \
	echo ""; \
	echo "Tag $(TAG) is pushed. Finish the release in the browser:"; \
	echo "  1. Check the notes ($$notes_hint)."; \
	echo "  2. Drop these files into the release:"; \
	for f in $(DIST_DIR)/*.lua $(DIST_DIR)/manifest.json; do echo "       $$f"; done; \
	echo "  3. Click 'Publish release'."; \
	echo ""; \
	echo "$$url"; \
	if command -v open >/dev/null; then open "$$url"; open "$(DIST_DIR)"; \
	elif command -v xdg-open >/dev/null; then xdg-open "$$url" >/dev/null 2>&1 || true; fi

# release-check runs before tag, so a bad RELEASE_MODE stops before anything is pushed
release: build release-check tag publish ## Check, build, tag, push and create the GitHub release
