#!/usr/bin/env bash
# Makes build/grdb, the local package the apps link: GRDB at GRDB_TAG with
# grdb-sqlite.patch applied, so it compiles the SQLite amalgamation below
# instead of linking the system's. That SQLite is the server's own, the one
# its modernc.org/sqlite release bundles; bump the two together. Remade only
# when the pin or the patch changes; a patch that no longer applies fails.
set -euo pipefail
cd "$(dirname "$0")/../.."

GRDB_TAG=v7.12.0
SQLITE_URL=https://sqlite.org/2026/sqlite-amalgamation-3540100.zip
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9

patch="$PWD/apple/scripts/grdb-sqlite.patch"
dir=build/grdb
pin="$GRDB_TAG $SQLITE_URL $SQLITE_SHA256 $(shasum -a 256 <"$patch" | cut -d ' ' -f 1)"
[ "$(cat "$dir/.pin" 2>/dev/null)" != "$pin" ] || exit 0

mkdir -p build
tmp="$(mktemp -d build/grdb.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$GRDB_TAG" \
    https://github.com/groue/GRDB.swift.git "$tmp/grdb"
git -C "$tmp/grdb" apply "$patch"
curl --fail --silent --show-error --location --output "$tmp/sqlite.zip" "$SQLITE_URL"
echo "$SQLITE_SHA256  $tmp/sqlite.zip" | shasum -a 256 --check --status ||
    { echo "error: $SQLITE_URL does not match SQLITE_SHA256" >&2; exit 1; }
unzip -q -j "$tmp/sqlite.zip" '*/sqlite3.c' '*/sqlite3.h' -d "$tmp/grdb/Sources/GRDBSQLite"
echo "$pin" >"$tmp/grdb/.pin"
rm -rf "$dir"
mv "$tmp/grdb" "$dir"
