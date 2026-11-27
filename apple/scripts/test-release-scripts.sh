#!/usr/bin/env bash
# Exercises the release scripts with no store, certificate or CI:
# require-env.sh, provisioning-profile.sh on a profile signed here with a
# throwaway key, and signing-keychain.sh and app-store-release.sh against
# fakes of security, xcodebuild and xcrun.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# expect <status> <command>...: runs it, output in $tmp/out.
expect() {
    local want="$1" got=0 cmd
    shift
    cmd="$*"
    "$@" > "$tmp/out" 2>&1 || got=$?
    [ "$got" -eq "$want" ] || fail "${cmd:0:120}... exited $got, want $want: $(cat "$tmp/out")"
}

said() { grep -q -- "$1" "$tmp/out" || fail "output lacks '$1': $(cat "$tmp/out")"; }
unsaid() { ! grep -q -- "$1" "$tmp/out" || fail "output has '$1': $(cat "$tmp/out")"; }

# require-env.sh: empty counts as missing, and every missing name is named.
expect 0 env TEST_A=1 TEST_B=2 "$here/require-env.sh" TEST_A TEST_B
expect 1 env -u TEST_C TEST_A=1 TEST_B= "$here/require-env.sh" TEST_A TEST_B TEST_C
said "TEST_B is not set"
said "TEST_C is not set"
unsaid "TEST_A is not set"
expect 64 "$here/require-env.sh"

# A profile as Apple ships one, a property list inside CMS signed data.
# profile_with_uuid <uuid> [platform]
uuid=0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0
profile_with_uuid() {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Name</key><string>Test</string><key>Platform</key><array><string>%s</string></array><key>UUID</key><string>%s</string></dict></plist>\n' "${2:-iOS}" "$1" > "$tmp/profile.plist"
    /usr/bin/openssl smime -sign -nodetach -binary -in "$tmp/profile.plist" \
        -signer "$tmp/cert.pem" -inkey "$tmp/key.pem" -outform DER -out "$tmp/profile.mobileprovision"
    base64 -i "$tmp/profile.mobileprovision"
}
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=throwaway -days 1 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
good="$(profile_with_uuid "$uuid")"
home="$tmp/home"
installed="$home/Library/Developer/Xcode/UserData/Provisioning Profiles/$uuid.mobileprovision"

# provisioning-profile.sh: install prints the UUID alone and remove undoes it.
expect 0 env HOME="$home" PROVISIONING_PROFILE="$good" "$here/provisioning-profile.sh" install
[ "$(cat "$tmp/out")" = "$uuid" ] || fail "install printed '$(cat "$tmp/out")', want $uuid"
[ -f "$installed" ] || fail "install left no $installed"
expect 0 env HOME="$home" PROVISIONING_PROFILE="$good" "$here/provisioning-profile.sh" remove
[ ! -e "$installed" ] || fail "remove left $installed"
expect 0 env -u PROVISIONING_PROFILE HOME="$home" "$here/provisioning-profile.sh" remove
# Xcode looks for a Mac profile under its own extension.
mac="$(profile_with_uuid "$uuid" OSX)"
mac_installed="${installed%.mobileprovision}.provisionprofile"
expect 0 env HOME="$home" PROVISIONING_PROFILE="$mac" "$here/provisioning-profile.sh" install
[ -f "$mac_installed" ] || fail "a Mac profile's install left no $mac_installed"
[ ! -e "$installed" ] || fail "a Mac profile's install left $installed"
expect 0 env HOME="$home" PROVISIONING_PROFILE="$mac" "$here/provisioning-profile.sh" remove
[ ! -e "$mac_installed" ] || fail "remove left $mac_installed"
expect 1 env -u PROVISIONING_PROFILE HOME="$home" "$here/provisioning-profile.sh" install
said "PROVISIONING_PROFILE is not set"
expect 64 env HOME="$home" PROVISIONING_PROFILE="$good" "$here/provisioning-profile.sh" list
expect 1 env HOME="$home" PROVISIONING_PROFILE="$(printf 'not a profile' | base64)" "$here/provisioning-profile.sh" install
said "not a base64-encoded .mobileprovision"
# A UUID that is a path would let remove delete outside the folder.
expect 1 env HOME="$home" PROVISIONING_PROFILE="$(profile_with_uuid ../../escape)" "$here/provisioning-profile.sh" install
said "is not a UUID"
[ -z "$(find "$home" -type f 2>/dev/null)" ] || fail "a refused install wrote $(find "$home" -type f)"

