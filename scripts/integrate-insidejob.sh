#!/usr/bin/env bash
# Run as the final app build phase after embedding the optional XCFramework.
set -euo pipefail

: "${CONFIGURATION:?Run this script from an app build phase}"
: "${TARGET_BUILD_DIR:?}"
: "${FRAMEWORKS_FOLDER_PATH:?}"

if [[ "$CONFIGURATION" != Debug ]]; then
    # Weak linking lets the host launch after its Debug-only framework is removed.
    rm -rf "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/TheInsideJob.framework"
fi
