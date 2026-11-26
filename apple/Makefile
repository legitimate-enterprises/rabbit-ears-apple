# What the macOS, iOS and Apple TV apps share: the kit, its tests, the API
# package and the release scripts. Each app compiles the kit into its own
# framework.

.DEFAULT_GOAL := help
.PHONY: help deps server-deps generate build test test-unit test-integration style lint drift format clean

help: ## Print this target list
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'

# Hand-written Swift outside sources/ and tests/.
EXTRA_SWIFT = $(shell find api tools -name '*.swift' -not -path '*/Generated/*' -not -path '*/.build/*')
SPEC        := ../openapi.yaml
GENERATOR   := swift run --quiet --package-path tools -c release swift-openapi-generator generate \
	--config api/openapi-generator-config.yaml $(SPEC)

deps: ## Install tooling and generate the API package
	brew list --formula swiftlint >/dev/null 2>&1 || brew install swiftlint
	brew list --formula shellcheck >/dev/null 2>&1 || brew install shellcheck
	$(MAKE) --no-print-directory generate

# Only test-integration and the apps' UI tests build and run a server, so
# only they install these.
server-deps: ## Install Go and ffmpeg, which build and run the server those tests use
	command -v go >/dev/null || brew install go
	command -v ffmpeg >/dev/null || brew install ffmpeg

generate: ## Regenerate api/Sources/RabbitEarsAPI/Generated from ../openapi.yaml
	@out="$$($(GENERATOR) --output-directory api/Sources/RabbitEarsAPI/Generated 2>&1)" || { echo "$$out" >&2; exit 1; }

drift: ## Fail if the generated API package is stale against the spec
	@tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	out="$$($(GENERATOR) --output-directory "$$tmp" 2>&1)" || { echo "$$out" >&2; exit 1; }; \
	diff -r -q "$$tmp" api/Sources/RabbitEarsAPI/Generated >/dev/null || \
	{ echo "api/Sources/RabbitEarsAPI/Generated is stale; run make generate" >&2; exit 1; }

build: ## Compile check of the API package
	swift build --quiet --package-path api

test: test-unit test-integration ## Every tier

# The kit's tests run in each app's suite.
test-unit: ## Release and screenshot export script tests
	scripts/test-release-scripts.sh
	scripts/test-screenshot-export.sh
	scripts/test-simulator-ui-runner.sh

test-integration: server-deps ## The demo server the UI tests use, against a real server at openapi.yaml's version
	python3 ../scripts/tests/demo-server-test.py

style: ## swift-format in checking mode
	xcrun swift-format lint --strict --recursive sources tests scripts/export-screenshots.swift $(EXTRA_SWIFT)

format: ## swift-format in place
	xcrun swift-format format --in-place --recursive sources tests scripts/export-screenshots.swift $(EXTRA_SWIFT)

lint: drift ## SwiftLint and ShellCheck in checking mode, and API package drift
	swiftlint lint --strict --config .swiftlint.yaml
	shellcheck scripts/*.sh ../scripts/*.sh

clean: ## Remove build products
	rm -rf api/.build tools/.build
