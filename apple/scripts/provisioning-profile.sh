#!/usr/bin/env bash
# Installs or removes the provisioning profile in PROVISIONING_PROFILE, a
# base64-encoded .mobileprovision or, for the Mac, .provisionprofile, where
# xcodebuild finds profiles; install prints the profile's UUID. A release
# job installs it for its archive and removes it in a step that always
# runs, so a runner that outlives the job keeps no profile.
#
#   apple/scripts/provisioning-profile.sh install|remove
set -euo pipefail

action="${1:-}"
case "$action" in
    install | remove) ;;
    *) echo "usage: provisioning-profile.sh install|remove" >&2; exit 64 ;;
esac

if [ -z "${PROVISIONING_PROFILE:-}" ]; then
    # remove runs after whatever failed, a missing secret included.
    [ "$action" = remove ] && exit 0
    echo "error: PROVISIONING_PROFILE is not set" >&2
    exit 1
fi

# Xcode 16 and later keep profiles in this folder.
dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/profile.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$PROVISIONING_PROFILE" | base64 --decode > "$tmp/profile.mobileprovision"
# The system's LibreSSL reads the content without a keychain; `security
# cms -D` would import the signer's certificates into the default one.
/usr/bin/openssl smime -verify -noverify -inform DER \
    -in "$tmp/profile.mobileprovision" -out "$tmp/profile.plist" 2>/dev/null ||
    { echo "error: PROVISIONING_PROFILE is not a base64-encoded .mobileprovision" >&2; exit 1; }
uuid="$(plutil -extract UUID raw -o - "$tmp/profile.plist")"
# The UUID names a file that remove deletes, so it must be only a UUID.
[[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
    { echo "error: the profile's UUID '$uuid' is not a UUID" >&2; exit 1; }
# Xcode looks for a Mac profile under its own extension.
extension=mobileprovision
if [ "$(plutil -extract Platform.0 raw -o - "$tmp/profile.plist" 2>/dev/null)" = OSX ]; then
    extension=provisionprofile
fi

if [ "$action" = install ]; then
    mkdir -p "$dir"
    cp "$tmp/profile.mobileprovision" "$dir/$uuid.$extension"
    echo "$uuid"
else
    rm -f "$dir/$uuid.$extension"
fi
