#!/usr/bin/env bash
# Fails, naming each one, when any variable named is unset or empty. A
# release job runs it over the variables it maps its secrets to, before it
# imports or builds anything, so a missing secret fails in seconds and says
# which. An app's own profile secret reaches every app's job as
# PROVISIONING_PROFILE.
#
#   apple/scripts/require-env.sh NAME...
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: require-env.sh NAME..." >&2; exit 64; }

missing=0
for name in "$@"; do
    if [ -z "${!name:-}" ]; then
        echo "::error::$name is not set" >&2
        missing=1
    fi
done
exit "$missing"
