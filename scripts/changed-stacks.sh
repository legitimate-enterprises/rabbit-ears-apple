#!/usr/bin/env bash
# Prints `<stack>=true` or `<stack>=false` for every stack: whether anything
# its gates read differs from the last commit on main whose ci run was
# green. Comparing with that commit, not the one before this push, keeps a
# stack that went red from being skipped by a later push that leaves it
# alone. A path this does not know, or no green run to compare with, runs
# every stack.
set -euo pipefail
cd "$(dirname "$0")/.."

STACKS="apple macos ios tvos"

all() {
    for s in $STACKS; do echo "$s=true"; done
    exit 0
}

# Push runs only: a pull request's run tests a merge, not the commit it names.
base="$(gh run list --workflow ci.yaml --branch main --event push --status success --limit 1 \
    --json headSha --jq '.[0].headSha // empty' 2>/dev/null)" || all
[ -n "$base" ] || all
# The checkout is shallow; one commit is all a comparison of trees needs.
git cat-file -e "$base^{commit}" 2>/dev/null || git fetch --quiet --depth=1 origin "$base" 2>/dev/null || all

run=" "
while IFS= read -r f; do
    case "$f" in
        # Read by no gate.
        README.md | AGENTS.md | LICENSE | .gitignore | scripts/cut-release.sh | .github/workflows/release.yaml \
            | .github/actions/* | assets/*) ;;
        # The generated API package is checked against the spec, and the spec
        # names the server the demo server and the UI tests run.
        openapi.yaml | scripts/server-source.sh | scripts/with-demo-server.py | scripts/tests/*) run="$run apple macos ios tvos " ;;
        # The kit, its tests and the API package are compiled into all
        # three apps.
        apple/*) run="$run apple macos ios tvos " ;;
        macos/* | ios/* | tvos/*) run="$run ${f%%/*} " ;;
        *) all ;;
    esac
done < <(git diff --no-renames --name-only "$base" HEAD)

for s in $STACKS; do
    case "$run" in
        *" $s "*) echo "$s=true" ;;
        *) echo "$s=false" ;;
    esac
done
