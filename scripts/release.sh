#!/usr/bin/env bash
# Prepare a version bump, or publish the unreleased version on signed, green main.
# Version changes go through the normal PR/CI path before publication.
# Usage: ./scripts/release.sh [--dry-run] [--major | --minor | <version>]
#        ./scripts/release.sh --tag-current [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/release-contract.sh
source "$SCRIPT_DIR/release-contract.sh"

DRY_RUN=false
TAG_CURRENT=false
BUMP_TYPE=""
VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --tag-current) TAG_CURRENT=true ;;
        --major|--minor)
            [[ -z "$BUMP_TYPE$VERSION" ]] || { echo "Error: choose one version or bump flag" >&2; exit 2; }
            BUMP_TYPE="${1#--}"
            ;;
        -*) echo "Error: unknown flag '$1'" >&2; exit 2 ;;
        *)
            [[ -z "$BUMP_TYPE$VERSION" ]] || { echo "Error: choose one version or bump flag" >&2; exit 2; }
            VERSION="$1"
            ;;
    esac
    shift
done
if [[ "$TAG_CURRENT" == true && -n "$BUMP_TYPE$VERSION" ]]; then
    echo "Error: --tag-current cannot be combined with a version or bump flag" >&2
    exit 2
fi
if [[ -n "$VERSION" && ! "$VERSION" =~ $BUTTONHEIST_RELEASE_VERSION_REGEX ]]; then
    echo "Error: version must be MAJOR.MINOR.PATCH" >&2
    exit 2
fi

retry_publication() {
    echo "  Retry publication of the existing tag:"
    echo "    gh workflow run release.yml --repo $BUTTONHEIST_GITHUB_REPO --ref main -f tag=v$1"
}

[[ "$(git branch --show-current)" == main ]] || { echo "Error: release from main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Error: worktree must be clean" >&2; exit 1; }
git fetch origin main --quiet
RELEASE_SHA=$(git rev-parse origin/main)
[[ "$(git rev-parse HEAD)" == "$RELEASE_SHA" ]] || { echo "Error: HEAD must equal origin/main" >&2; exit 1; }

"$SCRIPT_DIR/require-release-commit.sh" --timeout 1200 "$RELEASE_SHA" "main HEAD"
"$SCRIPT_DIR/validate-release-contract.sh"

# Waiting for admission must not silently select a different main commit.
git fetch origin main --quiet
if [[ "$(git rev-parse origin/main)" != "$RELEASE_SHA" || "$(git rev-parse HEAD)" != "$RELEASE_SHA" ]]; then
    echo "Error: main moved during release admission; update the checkout and retry" >&2
    exit 1
fi
[[ -z "$(git status --porcelain)" ]] || { echo "Error: worktree changed during admission" >&2; exit 1; }

BUILD_VERSION=$(buttonheist_code_version)
[[ "$BUILD_VERSION" =~ $BUTTONHEIST_BUILD_VERSION_REGEX ]] || { echo "Error: invalid source version" >&2; exit 1; }
CURRENT_VERSION=${BUILD_VERSION%%-*}
if [[ "$TAG_CURRENT" == true && "$BUILD_VERSION" != "$CURRENT_VERSION" ]]; then
    echo "Error: a development version cannot be tagged; prepare the next release first" >&2
    exit 1
fi
CURRENT_REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/v$CURRENT_VERSION")
CURRENT_TAG_EXISTS=false
if [[ -n "$CURRENT_REMOTE_TAG" ]] || git show-ref --verify --quiet "refs/tags/v$CURRENT_VERSION"; then
    CURRENT_TAG_EXISTS=true
fi
if [[ "$CURRENT_TAG_EXISTS" == true && -z "$CURRENT_REMOTE_TAG" ]]; then
    echo "Error: local tag v$CURRENT_VERSION exists, but its remote tag is missing."
    echo "Check the local tag before retrying its push: git push origin refs/tags/v$CURRENT_VERSION"
    exit 1
fi
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
if [[ -n "$BUMP_TYPE" ]]; then
    case "$BUMP_TYPE" in
        major) VERSION="$((MAJOR + 1)).0.0" ;;
        minor) VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
    esac
