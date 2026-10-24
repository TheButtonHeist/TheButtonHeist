#!/usr/bin/env bash
# Package one dynamic Debug runtime with statically linked private dependencies.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
source scripts/release-contract.sh

if [[ $# != 1 ]]; then
    echo "Usage: scripts/package-insidejob.sh <output-directory>" >&2
    exit 2
fi
mkdir -p "$1"
OUTPUT="$(cd "$1" && pwd)"
VERSION="$(buttonheist_code_version)"
ARCHIVE="$OUTPUT/$(buttonheist_insidejob_archive_name "$VERSION")"
[[ ! -e "$ARCHIVE" ]] || { echo "Error: archive already exists: $ARCHIVE" >&2; exit 1; }
STAGING="$(mktemp -d "$OUTPUT/.insidejob.XXXXXX")"
cleanup() {
    status=$?
    trap - EXIT
    TUIST_INSIDEJOB_DISTRIBUTION=false ./scripts/generate-project.sh --skip-install || status=1
    rm -rf "$STAGING"
    exit "$status"
}
trap cleanup EXIT
TUIST_INSIDEJOB_DISTRIBUTION=true ./scripts/generate-project.sh
BUNDLE="$STAGING/TheInsideJob.xcframework"

for platform in iphoneos iphonesimulator; do
    case "$platform" in
        iphoneos) destination='generic/platform=iOS' ;;
        iphonesimulator) destination='generic/platform=iOS Simulator' ;;
    esac
    xcodebuild -workspace ButtonHeist.xcworkspace -scheme TheInsideJob \
        -configuration Debug -destination "$destination" \
        -derivedDataPath "$STAGING/DerivedData" \
        SKIP_INSTALL=NO \
        CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO \
        DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
        build

    # Tuist leaves static-package resources beside the final dynamic framework.
    products="$STAGING/DerivedData/Build/Products/Debug-$platform"
    shopt -s nullglob
    for resource in "$products/"*.bundle; do
        cp -R "$resource" "$products/TheInsideJob.framework/"
    done
done

PRODUCTS="$STAGING/DerivedData/Build/Products"
# Automatic loading needs no Swift import, so preserve compiler-specific modules.
xcodebuild -create-xcframework \
    -allow-internal-distribution \
    -framework "$PRODUCTS/Debug-iphoneos/TheInsideJob.framework" \
    -debug-symbols "$PRODUCTS/Debug-iphoneos/TheInsideJob.framework.dSYM" \
    -framework "$PRODUCTS/Debug-iphonesimulator/TheInsideJob.framework" \
    -debug-symbols "$PRODUCTS/Debug-iphonesimulator/TheInsideJob.framework.dSYM" \
    -output "$BUNDLE"

cp docs/PREBUILT-IOS.md "$BUNDLE/README.md"
mkdir -p "$BUNDLE/Licenses"
cp LICENSE "$BUNDLE/Licenses/ButtonHeist.txt"
cp Tuist/.build/checkouts/AccessibilitySnapshotBH/LICENSE "$BUNDLE/Licenses/AccessibilitySnapshotBH.txt"
cp Tuist/.build/checkouts/AccessibilitySnapshotBH/NOTICE.txt "$BUNDLE/Licenses/AccessibilitySnapshotBH-NOTICE.txt"
printf '%s\n' "$VERSION" > "$BUNDLE/VERSION"
xcodebuild -version > "$BUNDLE/XCODE_VERSION"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ARCHIVE"
echo "Packaged $ARCHIVE"
