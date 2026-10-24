#!/usr/bin/env bash
# Run as the final app build phase after embedding the optional XCFrameworks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${CONFIGURATION:?Run this script from an app build phase}"
: "${TARGET_BUILD_DIR:?}"
: "${FRAMEWORKS_FOLDER_PATH:?}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

shopt -s nullglob
frameworks=("$BUNDLE_DIR"/XCFrameworks/*.xcframework)
[[ ${#frameworks[@]} -gt 0 ]] || { echo "Error: TheInsideJob bundle has no XCFrameworks" >&2; exit 1; }

if [[ "$CONFIGURATION" == Debug ]]; then
    case "${PLATFORM_NAME:-}" in
        iphoneos|iphonesimulator) ;;
        *) echo "Error: unsupported TheInsideJob platform: ${PLATFORM_NAME:-unset}" >&2; exit 1 ;;
    esac
    for resource in "$BUNDLE_DIR/Resources/$PLATFORM_NAME/"*.bundle; do
        destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/$(basename "$resource")"
        rm -rf "$destination"
        cp -R "$resource" "$destination"
    done
else
    # Weak linking lets the host launch after its Debug-only binaries are removed.
    for framework in "${frameworks[@]}"; do
        name="$(basename "$framework" .xcframework)"
        rm -rf "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/$name.framework"
    done
    for resource in "$BUNDLE_DIR"/Resources/*/*.bundle; do
        rm -rf "${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/$(basename "$resource")"
    done
fi
