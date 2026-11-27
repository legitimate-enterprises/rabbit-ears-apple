#!/usr/bin/env bash
# Builds the test bundles, then runs one directly with xctest.
#
# Not `xcodebuild test`: it needs com.apple.testmanagerd, published only in
# a logged-in GUI session, and the CI service account never logs in
# ("Failed to establish communication with the test runner"). Cost: no
# .xcresult and no coverage.
set -euo pipefail
cd "$(dirname "$0")/.."

bundle="${1:?usage: run-xctest.sh <BundleName> [<Bundle.Class>]}"
only="${2:-}"

PROJECT="RabbitEars.xcodeproj"
SCHEME="RabbitEars"
DESTINATION="platform=macOS"
CONFIGURATION="Debug"

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
    -configuration "$CONFIGURATION" build-for-testing

products="$(
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
        -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null |
        sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1
)"
[ -n "$products" ] || {
    echo "could not resolve BUILT_PRODUCTS_DIR" >&2
    exit 1
}

path="$products/$bundle.xctest"
[ -d "$path" ] || {
    echo "no test bundle at $path" >&2
    exit 1
}

# The runner keeps a backtrace of every error thrown for the life of the process.
export SWT_SWIFT_ERROR_BACKTRACING_ENABLED=0
# Only the orchestrated runner puts the products dir on the search path.
export DYLD_FRAMEWORK_PATH="$products"
export DYLD_LIBRARY_PATH="$products"
exec xcrun xctest ${only:+-XCTest "$only"} "$path"
