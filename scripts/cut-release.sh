#!/usr/bin/env bash
# Tags origin/main v<M.m.N>, the version ci gave all three apps it uploaded
# from that commit, once ci is green there: M.m as apple/version.yaml states
# it, N the commit's ordinal on main, the build number.
#
# Usage: cut-release.sh                  the version and whether it can be tagged
#        cut-release.sh --yes            tag and push it
#        cut-release.sh --check <tag>    fail unless the tag is HEAD's version
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE=apple/version.yaml
# What ships: the kit and the API package are compiled into every app.
PATHS="apple macos ios tvos"

die() { echo "error: $*" >&2; exit 1; }

# version_at <ref>
version_at() {
    local v form='^([0-9]+\.[0-9]+)\.\$\(CURRENT_PROJECT_VERSION\)$'
    # A shallow clone counts only the commits it holds.
    [ "$(git rev-parse --is-shallow-repository)" = false ] || die "the checkout is shallow; fetch its full history"
    v="$(git show "$1:$SOURCE" | sed -n 's/^ *MARKETING_VERSION: *//p')"
    [[ "$v" =~ $form ]] || die "$SOURCE at $1 states no version of the form $form (got '$v')"
    echo "${BASH_REMATCH[1]}.$(git rev-list --count "$1")"
}

# state_of: one line saying whether origin/main can be tagged. Returns 0 when
# it can, 1 when there is nothing to release, 2 when M.m must be put right
# first.
state_of() {
    local v tag newest
    v="$(version_at origin/main)" || return 2
    tag="v$v"
    if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null; then
        echo "$v is released"
        return 1
    fi
    newest="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' | sort -V | tail -1)"
    if [ -n "$newest" ]; then
        # shellcheck disable=SC2086 # the paths are separate arguments
        if git diff --quiet "v$newest" origin/main -- $PATHS; then
            echo "nothing that ships has changed since v$newest"
            return 1
        fi
        if [ "$(printf '%s\n%s\n' "$newest" "$v" | sort -V | tail -1)" != "$v" ]; then
            echo "says $v, below the released $newest: M.m in $SOURCE is the owner's to raise"
            return 2
        fi
    fi
    echo "$v is ready: $tag"
}

if [ "${1:-}" = "--check" ]; then
    tag="${2:?usage: cut-release.sh --check <tag>}"
    v="$(version_at HEAD)"
    [ "$tag" = "v$v" ] || die "$tag is on a commit whose version is $v"
    exit 0
fi

confirmed=""
case "$*" in
    "") ;;
    --yes) confirmed=1 ;;
    *) die "usage: cut-release.sh [--yes] | --check <tag>" ;;
esac

git fetch origin main --tags --quiet

rc=0
state="$(state_of)" || rc=$?
[ -z "$state" ] || echo "$state"
case "$rc" in
    1) [ -z "$confirmed" ] || die "nothing is ready to release"; exit 0 ;;
    2) die "nothing tagged: put M.m right first" ;;
esac
tag="${state##* }"
[ -n "$confirmed" ] || { echo "to tag $tag, run: make deploy YES=1"; exit 0; }

# A tag is a promise that its commit passed ci, so the check comes before
# the tag exists.
sha="$(git rev-parse origin/main)"
echo "tagging origin/main at ${sha:0:8}: $(git log -1 --format=%s "$sha")"
command -v gh >/dev/null 2>&1 || die "gh is required to verify ci before tagging (brew install gh)"

# A run record appears a beat after the push that created it.
deadline=$((SECONDS + 120))
while :; do
    run="$(gh run list --workflow ci.yaml --branch main --commit "$sha" --limit 1 \
        --json databaseId,status,conclusion,url \
        --jq '.[0] // empty | [.databaseId, .status, .conclusion // "pending", .url] | @tsv')" ||
        die "could not query ci runs; check 'gh auth status'"
    [ -n "$run" ] && break
    [ "$SECONDS" -lt "$deadline" ] || die "no ci run for ${sha:0:8} on main after 120s; is the commit pushed?"
    sleep 5
done
IFS=$'\t' read -r run_id run_status run_conclusion run_url <<< "$run"

if [ "$run_status" != "completed" ]; then
    echo "waiting for ci on ${sha:0:8}: $run_url"
    gh run watch "$run_id" --exit-status || die "ci failed; no tag created: $run_url"
elif [ "$run_conclusion" != "success" ]; then
    die "ci concluded '$run_conclusion'; no tag created: $run_url"
fi

# main can move while ci runs; the tag belongs on the commit that run vouched for.
git fetch origin main --quiet
[ "$(git rev-parse origin/main)" = "$sha" ] || die "origin/main moved while ci ran; no tag created"

git tag --annotate "$tag" --message "$tag" "$sha"
git push origin "$tag"
echo "pushed $tag"
