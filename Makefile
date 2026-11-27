# CI runs these same targets. Each stack in STACKS owns a Makefile with the
# same target names.

STACKS := apple macos ios tvos
COMPONENTS := macos ios tvos

.DEFAULT_GOAL := help
.PHONY: help deps generate spec build run test test-unit test-integration test-ui style lint format clean deploy changed \
	all $(COMPONENTS)

help: ## Print this target list
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) \
		| sort -t: -k1,1 \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  %-18s %s\n", $$1, $$2}'

deps: ## Install every stack's tooling
	@for s in $(STACKS); do $(MAKE) --no-print-directory -C $$s deps || exit $$?; done

generate: ## Regenerate the API package and the Xcode projects
	@for s in $(STACKS); do $(MAKE) --no-print-directory -C $$s generate || exit $$?; done

# The file's info.version is the server release the apps are built against.
spec: ## Replace openapi.yaml with the one from server release VERSION, and regenerate (make spec VERSION=0.20.0)
	@[ -n "$(VERSION)" ] || { echo "usage: make spec VERSION=<server version>" >&2; exit 64; }
	curl --fail --silent --show-error --location --output openapi.yaml.new \
		"https://raw.githubusercontent.com/legitimate-enterprises/rabbit-ears/server-v$(VERSION)/server/api/openapi.yaml"
	mv openapi.yaml.new openapi.yaml
	$(MAKE) --no-print-directory -C apple generate

build: ## Compile check in every stack
	@for s in $(STACKS); do $(MAKE) --no-print-directory -C $$s build || exit $$?; done

run: ## Build and launch the macOS app under the dev identity
	$(MAKE) --no-print-directory -C macos run

# Fastest first; exits with the last failure's status. CI runs each group
# as one job per stack instead.
TEST_GROUPS := style lint test-unit test-integration test-ui build

SEPARATOR := ========================================================================

test: ## Every gate CI enforces; every group runs even when one fails
	@status=0; \
	for group in $(TEST_GROUPS); do \
		printf '\n%s\n' "$(SEPARATOR)"; \
		printf 'TEST: %s\n' "$$group"; \
		printf '%s\n' "$(SEPARATOR)"; \
		if $(MAKE) --no-print-directory "$$group"; then \
			printf 'PASS: %s\n' "$$group"; \
		else \
			group_status=$$?; \
			status=$$group_status; \
			printf 'FAIL: %s (exit %s)\n' "$$group" "$$group_status"; \
		fi; \
	done; \
	printf '\n'; \
	if [ "$$status" -eq 0 ]; then printf 'all %s groups passed\n' "$(words $(TEST_GROUPS))"; \
	else printf 'at least one group failed; see FAIL lines above\n'; fi; \
	exit $$status

test-unit: ## Unit suites in every stack
	@for s in $(STACKS); do $(MAKE) --no-print-directory -C $$s test-unit || exit $$?; done

test-integration: ## The demo server the UI tests use, and the macOS sync end-to-end test, against a real server
	$(MAKE) --no-print-directory -C apple test-integration
	$(MAKE) --no-print-directory -C macos test-integration

test-ui: ## iPhone and Apple TV simulator UI flows against a real server
	$(MAKE) --no-print-directory -C ios test-ui
	$(MAKE) --no-print-directory -C tvos test-ui

style: ## Formatter checks in every stack
	@for s in $(STACKS); do $(MAKE) --no-print-directory -C $$s style || exit $$?; done

format: ## Formatters in place (the fix for `make style`)
	@for s in $(STACKS); do $(MAKE) --no-print-directory -C $$s format || exit $$?; done

lint: ## Linters in every stack
	@for s in $(STACKS); do $(MAKE) --no-print-directory -C $$s lint || exit $$?; done

clean: ## Remove build products, generated projects and the server's source
	@for s in $(STACKS); do $(MAKE) --no-print-directory -C $$s clean || exit $$?; done
	rm -rf build

changed: ## Which stacks differ from the last commit on main that CI passed
	@scripts/changed-stacks.sh

# Tags each named app at the version its project.yaml states on origin/main,
# once CI is green on that commit; a version already released is refused.
# With no app it lists what each one would do; `all` is every app that is
# ready, and tags only with YES=1. There is no local publish path.
deploy: ## Tag apps for release and push the tags (make deploy ios tvos, make deploy all YES=1)
	scripts/cut-release.sh $(filter all $(COMPONENTS),$(MAKECMDGOALS)) $(if $(YES),--yes)

# Pseudo-targets so `make deploy ios` parses.
all $(COMPONENTS):
	@:

# Each client owns its capture harness and store-specific validation.
SCREENSHOT_CLIENTS ?= ios tvos
.PHONY: screenshots
screenshots: ## Reproduce store images (SCREENSHOT_CLIENTS="ios tvos" selects clients)
	@test -n "$(strip $(SCREENSHOT_CLIENTS))" || { echo "Select at least one SCREENSHOT_CLIENTS client" >&2; exit 1; }
	@for client in $(SCREENSHOT_CLIENTS); do \
		$(MAKE) --no-print-directory -C "$$client" screenshots || exit $$?; \
	done
