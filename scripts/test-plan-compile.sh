#!/usr/bin/env bash
# Smoke test the buttonheist plan compiler outside SwiftPM's test runner.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUTTONHEIST_TOOL="${BUTTONHEIST_TOOL:-$REPO_ROOT/ButtonHeistCLI/.build/debug/buttonheist}"
if [[ ! -x "$BUTTONHEIST_TOOL" ]]; then
    echo "Error: buttonheist executable not found at $BUTTONHEIST_TOOL" >&2
    exit 1
fi
HEIST_THEPLANS_BUILD_DIR="${HEIST_THEPLANS_BUILD_DIR:-$REPO_ROOT/.build/debug}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plan-compile.XXXXXX")"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SOURCE="$TMP_DIR/Plan.swift"
OUTPUT="$TMP_DIR/compiled.heist"
RENDERED="$TMP_DIR/rendered.swift"
EXPECTED="$TMP_DIR/expected.swift"
EXAMPLE_OUTPUT="$TMP_DIR/example.heist"

cat > "$SOURCE" <<'SWIFT'
import ThePlans

func makeHeist() throws -> HeistPlan {
    try HeistPlan("compiled") {
        Warn("from Swift")
    }
}
SWIFT

cat > "$EXPECTED" <<'SWIFT'
HeistPlan("compiled") {
    Warn("from Swift")
}
SWIFT

echo "Compiling Swift fixture with buttonheist plan"
HEIST_SWIFT_COMPILATION_TRACE=1 HEIST_THEPLANS_BUILD_DIR="$HEIST_THEPLANS_BUILD_DIR" \
    "$BUTTONHEIST_TOOL" plan compile "$SOURCE" --entry makeHeist --output "$OUTPUT"
[[ -d "$OUTPUT" ]] || {
    echo "Error: compile did not produce a .heist package directory" >&2
    exit 1
}
[[ -f "$OUTPUT/manifest.json" ]] || {
    echo "Error: compile output is missing manifest.json" >&2
    exit 1
}
[[ -f "$OUTPUT/plan.json" ]] || {
    echo "Error: compile output is missing plan.json" >&2
    exit 1
}

echo "Validating compiled heist package passes runtime validation"
"$BUTTONHEIST_TOOL" plan validate "$OUTPUT"
echo "Rendering compiled heist package as canonical Swift"
"$BUTTONHEIST_TOOL" plan render-swift "$OUTPUT" > "$RENDERED"
diff -u "$EXPECTED" "$RENDERED"

echo "Compiling checked-in public example with buttonheist plan"
HEIST_SWIFT_COMPILATION_TRACE=1 HEIST_THEPLANS_BUILD_DIR="$HEIST_THEPLANS_BUILD_DIR" \
    "$BUTTONHEIST_TOOL" plan compile examples/heist-program.swift --output "$EXAMPLE_OUTPUT"
"$BUTTONHEIST_TOOL" plan validate "$EXAMPLE_OUTPUT"

echo "Compiling Swift fixture through installed-prefix artifacts"
INSTALLED_PREFIX="$TMP_DIR/installed-prefix"
INSTALLED_TOOL="$INSTALLED_PREFIX/bin/buttonheist"
INSTALLED_OUTPUT="$TMP_DIR/installed.heist"
INTERFACE_BUILD_DIR="$TMP_DIR/interface-build"
INTERFACE_ARTIFACT_DIR="$INTERFACE_BUILD_DIR/arm64-apple-macosx/release"
swift build -c release --arch arm64 --target ThePlans \
    -Xswiftc -enable-library-evolution \
    -Xswiftc -emit-module-interface \
    --scratch-path "$INTERFACE_BUILD_DIR"
mkdir -p "$INSTALLED_PREFIX/bin" "$INSTALLED_PREFIX/lib/ThePlans/arm64-apple-macosx/release"
cp "$BUTTONHEIST_TOOL" "$INSTALLED_TOOL"
mkdir -p "$INSTALLED_PREFIX/lib/ThePlans/arm64-apple-macosx/release/Modules"
cp -R "$INTERFACE_ARTIFACT_DIR/ThePlans.build" \
    "$INSTALLED_PREFIX/lib/ThePlans/arm64-apple-macosx/release/"
cp \
    "$INTERFACE_ARTIFACT_DIR/ThePlans.build/ThePlans.swiftinterface" \
    "$INTERFACE_ARTIFACT_DIR/ThePlans.build/ThePlans.private.swiftinterface" \
    "$INSTALLED_PREFIX/lib/ThePlans/arm64-apple-macosx/release/Modules/"
cp "$INTERFACE_ARTIFACT_DIR/description.json" \
    "$INSTALLED_PREFIX/lib/ThePlans/arm64-apple-macosx/release/"
if [[ -f "$INSTALLED_PREFIX/lib/ThePlans/arm64-apple-macosx/release/Modules/ThePlans.swiftmodule" ]]; then
    echo "Error: installed-prefix smoke test must not rely on binary ThePlans.swiftmodule" >&2
    exit 1
fi
(
    unset HEIST_THEPLANS_BUILD_DIR
    HEIST_SWIFT_COMPILATION_TRACE=1 "$INSTALLED_TOOL" plan compile "$SOURCE" --entry makeHeist --output "$INSTALLED_OUTPUT"
)
"$INSTALLED_TOOL" plan validate "$INSTALLED_OUTPUT"

# Negative: a missing build directory override must fail with an actionable
# diagnostic that names what was searched and how to fix it. This guards the
# single-resolution contract — there is no hidden fallback to building ThePlans
# from source or to JSON.
echo "Verifying missing-artifact diagnostic"
MISSING_OUTPUT="$TMP_DIR/missing.heist"
set +e
DIAGNOSTIC="$(HEIST_THEPLANS_BUILD_DIR="$TMP_DIR/does-not-exist" \
    "$BUTTONHEIST_TOOL" plan compile "$SOURCE" --entry makeHeist --output "$MISSING_OUTPUT" 2>&1)"
STATUS=$?
set -e
if [[ "$STATUS" -eq 0 ]]; then
    echo "Error: compile unexpectedly succeeded with a missing build directory" >&2
    exit 1
fi
for fragment in "searched:" "HEIST_THEPLANS_BUILD_DIR" "swift build --target ThePlans"; do
    if [[ "$DIAGNOSTIC" != *"$fragment"* ]]; then
        echo "Error: missing-artifact diagnostic did not mention '$fragment'" >&2
        echo "--- diagnostic ---" >&2
        echo "$DIAGNOSTIC" >&2
        exit 1
    fi
done
