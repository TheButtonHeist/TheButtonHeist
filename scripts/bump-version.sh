#!/usr/bin/env bash
# Update the canonical TheScore version declaration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/release-contract.sh
source "$SCRIPT_DIR/release-contract.sh"

SEMVER_REGEX='^[0-9]+\.[0-9]+\.[0-9]+$'

[[ $# -eq 1 ]] || { echo "Usage: $0 <version>" >&2; exit 1; }
NEW_VERSION="$1"
[[ "$NEW_VERSION" =~ $SEMVER_REGEX ]] \
    || { echo "Error: '$NEW_VERSION' is not MAJOR.MINOR.PATCH" >&2; exit 1; }

CURRENT_VERSION=$(buttonheist_code_version)
[[ "$CURRENT_VERSION" =~ $SEMVER_REGEX ]] \
    || { echo "Error: canonical version '$CURRENT_VERSION' is not MAJOR.MINOR.PATCH" >&2; exit 1; }

TMP_DIR=$(mktemp -d)
UPDATED=false
cleanup() {
    local status=$?
    if [[ "$status" -ne 0 && "$UPDATED" == true ]]; then
        cp "$TMP_DIR/original" "$BUTTONHEIST_CODE_VERSION_FILE"
    fi
    rm -rf "$TMP_DIR"
    exit "$status"
}
trap cleanup EXIT

cp "$BUTTONHEIST_CODE_VERSION_FILE" "$TMP_DIR/original"

CURRENT_PATTERN=${CURRENT_VERSION//./\\.}
sed "s/buttonHeistVersion: ButtonHeistVersion = \"$CURRENT_PATTERN\"/buttonHeistVersion: ButtonHeistVersion = \"$NEW_VERSION\"/" \
    "$BUTTONHEIST_CODE_VERSION_FILE" > "$TMP_DIR/updated"

UPDATED=true
cp "$TMP_DIR/updated" "$BUTTONHEIST_CODE_VERSION_FILE"

"$SCRIPT_DIR/validate-release-contract.sh"
echo "Version: $CURRENT_VERSION -> $NEW_VERSION"
