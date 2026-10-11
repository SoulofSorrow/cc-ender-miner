# cc-ender-miner - local build, test and release helpers
#
#   make check                  lint, format check and tests
#   make build                  copy the programs into dist/
#   make release                check, build, tag v$(VERSION), push the tag
#                               and create a GitHub release with dist/ files
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

SRC_DIR  := src
DIST_DIR := dist
SOURCES  := $(SRC_DIR)/miner.lua $(SRC_DIR)/minermon.lua $(SRC_DIR)/follower.lua \
            $(SRC_DIR)/update.lua $(SRC_DIR)/install.lua

VERSION     := $(shell sed -n 's/^local VERSION = "\(.*\)"/\1/p' $(SRC_DIR)/miner.lua)
# Every program and the manifest must carry the same version
VERSIONED   := $(SRC_DIR)/minermon.lua $(SRC_DIR)/follower.lua $(SRC_DIR)/update.lua
TAG         := v$(VERSION)

.PHONY: help lint format format-check test check build clean version-check tag release

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

tag: version-check ## Create and push the git tag v$(VERSION)
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: working tree is not clean, commit first" >&2; exit 1; fi
	@if git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null; then \
		echo "error: tag $(TAG) exists already, bump VERSION first" >&2; exit 1; fi
	git tag -a "$(TAG)" -m "Release $(TAG)"
	git push $(REMOTE) "$(TAG)"

release: build tag ## Tag, push and create a GitHub release with dist/ files
	@command -v $(GH) >/dev/null || { echo "error: GitHub CLI '$(GH)' not found" >&2; exit 1; }
	@awk '/^## \[$(VERSION)\]/{flag=1; next} /^## \[/{flag=0} flag' CHANGELOG.md > $(DIST_DIR)/RELEASE_NOTES.md
	$(GH) release create "$(TAG)" $(DIST_DIR)/*.lua $(DIST_DIR)/manifest.json \
		--title "$(TAG)" --notes-file $(DIST_DIR)/RELEASE_NOTES.md