elif [[ -z "$VERSION" ]]; then
    VERSION="$CURRENT_VERSION"
    if [[ "$TAG_CURRENT" == false && "$CURRENT_TAG_EXISTS" == true ]]; then
        if ! IS_DRAFT=$(gh release view "v$CURRENT_VERSION" --repo "$BUTTONHEIST_GITHUB_REPO" --json isDraft --jq '.isDraft') \
            || [[ "$IS_DRAFT" != false ]]; then
            echo "Error: v$CURRENT_VERSION is tagged but publication is incomplete or could not be verified."
            retry_publication "$CURRENT_VERSION"
            exit 1
        fi
        VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
    elif [[ "$BUILD_VERSION" != "$CURRENT_VERSION" ]]; then
        VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
    fi
fi
if [[ "$VERSION" != "$CURRENT_VERSION" ]]; then
    if ! jq -en --arg current "$CURRENT_VERSION" --arg next "$VERSION" \
        '($next | split(".") | map(tonumber)) > ($current | split(".") | map(tonumber))' >/dev/null; then
        echo "Error: prepared version must be newer than $CURRENT_VERSION" >&2
        exit 1
    fi
    TARGET_REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/v$VERSION")
    if [[ -n "$TARGET_REMOTE_TAG" ]] || git show-ref --verify --quiet "refs/tags/v$VERSION"; then
        echo "Error: v$VERSION already exists; choose a new version" >&2
        exit 1
    fi
    if [[ "$DRY_RUN" == true ]]; then
        echo "Would run scripts/bump-version.sh $VERSION."
    else
        "$SCRIPT_DIR/bump-version.sh" "$VERSION"
    fi
    echo "Version preparation: $CURRENT_VERSION -> $VERSION. No release was published."
    echo "Merge this change as a signed commit and wait for main CI, then run ./scripts/release.sh."
    exit 0
fi
if [[ "$CURRENT_TAG_EXISTS" == true ]]; then
    echo "Error: v$VERSION already exists; its tag and published files are preserved."
    retry_publication "$VERSION"
    exit 1
fi
if [[ "$BUILD_VERSION" != "$CURRENT_VERSION" ]]; then
    echo "Error: prepare a newer release version to clear the development hash" >&2
    exit 1
fi
if [[ "$DRY_RUN" == true ]]; then
    echo "Would tag signed, green main $RELEASE_SHA as v$VERSION."
    echo "Release CI would build this exact commit, verify artifacts, publish, and update both formulas."
    exit 0
fi

git tag "v$VERSION" "$RELEASE_SHA"
git push origin "refs/tags/v$VERSION"
echo "Tagged signed, green main $RELEASE_SHA as v$VERSION."
DISPATCHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! gh workflow run release.yml --repo "$BUTTONHEIST_GITHUB_REPO" --ref main -f "tag=v$VERSION"; then
    echo "Release dispatch failed; the tag is preserved."
    retry_publication "$VERSION"
    exit 1
fi

RUN_ID=""
for _ in {1..30}; do
    if ! RUN_ID=$(gh run list --repo "$BUTTONHEIST_GITHUB_REPO" --workflow Release \
        --branch main --event workflow_dispatch --created ">=$DISPATCHED_AT" \
        --limit 20 --json databaseId,displayTitle \
        | jq -r --arg title "Release v$VERSION" '[.[] | select(.displayTitle == $title)][0].databaseId // ""'); then
        echo "Could not inspect release workflows. The tag is preserved."
        retry_publication "$VERSION"
        exit 1
    fi
    [[ -z "$RUN_ID" ]] || break
    sleep 5
done
if [[ -z "$RUN_ID" ]]; then
    echo "No release workflow run found. The tag is preserved; check Actions before retrying."
    retry_publication "$VERSION"
    exit 1
fi
if ! gh run watch "$RUN_ID" --repo "$BUTTONHEIST_GITHUB_REPO" --exit-status; then
    echo "Release workflow failed; tag and published files are preserved."
    echo "Inspect: https://github.com/$BUTTONHEIST_GITHUB_REPO/actions/runs/$RUN_ID"
    retry_publication "$VERSION"
    exit 1
fi
buttonheist_upgrade_installed_formulas "$VERSION"
echo "Release $VERSION complete."
