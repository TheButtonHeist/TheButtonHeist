#!/usr/bin/env bash
# Canonical entry point for regenerating Xcode projects.
#
# Wraps `tuist install && tuist generate --no-open` and then auto-cleans the
# generated pbxproj files (see scripts/clean-pbxproj.py for what gets removed).
# Use this instead of calling tuist directly so local generated projects do not
# retain hardcoded SRCROOT or duplicate search-path entries.

set -euo pipefail

cd "$(dirname "$0")/.."

install_dependencies=true
generate_arguments=(--no-open)
for argument in "$@"; do
    case "$argument" in
        --skip-install) install_dependencies=false ;;
        *) generate_arguments+=("$argument") ;;
    esac
done

run_tuist() {
    if [[ -n "${BUTTONHEIST_TUIST_BIN:-}" ]]; then
        "$BUTTONHEIST_TUIST_BIN" "$@"
    elif command -v mise >/dev/null 2>&1 && [[ -f mise.toml ]]; then
        mise exec -- tuist "$@"
    else
        tuist "$@"
    fi
}

if [[ "$install_dependencies" == true ]]; then
    run_tuist install
fi

set +e
run_tuist generate "${generate_arguments[@]}"
generate_status=$?
set -e

"${BUTTONHEIST_GENERATED_PROJECT_CLEANER:-scripts/clean-generated-projects.sh}"

exit "$generate_status"
