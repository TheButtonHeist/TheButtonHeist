#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_ROOT="$(mktemp -d)"
FAKE_BIN="$FIXTURE_ROOT/bin"
OUTPUT=""
STATUS=0

trap 'rm -rf "$FIXTURE_ROOT"' EXIT
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/swift" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_SWIFT_ARGUMENTS"
echo "API breakage: fixture diagnostic from Swift"
exit "${FAKE_SWIFT_STATUS:-1}"
EOF
chmod +x "$FAKE_BIN/swift"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_gate() {
    local baseline="$1"
    local mode="$2"
    local swift_status="$3"

    set +e
    OUTPUT=$(
        PATH="$FAKE_BIN:$PATH" \
        FAKE_SWIFT_ARGUMENTS="$FIXTURE_ROOT/swift-arguments.txt" \
        FAKE_SWIFT_STATUS="$swift_status" \
        BUTTONHEIST_SWIFT_API_BASELINE_TAG="$baseline" \
        BUTTONHEIST_SWIFT_API_BREAKAGE_MODE="$mode" \
            "$REPO_ROOT/scripts/check-swift-api-breaking-changes.sh" 2>&1
    )
    STATUS=$?
    set -e
}

run_gate v0.6.38 strict 1
[[ "$STATUS" -eq 0 ]] || fail "scoped v0.6.38 baseline waiver failed: $OUTPUT"
[[ "$OUTPUT" == *"legacy connection/failure wrappers, duplicate public-JSON adapters and request metadata, permissive environment aliases, validation-error aliases, obsolete resolver overloads, and unused convenience declarations"* ]] \
    || fail "waiver did not name the intentional source changes: $OUTPUT"
[[ "$OUTPUT" == *"exemption expires"* ]] || fail "waiver did not explain its scope: $OUTPUT"

run_gate v0.6.37 strict 1
[[ "$STATUS" -eq 1 ]] || fail "expired baseline waiver accepted native breakage: $OUTPUT"

run_gate v0.6.38 report 1
[[ "$STATUS" -eq 0 ]] || fail "report mode rejected native diagnostics: $OUTPUT"

run_gate v0.6.38 strict 0
[[ "$STATUS" -eq 0 ]] || fail "clean native API result failed: $OUTPUT"

grep -Fq 'package diagnose-api-breaking-changes v0.6.38 --products' \
    "$FIXTURE_ROOT/swift-arguments.txt" \
    || fail "gate did not invoke Swift's native API diagnosis"

echo "PASS: Swift API gate uses native diagnostics with one tag-scoped waiver"
