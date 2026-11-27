#!/usr/bin/env bash
# Prints the folder that holds the server's source at the version
# openapi.yaml states: a shallow clone of that release's tag under build/,
# made once. With RABBIT_EARS_SERVER_SRC set to a checkout of the server's
# repository it prints that instead, for work on both at once.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${RABBIT_EARS_SERVER_SRC:-}" ]; then
    cd "$RABBIT_EARS_SERVER_SRC" && pwd
    exit 0
fi
version="$(sed -n 's/^  version: *//p' openapi.yaml | head -1)"
[ -n "$version" ] || { echo "error: openapi.yaml states no info.version" >&2; exit 1; }
dir="build/server-$version"
# A clone that failed midway has no server/ and is made again.
if [ ! -d "$dir/server" ]; then
    rm -rf "$dir"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$version" \
        https://github.com/legitimate-enterprises/rabbit-ears.git "$dir" >&2
fi
cd "$dir" && pwd
