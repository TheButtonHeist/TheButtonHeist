#!/usr/bin/env bash
# Package the Debug iOS runtime and its complete binary dependency closure.
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
trap 'rm -rf "$STAGING"' EXIT
BUNDLE="$STAGING/TheInsideJob"
mkdir -p "$BUNDLE/XCFrameworks" "$BUNDLE/Scripts"

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

    products="$STAGING/DerivedData/Build/Products/Debug-$platform"
    mkdir -p "$BUNDLE/Resources/$platform"
    shopt -s nullglob
    for resource in "$products/"*.bundle; do
        cp -R "$resource" "$BUNDLE/Resources/$platform/"
    done
done

PRODUCTS="$STAGING/DerivedData/Build/Products"
frameworks=("$PRODUCTS/Debug-iphoneos/"*.framework)
[[ ${#frameworks[@]} -gt 0 && -d "$PRODUCTS/Debug-iphoneos/TheInsideJob.framework" ]] \
    || { echo "Error: TheInsideJob build produced no runtime" >&2; exit 1; }
for framework in "${frameworks[@]}"; do
    name="$(basename "$framework" .framework)"
    # Automatic loading needs no Swift import, so preserve compiler-specific modules.
    xcodebuild -create-xcframework \
        -allow-internal-distribution \
        -framework "$framework" \
        -debug-symbols "$PRODUCTS/Debug-iphoneos/$name.framework.dSYM" \
        -framework "$PRODUCTS/Debug-iphonesimulator/$name.framework" \
        -debug-symbols "$PRODUCTS/Debug-iphonesimulator/$name.framework.dSYM" \
        -output "$BUNDLE/XCFrameworks/$name.xcframework"
done

cp scripts/integrate-insidejob.sh "$BUNDLE/Scripts/"
cp docs/PREBUILT-IOS.md "$BUNDLE/README.md"
mkdir -p "$BUNDLE/Licenses"
cp LICENSE "$BUNDLE/Licenses/ButtonHeist.txt"
cp Tuist/.build/checkouts/AccessibilitySnapshotBH/LICENSE "$BUNDLE/Licenses/AccessibilitySnapshotBH.txt"
cp Tuist/.build/checkouts/AccessibilitySnapshotBH/NOTICE.txt "$BUNDLE/Licenses/AccessibilitySnapshotBH-NOTICE.txt"
printf '%s\n' "$VERSION" > "$BUNDLE/VERSION"
xcodebuild -version > "$BUNDLE/XCODE_VERSION"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ARCHIVE"
echo "Packaged $ARCHIVE"