# The scripts under test find these first on PATH. No case may reach the
# real security: where CI is set it would replace the keychain search list.
fakes="$tmp/fakes"
log="$tmp/log"
jobtmp="$tmp/jobtmp"
mkdir -p "$fakes" "$log" "$jobtmp"
cat > "$fakes/security" << 'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG/security.log"
if [ "$1" = import ]; then
    [ "$(cat "$2")" = p12 ] || exit 95
    case "$2" in "$TMPDIR"/*) ;; *) exit 94 ;; esac
fi
[ "$1" != find-identity ] || printf '  %s\n' "${FAKE_IDENTITIES:-}"
FAKE
cat > "$fakes/xcodebuild" << 'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG/xcodebuild.log"
! env | grep -qE '^(APPLE_API_KEY|PROVISIONING_PROFILE|[A-Z_]+_P12|[A-Z_]+_PASSWORD)=' || exit 96
[ -z "${FAKE_ARCHIVE_FAIL:-}" ] || exit 65
args=("$@")
for ((i = 0; i < $#; i++)); do
    case "${args[i]}" in
        -archivePath) archive="${args[i + 1]}" ;;
        -exportPath) out="${args[i + 1]}" ;;
        -exportOptionsPlist) options="${args[i + 1]}" ;;
    esac
done
if [ -n "${out:-}" ]; then
    cp "$options" "$FAKE_LOG/options.plist"
    command -v rsync > "$FAKE_LOG/rsync"
    mkdir -p "$out"
    : > "$out/App.$FAKE_PRODUCT"
else
    mkdir -p "$archive"
    plutil -create xml1 "$archive/Info.plist"
    plutil -insert ApplicationProperties -json '{"CFBundleIdentifier": "test.bundle"}' "$archive/Info.plist"
fi
FAKE
cat > "$fakes/xcrun" << 'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG/xcrun.log"
key="$API_PRIVATE_KEYS_DIR/AuthKey_I.p8"
[ "$(cat "$key")" = K ] || exit 97
echo "$key" > "$FAKE_LOG/key"
FAKE
# Stands in for Homebrew's rsync, ahead of the system's on PATH.
cp "$fakes/security" "$fakes/rsync"
chmod +x "$fakes"/*
faked=(PATH="$fakes:$PATH" FAKE_LOG="$log" TMPDIR="$jobtmp" CI=true)
# logged <name> <text>: the fake's log has a line holding the text.
logged() { grep -qF -- "$2" "$log/$1.log" 2>/dev/null || fail "$1 was not called with '$2': $(cat "$log/$1.log" 2>/dev/null)"; }
emptied() { [ -z "$(find "$jobtmp" -mindepth 1 2>/dev/null)" ] || fail "$1 left $(find "$jobtmp" -mindepth 1) in the temporary folder"; }

# signing-keychain.sh refuses outside CI and on a missing variable, before
# it makes a keychain or changes the search list; a Mac release also needs
# the installer identity.
p12="$(printf p12 | base64)"
distribution=(APPLE_DISTRIBUTION_CERT_P12="$p12" APPLE_DISTRIBUTION_CERT_PASSWORD=W)
installer=(MAC_INSTALLER_CERT_P12="$p12" MAC_INSTALLER_CERT_PASSWORD=X)
expect 1 env "${faked[@]}" CI= "${distribution[@]}" "$here/signing-keychain.sh" iOS
said "CI only"
expect 1 env -u APPLE_DISTRIBUTION_CERT_PASSWORD "${faked[@]}" APPLE_DISTRIBUTION_CERT_P12="$p12" "$here/signing-keychain.sh" iOS
said "APPLE_DISTRIBUTION_CERT_PASSWORD is not set"
expect 1 env -u MAC_INSTALLER_CERT_P12 -u MAC_INSTALLER_CERT_PASSWORD "${faked[@]}" "${distribution[@]}" "$here/signing-keychain.sh" macOS
said "MAC_INSTALLER_CERT_P12 is not set"
expect 64 env "${faked[@]}" "$here/signing-keychain.sh" watchOS
[ ! -e "$log/security.log" ] || fail "a refused import called security: $(cat "$log/security.log")"
# It imports each identity from the job's temporary folder, leaves no .p12
# there, and names an identity the keychain does not then hold.
expect 0 env "${faked[@]}" FAKE_IDENTITIES='1) AB "Apple Distribution: T (X)"' "${distribution[@]}" "$here/signing-keychain.sh" iOS
logged security "create-keychain"
logged security "list-keychains -d user -s build.keychain login.keychain"
[ "$(grep -c '^import ' "$log/security.log")" -eq 1 ] || fail "an iOS import imported $(grep -c '^import ' "$log/security.log") identities"
emptied "an import"
rm "$log/security.log"
expect 1 env "${faked[@]}" FAKE_IDENTITIES='1) AB "Apple Distribution: T (X)"' "${distribution[@]}" "${installer[@]}" "$here/signing-keychain.sh" macOS
said "no valid 3rd Party Mac Developer Installer identity"
[ "$(grep -c '^import ' "$log/security.log")" -eq 2 ] || fail "a Mac import imported $(grep -c '^import ' "$log/security.log") identities"
emptied "a refused import"

# app-store-release.sh refuses a platform it does not know, then outside
# CI, then on a missing variable, then on a shallow clone, each before a
# profile is installed or a build starts.
release=("$here/app-store-release.sh" RabbitEars.xcodeproj RabbitEars iOS)
# The job's environment holds the certificates too.
secrets=(APPLE_TEAM_ID=T APPLE_API_KEY=K APPLE_API_KEY_ID=I APPLE_API_ISSUER_ID=S PROVISIONING_PROFILE="$good" "${distribution[@]}" "${installer[@]}")
mkdir -p "$tmp/app"
cd "$tmp/app"
expect 64 env "${faked[@]}" HOME="$home" "${secrets[@]}" "$here/app-store-release.sh" RabbitEars.xcodeproj RabbitEars watchOS
said "usage"
expect 128 env "${faked[@]}" HOME="$home" "${secrets[@]}" "${release[@]}"
said "not a git repository"
expect 1 env "${faked[@]}" CI= HOME="$home" "${secrets[@]}" "${release[@]}"
said "CI only"
expect 1 env -u APPLE_API_KEY -u PROVISIONING_PROFILE "${faked[@]}" HOME="$home" APPLE_TEAM_ID=T APPLE_API_KEY_ID=I APPLE_API_ISSUER_ID=S "${release[@]}"
said "APPLE_API_KEY is not set"
said "PROVISIONING_PROFILE is not set"
unsaid "APPLE_TEAM_ID is not set"
git init --quiet "$tmp/repo"
git -C "$tmp/repo" -c user.name=test -c user.email=test@example.invalid commit --quiet --allow-empty -m one
git -C "$tmp/repo" -c user.name=test -c user.email=test@example.invalid commit --quiet --allow-empty -m two
git clone --quiet --depth 1 "file://$tmp/repo" "$tmp/shallow"
cd "$tmp/shallow"
expect 1 env "${faked[@]}" HOME="$home" "${secrets[@]}" "${release[@]}"
said "shallow"
[ ! -e "$installed" ] || fail "a refused release installed $installed"
[ ! -e build ] && [ ! -e "$tmp/app/build" ] || fail "a refused release started a build"
[ ! -e "$log/xcodebuild.log" ] || fail "a refused release called xcodebuild"

# A release archives with the profile named by a setting only the app
# target reads, exports what this run built, and uploads it with a key that
# lives in the job's temporary folder for the upload alone.
cd "$tmp/repo"
mkdir -p build/release
: > build/release/Old.ipa
expect 0 env "${faked[@]}" HOME="$home" FAKE_PRODUCT=ipa "${secrets[@]}" "${release[@]}"
logged xcodebuild "-destination generic/platform=iOS"
logged xcodebuild "CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=Apple Distribution DEVELOPMENT_TEAM=T APP_STORE_PROFILE=$uuid CURRENT_PROJECT_VERSION=2"
! grep -q "PROVISIONING_PROFILE" "$log/xcodebuild.log" || fail "the profile reached every target: $(cat "$log/xcodebuild.log")"
[ "$(plutil -extract method raw "$log/options.plist")" = app-store-connect ] || fail "the export method is $(plutil -extract method raw "$log/options.plist")"
[ "$(plutil -extract provisioningProfiles.test\\.bundle raw "$log/options.plist")" = "$uuid" ] || fail "the export names no profile for the app: $(cat "$log/options.plist")"
[ "$(plutil -extract manageAppVersionAndBuildNumber raw "$log/options.plist")" = false ] || fail "the export may renumber the build"
! plutil -extract installerSigningCertificate raw "$log/options.plist" > /dev/null 2>&1 || fail "an iOS export names an installer certificate"
[ "$(cat "$log/rsync")" = /usr/bin/rsync ] || fail "the export would copy with $(cat "$log/rsync")"
[ "$(cat "$log/xcrun.log")" = "altool --upload-package build/release/App.ipa --api-key I --api-issuer S --wait" ] || fail "uploaded with: $(cat "$log/xcrun.log")"
case "$(cat "$log/key")" in "$jobtmp"/*) ;; *) fail "the API key was written to $(cat "$log/key")" ;; esac
emptied "a release"
[ ! -e "$installed" ] || fail "a release left $installed"
rm "$log"/*
# The Mac's export is a package, under the Mac's destination, and names the
# certificate that signs the package.
expect 0 env "${faked[@]}" HOME="$home" FAKE_PRODUCT=pkg "${secrets[@]}" "$here/app-store-release.sh" RabbitEars.xcodeproj RabbitEars macOS
logged xcodebuild "-destination generic/platform=macOS"
[ "$(plutil -extract installerSigningCertificate raw "$log/options.plist")" = "3rd Party Mac Developer Installer" ] || fail "the Mac export names no installer certificate: $(cat "$log/options.plist")"
logged xcrun "--upload-package build/release/App.pkg"
rm "$log"/*
# A failed archive uploads nothing and leaves no profile or key behind.
expect 65 env "${faked[@]}" HOME="$home" FAKE_ARCHIVE_FAIL=1 "${secrets[@]}" "${release[@]}"
[ ! -e "$log/xcrun.log" ] || fail "a failed archive was uploaded"
[ ! -e "$installed" ] || fail "a failed archive left $installed"
emptied "a failed archive"

# cut-release.sh --check passes only v<M.m.N>: M.m as the committed version
# file states it and N the commit's ordinal; the repository's own file
# states M.m in that form.
# shellcheck disable=SC2016 # Xcode expands it, not the shell
version='MARKETING_VERSION: 1.0.$(CURRENT_PROJECT_VERSION)'
grep -qE '^    MARKETING_VERSION: [0-9]+\.[0-9]+\.\$\(CURRENT_PROJECT_VERSION\)$' "$here/../version.yaml" ||
    fail "apple/version.yaml states no M.m.\$(CURRENT_PROJECT_VERSION)"
tagged="$tmp/tagged"
mkdir -p "$tagged/scripts" "$tagged/apple"
cp "$here/../../scripts/cut-release.sh" "$tagged/scripts/"
printf 'settings:\n  base:\n    %s\n' "$version" > "$tagged/apple/version.yaml"
git -C "$tagged" init --quiet
git -C "$tagged" add .
git -C "$tagged" -c user.name=test -c user.email=test@example.invalid commit --quiet -m version
expect 0 "$tagged/scripts/cut-release.sh" --check v1.0.1
for tag in v1.0.2 v1.0.0 1.0.1 v1.0 v1.0.1.0 ios-v1.0.1 v1.0.1-rc1; do
    expect 1 "$tagged/scripts/cut-release.sh" --check "$tag"
done
git -C "$tagged" -c user.name=test -c user.email=test@example.invalid commit --quiet --allow-empty -m next
expect 0 "$tagged/scripts/cut-release.sh" --check v1.0.2
expect 1 "$tagged/scripts/cut-release.sh" --check v1.0.1
git clone --quiet --depth 1 "file://$tagged" "$tmp/tagged-shallow"
expect 1 "$tmp/tagged-shallow/scripts/cut-release.sh" --check v1.0.2
said "shallow"
printf 'settings:\n  base:\n    MARKETING_VERSION: 1.0.0\n' > "$tagged/apple/version.yaml"
git -C "$tagged" -c user.name=test -c user.email=test@example.invalid commit --quiet -am fixed
expect 1 "$tagged/scripts/cut-release.sh" --check v1.0.3
said "states no version"

[ "$failures" -eq 0 ] || { echo "$failures failed" >&2; exit 1; }
echo "release scripts: all checks passed"
