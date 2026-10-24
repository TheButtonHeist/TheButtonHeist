#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

for configuration in Debug Release Staging; do
    framework="$FIXTURE/Build/Consumer.app/Frameworks/TheInsideJob.framework"
    mkdir -p "$framework/Parser.bundle"
    mkdir -p "$FIXTURE/Build/Consumer.app/Frameworks/Unrelated.framework"
    CONFIGURATION="$configuration" TARGET_BUILD_DIR="$FIXTURE/Build" \
    FRAMEWORKS_FOLDER_PATH="Consumer.app/Frameworks" \
        bash "$REPO_ROOT/scripts/integrate-insidejob.sh"
    if [[ "$configuration" == Debug ]]; then
        [[ -d "$framework/Parser.bundle" ]]
    else
        [[ ! -e "$framework" ]]
    fi
    [[ -d "$FIXTURE/Build/Consumer.app/Frameworks/Unrelated.framework" ]]
done

echo "PASS: Debug keeps the framework and its resources; other configurations remove it"
