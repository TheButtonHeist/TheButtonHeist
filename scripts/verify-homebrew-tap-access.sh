#!/usr/bin/env bash
# Recreate the existing tree to test Contents write without changing any ref.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release-contract.sh
source "$SCRIPT_DIR/release-contract.sh"
[[ -n "${HOMEBREW_TAP_TOKEN:-}" ]] \
    || { echo "Error: HOMEBREW_TAP_TOKEN is required" >&2; exit 1; }
export GH_TOKEN="$HOMEBREW_TAP_TOKEN"

branch=$(gh api "repos/$BUTTONHEIST_TAP_REPO" --jq '.default_branch | @uri')
tree=$(gh api "repos/$BUTTONHEIST_TAP_REPO/git/trees/$branch")
jq -e '.truncated == false and (.tree | length > 0)' <<< "$tree" >/dev/null
sha=$(jq -r '.sha' <<< "$tree")
verified_sha=$(jq '{tree: [.tree[] | {path, mode, type, sha}]}' <<< "$tree" \
    | gh api "repos/$BUTTONHEIST_TAP_REPO/git/trees" --method POST --input - --jq '.sha')
[[ "$verified_sha" == "$sha" ]] \
    || { echo "Error: tap access check returned a different tree" >&2; exit 1; }
echo "HOMEBREW_TAP_TOKEN can write to $BUTTONHEIST_TAP_REPO. No branch was changed."
