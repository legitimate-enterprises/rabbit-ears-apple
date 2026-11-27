# xcodebuild targets need full Xcode with an iOS simulator runtime.
PROJECT      := RabbitEars.xcodeproj
SCHEME       := RabbitEars
# Products stay under build/ so clean leaves the macOS project's alone.
XCODEBUILD   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath build

.DEFAULT_GOAL := help
.PHONY: help deps generate build test test-unit style lint format clean release release-clean

help: ## Print this target list
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'

# The kit and the API package are apple/'s; their Swift is checked there.
deps: ## Install tooling and generate the Xcode project
	brew list --formula xcodegen >/dev/null 2>&1 || brew install xcodegen
	brew list --formula swiftlint >/dev/null 2>&1 || brew install swiftlint
	../apple/scripts/grdb-source.sh
	$(MAKE) --no-print-directory generate

generate: ## Regenerate the Xcode project from project.yaml
	xcodegen generate --quiet --spec project.yaml

build: ## Unsigned Release compile check for any iPhone
	$(XCODEBUILD) -destination 'generic/platform=iOS' build -configuration Release CODE_SIGNING_ALLOWED=NO

test: ## Every tier, serialized because Xcode shares build products
	$(MAKE) --no-print-directory test-unit
	$(MAKE) --no-print-directory test-ui

test-unit: ## Unit suite on the first available iPhone simulator, headless
	scripts/run-tests.sh

style: ## swift-format in checking mode
	xcrun swift-format lint --strict --recursive sources tests

format: ## swift-format in place
	xcrun swift-format format --in-place --recursive sources tests

lint: ## SwiftLint in checking mode
	swiftlint lint --strict --config .swiftlint.yaml

release: ## Sign and upload to App Store Connect (CI only, in a green run on main)
	../apple/scripts/app-store-release.sh $(PROJECT) $(SCHEME) iOS

release-clean: ## Remove the provisioning profile a release installed
	../apple/scripts/provisioning-profile.sh remove

clean: ## Remove the generated project and build products
	rm -rf build $(PROJECT)

.PHONY: test-ui screenshots

test-ui: ## Sign in, browse and play video on a disposable simulator and demo server
	$(MAKE) --no-print-directory -C ../apple server-deps
	../apple/scripts/run-simulator-ui-tests.sh ios test

screenshots: ## Export anonymous App Store screenshots from the simulator UI test
	../apple/scripts/run-simulator-ui-tests.sh ios screenshots
