#!/usr/bin/env bash
# Runs the unit suite on the first available Apple TV simulator. xcodebuild
# boots it headless; Simulator.app is never opened. The bundle is compiled
# first, so a machine without a usable runtime still checks that it builds.
set -euo pipefail
cd "$(dirname "$0")/.."

XCODEBUILD=(xcodebuild -project RabbitEars.xcodeproj -scheme RabbitEars -derivedDataPath build)

"${XCODEBUILD[@]}" -destination 'generic/platform=tvOS Simulator' build-for-testing -only-testing:RabbitEarsTests

# simctl can take minutes to answer the first time, and never answers when
# CoreSimulator is older than Xcode.
udid="$(
    timeout 300 xcrun simctl list devices available "Apple TV" 2>/dev/null |
        sed -nE 's/^ +Apple TV.*\(([0-9A-F-]{36})\).*/\1/p' | head -1
)" || true
[ -n "$udid" ] || {
    echo "no usable Apple TV simulator: test bundle compiled, tests not run" >&2
    exit 1
}

exec "${XCODEBUILD[@]}" -destination "id=$udid" test-without-building -only-testing:RabbitEarsTests
