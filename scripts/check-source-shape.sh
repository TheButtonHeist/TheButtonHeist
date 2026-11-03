#!/usr/bin/env bash
# Guard source-level house rules that the compiler and API diff do not own.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${BUTTONHEIST_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
BUMPER_EVALUATION_TIMEOUT_SECONDS="${BUMPER_EVALUATION_TIMEOUT_SECONDS:-300}"
BUMPER_RUNNER_BUILD_CONFIGURATION="${BUMPER_RUNNER_BUILD_CONFIGURATION:-debug}"
export BUMPER_EVALUATION_TIMEOUT_SECONDS BUMPER_RUNNER_BUILD_CONFIGURATION

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

# Keep build cost separate from rule tests and source evaluation.
phase() {
    local name="$1" started="$SECONDS" status=0
    shift
    "$@" || status=$?
    echo "Bumper $name: $((SECONDS - started))s (exit $status)" >&2
    return "$status"
}

build_rules() {
    swift build --package-path "$REPO_ROOT/.bumper" --configuration debug --product bumper || return "$?"
    swift build --package-path "$REPO_ROOT/.bumper" --configuration debug --build-tests || return "$?"
    if [[ "$COMMAND" == "lint" && "$BUMPER_RUNNER_BUILD_CONFIGURATION" != "debug" ]]; then
        swift build --package-path "$REPO_ROOT/.bumper" \
            --configuration "$BUMPER_RUNNER_BUILD_CONFIGURATION" --product BumperRulesRunner || return "$?"
    fi
    local bin_path
    bin_path="$(swift build --package-path "$REPO_ROOT/.bumper" --configuration debug --show-bin-path)" || return "$?"
    if [[ "$bin_path" != /* || "$bin_path" == *$'\n'* || "$bin_path" == *$'\r'* || ! -x "$bin_path/bumper" ]]; then
        echo "SwiftPM did not return an executable Bumper directory." >&2
        return 2
    fi
    BUMPER_EXECUTABLE="$bin_path/bumper"
}

phase build build_rules
phase tests "$BUMPER_EXECUTABLE" test "$REPO_ROOT"
if [[ "$COMMAND" == "lint" ]]; then
    phase lint "$BUMPER_EXECUTABLE" lint "$REPO_ROOT"
fi
