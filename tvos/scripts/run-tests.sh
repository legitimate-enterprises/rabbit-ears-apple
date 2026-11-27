#!/usr/bin/env bash
# Runs the unit suite on the first available Apple TV simulator, booted
# headless; Simulator.app is never opened. The bundle is compiled
# first, so a machine without a usable runtime still checks that it builds.
set -euo pipefail
cd "$(dirname "$0")/.."

# The runner keeps a backtrace of every error thrown for the life of the process.
export TEST_RUNNER_SWT_SWIFT_ERROR_BACKTRACING_ENABLED=0

XCODEBUILD=(xcodebuild -project RabbitEars.xcodeproj -scheme RabbitEars -derivedDataPath build)

"${XCODEBUILD[@]}" -destination 'generic/platform=tvOS Simulator' build-for-testing -only-testing:RabbitEarsTests

# simctl can take minutes to answer the first time, and never answers when
# CoreSimulator is older than Xcode.
udid="$(
    perl -e 'alarm shift; exec @ARGV' 300 xcrun simctl list devices available "Apple TV" |
        sed -nE 's/^ +Apple TV.*\(([0-9A-F-]{36})\).*/\1/p' | head -1
)" || true
[ -n "$udid" ] || {
    echo "no usable Apple TV simulator: test bundle compiled, tests not run" >&2
    exit 1
}

# xcodebuild gives up on a simulator still in its first boot, so it is booted
# here first; one this script boots is shut down again on exit.
if [[ "$(xcrun simctl list devices)" != *"$udid) (Booted)"* ]]; then
    trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi
perl -e 'alarm shift; exec @ARGV' 600 xcrun simctl bootstatus "$udid" -b || {
    echo "Apple TV simulator $udid did not finish booting within 600s" >&2
    exit 1
}

# A hung test fails by name. The allowance covers the slowest, the large
# action batch, on a slow runner; XCTest rounds it up to whole minutes.
"${XCODEBUILD[@]}" -destination "id=$udid" test-without-building -only-testing:RabbitEarsTests \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 300
