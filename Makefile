# CI runs these same targets. Each stack in STACKS owns a Makefile with the
# same target names.

STACKS := apple macos ios tvos

.DEFAULT_GOAL := help
.PHONY: help deps generate spec build run test test-unit test-integration test-ui style lint format clean deploy

help: ## Print this target list
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) \
		| sort -t: -k1,1 \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  %-18s %s\n", $$1, $$2}'

deps: ## Install every stack's tooling
	@for s in $(STACKS); do $(MAKE) --no-print-directory -C $$s deps || exit $$?; done

generate: ## Regenerate the API package and the Xcode projects
	@for s in $(STACKS); do $(MAKE) --no-print-directory -C $$s generate || exit $$?; done

spec: ## Replace openapi.yaml with the one from server release VERSION, and regenerate (make spec VERSION=0.20.0)
	@[ -n "$(VERSION)" ] || { echo "usage: make spec VERSION=<server version>" >&2; exit 64; }
	curl --fail --silent --show-error --location --output openapi.yaml.new \
		"https://raw.githubusercontent.com/legitimate-enterprises/rabbit-ears/v$(VERSION)/server/api/openapi.yaml"
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

# scripts/cut-release.sh refuses a version already released; without YES=1
# it only says what it would do.
deploy: ## Tag origin/main for release and push the tag (make deploy YES=1)
	scripts/cut-release.sh $(if $(YES),--yes)

# Each client owns its capture harness and store-specific validation.
SCREENSHOT_CLIENTS ?= ios tvos
.PHONY: screenshots
screenshots: ## Reproduce store images (SCREENSHOT_CLIENTS="ios tvos" selects clients)
	@test -n "$(strip $(SCREENSHOT_CLIENTS))" || { echo "Select at least one SCREENSHOT_CLIENTS client" >&2; exit 1; }
	@for client in $(SCREENSHOT_CLIENTS); do \
		$(MAKE) --no-print-directory -C "$$client" screenshots || exit $$?; \
	done
