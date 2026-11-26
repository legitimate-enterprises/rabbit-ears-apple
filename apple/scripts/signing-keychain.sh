#!/usr/bin/env bash
# Puts the App Store signing identities in a throwaway keychain,
# build.keychain, and puts it first in the user's search list, where
# xcodebuild finds them: the Apple Distribution identity from
# APPLE_DISTRIBUTION_CERT_P12 and, for the Mac, the installer identity that
# signs its package from MAC_INSTALLER_CERT_P12. Each is a base64-encoded
# .p12 with its password in the variable of the same name ending _PASSWORD.
#
#   apple/scripts/signing-keychain.sh <iOS|tvOS|macOS>
#
# CI only: it replaces the user's keychain search list. The release job's
# runner is GitHub's and is discarded with the job, so nothing puts the list
# back.
set -euo pipefail

usage="usage: signing-keychain.sh <iOS|tvOS|macOS>"
here="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
    iOS | tvOS) certificates="APPLE_DISTRIBUTION_CERT" ;;
    macOS) certificates="APPLE_DISTRIBUTION_CERT MAC_INSTALLER_CERT" ;;
    *) echo "$usage" >&2; exit 64 ;;
esac

if [ -z "${CI:-}" ]; then
    echo "error: releases are produced by CI only; this would replace the keychain search list" >&2
    exit 1
fi
for certificate in $certificates; do
    "$here/require-env.sh" "${certificate}_P12" "${certificate}_PASSWORD"
done

work="$(mktemp -d "${TMPDIR:-/tmp}/keychain.XXXXXX")"
trap 'rm -rf "$work"' EXIT
security delete-keychain build.keychain 2>/dev/null || true
keychain_password="$(uuidgen)"
security create-keychain -p "$keychain_password" build.keychain
security set-keychain-settings -lut 21600 build.keychain
security unlock-keychain -p "$keychain_password" build.keychain
for certificate in $certificates; do
    p12="${certificate}_P12"
    password="${certificate}_PASSWORD"
    printf '%s' "${!p12}" | base64 --decode > "$work/identity.p12"
    security import "$work/identity.p12" -k build.keychain -P "${!password}" \
        -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/security
done
# Without the partition list each use of a key waits for a confirmation
# nobody can give.
security set-key-partition-list -S "apple-tool:,apple:,codesign:" \
    -s -k "$keychain_password" build.keychain > /dev/null
security list-keychains -d user -s build.keychain login.keychain

# An identity whose chain or key is unusable fails here, by name, not
# midway through the archive.
identities="$(security find-identity -v build.keychain)"
wanted=("Apple Distribution")
[ "$1" != macOS ] || wanted+=("3rd Party Mac Developer Installer")
for identity in "${wanted[@]}"; do
    grep -q "\"$identity: " <<< "$identities" ||
        { echo "::error::no valid $identity identity in build.keychain" >&2; exit 1; }
done
