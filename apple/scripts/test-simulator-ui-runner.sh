#!/usr/bin/env bash
# A skipped suite or failed command must fail the gate and clean up only its own simulator.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
export UI_RUNNER_TEST_ROOT="$tmp"
export UI_RUNNER_TEST_CASE=passed
cat > "$tmp/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    'simctl list runtimes --json')
        if [ "$UI_RUNNER_TEST_CASE" = no-runtime ]; then echo '{"runtimes":[]}'; exit 0; fi
        printf '{"runtimes":[{"isAvailable":true,"platform":"iOS","version":"27.0","identifier":"test-runtime","supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"}]}]}' ;;
    'simctl create '*) echo own-simulator ;;
    'simctl shutdown own-simulator'|'simctl delete own-simulator') echo "$*" >> "$UI_RUNNER_TEST_ROOT/cleanup" ;;
    'simctl boot own-simulator'|'simctl bootstatus own-simulator -b'|'simctl status_bar own-simulator override '*) ;;
    'xcresulttool get test-results summary '*)
        case "$UI_RUNNER_TEST_CASE" in
            passed) echo '{"totalTestCount":1,"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0}' ;;
            skipped) echo '{"totalTestCount":1,"passedTests":0,"failedTests":0,"skippedTests":1,"expectedFailures":0}' ;;
            empty) echo '{"totalTestCount":0,"passedTests":0,"failedTests":0,"skippedTests":0,"expectedFailures":0}' ;;
            failed) echo '{"totalTestCount":1,"passedTests":0,"failedTests":1,"skippedTests":0,"expectedFailures":0}' ;;
        esac ;;
    *) echo "unexpected xcrun call: $*" >&2; exit 99 ;;
esac
FAKE
cat > "$tmp/bin/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    *build-for-testing*) test "$UI_RUNNER_TEST_CASE" != build-failed ;;
    *test-without-building*) test "$UI_RUNNER_TEST_CASE" != command-failed ;;
    *) echo 'unexpected xcodebuild call' >&2; exit 99 ;;
esac
FAKE
cat > "$tmp/bin/python3" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" = */scripts/with-demo-server.py && "$2" = -- ]]
shift 2
exec "$@"
FAKE
for tool in xcodegen go ffmpeg ffprobe; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/$tool"; done
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
for scenario in passed skipped empty failed command-failed build-failed no-runtime; do
    export UI_RUNNER_TEST_CASE="$scenario"
    rm -f "$tmp/cleanup"
    code=0
    "$here/run-simulator-ui-tests.sh" ios test > "$tmp/output" 2>&1 || code=$?
    if [ "$scenario" = passed ]; then
        test "$code" -eq 0 || { cat "$tmp/output" >&2; exit 1; }
    else
        test "$code" -ne 0 || { echo "accepted $scenario suite" >&2; exit 1; }
    fi
    if [ "$scenario" = build-failed ] || [ "$scenario" = no-runtime ]; then
        test ! -e "$tmp/cleanup"
    else
        printf 'simctl shutdown own-simulator\nsimctl delete own-simulator\n' > "$tmp/expected"
        diff -u "$tmp/expected" "$tmp/cleanup"
    fi
done
echo 'simulator UI runner tests passed'
