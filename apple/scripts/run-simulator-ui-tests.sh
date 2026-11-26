#!/usr/bin/env bash
# A fresh simulator and fixture server prevent UI tests from changing personal sessions or media state.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
platform="${1:-}"
mode="${2:-test}"
case "$platform/$mode" in ios/test|ios/screenshots|tvos/test|tvos/screenshots) ;; *)
    echo "usage: $0 ios|tvos test|screenshots" >&2; exit 64 ;;
esac
for tool in xcrun xcodebuild xcodegen make jq python3 go ffmpeg ffprobe; do
    command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done
case "$platform" in
    ios)
        runtime_platform=iOS
        device=com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro
        output="$root/assets/apple-app-store/screenshots-iphone"
        ;;
    tvos)
        runtime_platform=tvOS
        device=com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K
        output="$root/assets/apple-app-store/screenshots-apple-tv"
        ;;
esac
runtime="$(xcrun simctl list runtimes --json | jq -r --arg platform "$runtime_platform" --arg device "$device" '
    [.runtimes[] | select(.isAvailable and .platform == $platform)
    | select((.version | split(".")[0] | tonumber) >= 27)
    | select(any(.supportedDeviceTypes[]; .identifier == $device))]
    | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty')"
if [ -z "$runtime" ]; then
    echo "Install a compatible $runtime_platform 27+ simulator runtime in Xcode before running UI tests." >&2
    exit 1
fi
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="$root/$platform/build/ui-tests/$run_id"
mkdir -p "$run_dir"
simulator=""
cleanup() {
    if [ -n "$simulator" ]; then
        xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
        xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_logged() {
    local log="$1"
    shift
    if "$@" > "$log" 2>&1; then return 0; else
        local code=$?
        tail -300 "$log" >&2
        echo "Full log: $log" >&2
        return "$code"
    fi
}
echo "Building $platform UI tests; logs: $run_dir"
make --no-print-directory -C "$root/$platform" generate
build=(xcodebuild -project "$root/$platform/RabbitEars.xcodeproj" -scheme RabbitEars
    -configuration Debug -derivedDataPath "$root/$platform/build"
    -only-testing:RabbitEarsUITests -parallel-testing-enabled NO)
run_logged "$run_dir/build.log" "${build[@]}" -destination "generic/platform=$runtime_platform Simulator" build-for-testing
simulator="$(xcrun simctl create "Rabbit Ears UI $platform $run_id" "$device" "$runtime")"
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b > "$run_dir/boot.log" 2>&1
if [ "$platform" = ios ]; then
    xcrun simctl status_bar "$simulator" override --time '9:41' --dataNetwork wifi \
        --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
fi
export TEST_RUNNER_RABBIT_EARS_UI_SCREENSHOTS=0
if [ "$mode" = screenshots ]; then export TEST_RUNNER_RABBIT_EARS_UI_SCREENSHOTS=1; fi
echo "Running $platform critical path with an isolated demo server"
run_logged "$run_dir/tests.log" "$root/scripts/with-demo-server.py" -- \
    "${build[@]}" -destination "id=$simulator" -resultBundlePath "$run_dir/results.xcresult" \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 180 \
    -maximum-test-execution-time-allowance 300 test-without-building
xcrun xcresulttool get test-results summary --path "$run_dir/results.xcresult" > "$run_dir/summary.json"
if ! jq -e '.totalTestCount > 0 and .passedTests == .totalTestCount and .failedTests == 0
    and .skippedTests == 0 and .expectedFailures == 0' "$run_dir/summary.json" >/dev/null; then
    echo "UI suite did not run every test successfully: $run_dir/summary.json" >&2
    exit 1
fi
if [ "$mode" = screenshots ]; then
    xcrun xcresulttool export attachments --path "$run_dir/results.xcresult" --output-path "$run_dir/attachments"
    xcrun swift "$here/export-screenshots.swift" "$platform" "$run_dir/attachments" "$output"
fi
echo "$platform UI tests passed; results: $run_dir/results.xcresult"
