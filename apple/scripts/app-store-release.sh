#!/usr/bin/env bash
# Archives an iOS, Apple TV or macOS app signed for App Store distribution,
# exports it, and uploads it to App Store Connect, where it reaches
# TestFlight once processed.
#
#   ../apple/scripts/app-store-release.sh <project> <scheme> <iOS|tvOS|macOS>
#
# Run from the app's directory by its `make release`, in ci's TestFlight job
# on main, after signing-keychain.sh. The build number N is the commit
# count, which rises with every commit on a linear main, as each upload to
# App Store Connect needs; the version is M.m.N, M.m as apple/version.yaml
# states it. The app target's Release configuration names its profile as
# PROVISIONING_PROFILE_SPECIFIER = $(APP_STORE_PROFILE): a profile set on
# the command line would reach the frameworks too, which refuse one.
set -euo pipefail

usage="usage: app-store-release.sh <project> <scheme> <iOS|tvOS|macOS>"
project="${1:?$usage}"
scheme="${2:?$usage}"
platform="${3:?$usage}"
here="$(cd "$(dirname "$0")" && pwd)"
case "$platform" in
    iOS | tvOS | macOS) ;;
    *) echo "$usage" >&2; exit 64 ;;
esac

if [ -z "${CI:-}" ]; then
    echo "error: releases are produced by CI only, from a green run on main" >&2
    exit 1
fi
"$here/require-env.sh" APPLE_TEAM_ID APPLE_API_KEY APPLE_API_KEY_ID APPLE_API_ISSUER_ID PROVISIONING_PROFILE
# A shallow clone counts only the commits it holds, so every release would
# carry the same build number and App Store Connect would refuse the second.
shallow="$(git rev-parse --is-shallow-repository)"
if [ "$shallow" != false ]; then
    echo "error: the checkout is shallow; check out with fetch-depth 0" >&2
    exit 1
fi

# Under TMPDIR, the job's own folder, and not where mktemp puts a bare
# request: the system's per-user folder, which outlives the job.
work="$(mktemp -d "${TMPDIR:-/tmp}/release.XXXXXX")"
trap '"$here/provisioning-profile.sh" remove; rm -rf "$work"' EXIT
profile="$("$here/provisioning-profile.sh" install)"

out=build/release
archive="$out/$scheme.xcarchive"
# A leftover archive or export from an earlier attempt would be uploaded in
# place of what this run builds.
rm -rf "$out"

# The build and the export need none of the secrets: signing-keychain.sh has
# already imported the certificates.
unset_secrets=(env -u APPLE_API_KEY -u PROVISIONING_PROFILE
    -u APPLE_DISTRIBUTION_CERT_P12 -u APPLE_DISTRIBUTION_CERT_PASSWORD
    -u MAC_INSTALLER_CERT_P12 -u MAC_INSTALLER_CERT_PASSWORD)
"${unset_secrets[@]}" xcodebuild -project "$project" -scheme "$scheme" -derivedDataPath build \
    -destination "generic/platform=$platform" -configuration Release \
    -archivePath "$archive" archive \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" APP_STORE_PROFILE="$profile" \
    CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$archive/Info.plist")"
options="$work/export-options.plist"
plutil -create xml1 "$options"
plutil -insert method -string app-store-connect "$options"
plutil -insert signingStyle -string manual "$options"
plutil -insert signingCertificate -string "Apple Distribution" "$options"
# The Mac's package is signed by a certificate of its own. Left unnamed, the
# export signs the app with that one too, which the profile does not hold.
[ "$platform" != macOS ] || plutil -insert installerSigningCertificate -string "3rd Party Mac Developer Installer" "$options"
plutil -insert teamID -string "$APPLE_TEAM_ID" "$options"
plutil -insert provisioningProfiles -json "{\"$bundle_id\": \"$profile\"}" "$options"
# The build number stays the one stamped above.
plutil -insert manageAppVersionAndBuildNumber -bool NO "$options"
# The export copies with /usr/bin/rsync, which starts the first rsync on
# PATH as its other end, and Homebrew's refuses the options it is sent.
xcodebuild="$(command -v xcodebuild)"
"${unset_secrets[@]}" PATH="/usr/bin:$PATH" "$xcodebuild" -exportArchive -archivePath "$archive" -exportPath "$out" -exportOptionsPlist "$options"

# The Mac export is an installer package.
package="$(find "$out" -maxdepth 1 \( -name '*.ipa' -o -name '*.pkg' \) | head -1)"
[ -n "$package" ] || { echo "error: the export left no .ipa or .pkg in $out" >&2; exit 1; }

# altool reads the key from AuthKey_<id>.p8 in API_PRIVATE_KEYS_DIR.
# --wait holds the job until App Store Connect has processed the build, so a
# build it rejects fails the release instead of arriving later by email.
printf '%s' "$APPLE_API_KEY" > "$work/AuthKey_$APPLE_API_KEY_ID.p8"
API_PRIVATE_KEYS_DIR="$work" xcrun altool --upload-package "$package" \
    --api-key "$APPLE_API_KEY_ID" --api-issuer "$APPLE_API_ISSUER_ID" --wait
echo "uploaded $(basename "$package") ($bundle_id) to App Store Connect"
