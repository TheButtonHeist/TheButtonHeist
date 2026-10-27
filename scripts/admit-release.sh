#!/usr/bin/env bash
# Run from protected main before checking out any requested release source.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=scripts/release-contract.sh
source "$SCRIPT_DIR/release-contract.sh"

[[ $# -eq 1 ]] || { echo "Usage: $0 vMAJOR.MINOR.PATCH" >&2; exit 2; }
TAG="$1"
VERSION="${TAG#v}"
[[ "$TAG" == "v$VERSION" && "$VERSION" =~ $BUTTONHEIST_RELEASE_VERSION_REGEX ]] \
    || { echo "Error: release tag must be vMAJOR.MINOR.PATCH" >&2; exit 2; }

git fetch --no-tags origin "refs/tags/$TAG:refs/tags/$TAG"
SHA=$(git rev-parse --verify --end-of-options "refs/tags/$TAG^{commit}")
"$SCRIPT_DIR/require-release-commit.sh" --repo "$BUTTONHEIST_GITHUB_REPO" "$SHA"
CODE_VERSION=$(git show "$SHA:$BUTTONHEIST_CODE_VERSION_FILE" | buttonheist_parse_code_version)
[[ "$CODE_VERSION" == "$VERSION" ]] \
    || { echo "Error: tag version does not match the admitted source version" >&2; exit 1; }
printf 'sha=%s\nversion=%s\n' "$SHA" "$VERSION" >> "${GITHUB_OUTPUT:-/dev/stdout}"
