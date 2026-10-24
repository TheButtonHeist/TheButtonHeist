#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/TheInsideJob/Scripts" "$FIXTURE/TheInsideJob/XCFrameworks/TheInsideJob.xcframework"
mkdir -p "$FIXTURE/TheInsideJob/Resources/iphoneos/Parser.bundle"
mkdir -p "$FIXTURE/TheInsideJob/Resources/iphonesimulator/Parser.bundle"
cp "$REPO_ROOT/scripts/integrate-insidejob.sh" "$FIXTURE/TheInsideJob/Scripts/"
echo device > "$FIXTURE/TheInsideJob/Resources/iphoneos/Parser.bundle/platform"
echo simulator > "$FIXTURE/TheInsideJob/Resources/iphonesimulator/Parser.bundle/platform"

integrate() {
    CONFIGURATION="$1" PLATFORM_NAME="$2" \
    TARGET_BUILD_DIR="$FIXTURE/Build" \
    FRAMEWORKS_FOLDER_PATH="Consumer.app/Frameworks" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH="Consumer.app" \
        bash "$FIXTURE/TheInsideJob/Scripts/integrate-insidejob.sh"
}

for platform in iphoneos iphonesimulator; do
    mkdir -p "$FIXTURE/Build/Consumer.app/Frameworks/TheInsideJob.framework"
    integrate Debug "$platform"
    [[ -d "$FIXTURE/Build/Consumer.app/Frameworks/TheInsideJob.framework" ]]
    case "$platform" in
        iphoneos) expected=device ;;
        iphonesimulator) expected=simulator ;;
    esac
    [[ "$(cat "$FIXTURE/Build/Consumer.app/Parser.bundle/platform")" == "$expected" ]]
done

for configuration in Release Staging; do
    mkdir -p "$FIXTURE/Build/Consumer.app/Frameworks/TheInsideJob.framework"
    mkdir -p "$FIXTURE/Build/Consumer.app/Frameworks/Unrelated.framework"
    integrate "$configuration" iphoneos
    [[ ! -e "$FIXTURE/Build/Consumer.app/Frameworks/TheInsideJob.framework" ]]
    [[ ! -e "$FIXTURE/Build/Consumer.app/Parser.bundle" ]]
    [[ -d "$FIXTURE/Build/Consumer.app/Frameworks/Unrelated.framework" ]]
done

if integrate Debug macosx; then
    echo "FAIL: unsupported platform was accepted" >&2
    exit 1
fi

rm -rf "$FIXTURE/TheInsideJob/Resources"
integrate Debug iphonesimulator
echo "PASS: Debug embeds resources; every other configuration excludes the runtime"
