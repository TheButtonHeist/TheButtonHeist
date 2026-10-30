#!/usr/bin/env bash
# Guard source-level house rules that the compiler and API diff do not own.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${BUTTONHEIST_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
BUMPER_CACHE_DIR="${BUMPER_CACHE_DIR:-$REPO_ROOT/.build/bumper-cache}"
BUMPER_EVALUATION_TIMEOUT_SECONDS="${BUMPER_EVALUATION_TIMEOUT_SECONDS:-300}"
BUMPER_RUNNER_BUILD_CONFIGURATION="${BUMPER_RUNNER_BUILD_CONFIGURATION:-debug}"
export BUMPER_CACHE_DIR BUMPER_EVALUATION_TIMEOUT_SECONDS BUMPER_RUNNER_BUILD_CONFIGURATION

if (( $# > 1 )); then
    echo "Usage: scripts/check-source-shape.sh [lint|test]" >&2
    exit 2
fi

COMMAND="${1:-lint}"
case "$COMMAND" in
    lint|test) ;;
    *)
        echo "Usage: scripts/check-source-shape.sh [lint|test]" >&2
        exit 2
        ;;
esac

export BUTTONHEIST_SOURCE_ROOT="$REPO_ROOT"

# Coverage needs the filesystem: Bumper drops unowned files before rule evaluation.
swift run \
    --package-path "$REPO_ROOT" \
    --configuration debug \
    bumper test "$REPO_ROOT"

if [[ "$COMMAND" == "lint" ]]; then
    swift run \
        --package-path "$REPO_ROOT" \
        --configuration debug \
        bumper lint "$REPO_ROOT" --fail-on error
fi
