# xcodebuild targets need full Xcode, not just Command Line Tools.
PROJECT      := RabbitEars.xcodeproj
SCHEME       := RabbitEars
DESTINATION  := platform=macOS
XCODEBUILD   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)'

# Keep the name and pattern in step with project.yaml's APP_NAME_SUFFIX.
DEV_APP_NAME    := Rabbit Ears (dev)
DEV_APP_PATTERN := Rabbit Ears \(dev\)\.app/Contents/MacOS

.DEFAULT_GOAL := help
.PHONY: help deps generate build run test test-unit test-integration test-ui style lint format release release-clean clean

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

build: ## Unsigned Release compile check
	$(XCODEBUILD) build -configuration Release CODE_SIGNING_ALLOWED=NO

# Ad-hoc signed, hardened runtime off: library validation rejects ad-hoc
# frameworks (no team ID).
run: ## Build and launch the dev-identity app
	$(XCODEBUILD) build -configuration Release ENABLE_HARDENED_RUNTIME=NO \
		CODE_SIGN_IDENTITY=- DEV_IDENTITY=YES
	-pkill -f "$(DEV_APP_PATTERN)"
	open "$$($(XCODEBUILD) -configuration Release -showBuildSettings 2>/dev/null \
		| sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)/$(DEV_APP_NAME).app"

test: test-unit test-integration ## Every tier

test-unit: ## Unit suite (no GUI session needed)
	scripts/run-xctest.sh RabbitEarsTests

# A demo server with the server's fixtures scanned, built from
# RABBIT_EARS_SERVER_SRC or the release openapi.yaml states.
test-integration: ## The sync end-to-end test against a real server
	$(MAKE) --no-print-directory -C ../apple server-deps
	python3 ../scripts/with-demo-server.py --fixtures -- \
		scripts/run-xctest.sh RabbitEarsTests RabbitEarsTests.SyncEndToEndTests

# Plays a fixture through the real app. Set TEST_RUNNER_RABBIT_EARS_UI_SERVER,
# _EMAIL and _PASSWORD to an adult on a server with fixtures scanned; without
# them, or without a logged-in GUI session, it skips.
test-ui: ## UI test against a running server (GUI session only)
	@if launchctl print "gui/$$(id -u)" >/dev/null 2>&1; then \
		$(XCODEBUILD) test -only-testing:RabbitEarsUITests; \
	else echo "test-ui: no GUI session; skipped"; fi

style: ## swift-format in checking mode
	xcrun swift-format lint --strict --recursive sources tests scripts

format: ## swift-format in place
	xcrun swift-format format --in-place --recursive sources tests scripts

lint: ## SwiftLint in checking mode
	swiftlint lint --strict --config .swiftlint.yaml

release: ## Sign and upload to App Store Connect (CI only, in a green run on main)
	../apple/scripts/app-store-release.sh $(PROJECT) $(SCHEME) macOS

release-clean: ## Remove the provisioning profile a release installed
	../apple/scripts/provisioning-profile.sh remove

clean: ## Remove the generated project and build products
	rm -rf build $(PROJECT)
	rm -rf ~/Library/Developer/Xcode/DerivedData/RabbitEars-*
