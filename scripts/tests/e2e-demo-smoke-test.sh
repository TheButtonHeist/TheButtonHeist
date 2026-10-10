#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_ROOT="$(mktemp -d)"
FIXTURE_REPO="$FIXTURE_ROOT/repo"
FAKE_BIN="$FIXTURE_ROOT/bin"
GIT_LOG="$FIXTURE_ROOT/git.log"
HARNESS="$FIXTURE_REPO/scripts/e2e-demo-smoke.py"

trap 'rm -rf "$FIXTURE_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$FIXTURE_REPO/scripts" "$FAKE_BIN"
cp "$REPO_ROOT/scripts/e2e-demo-smoke.py" "$HARNESS"
cp "$REPO_ROOT/scripts/e2e_runtime.py" "$FIXTURE_REPO/scripts/e2e_runtime.py"

cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
exit 97
EOF

cat > "$FAKE_BIN/nc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

for tool in xcrun xcodebuild swift; do
    cat > "$FAKE_BIN/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
chmod +x "$FAKE_BIN"/*
: > "$GIT_LOG"

if grep -Fq 'git submodule update' "$HARNESS"; then
    fail "smoke harness initializes a submodule instead of consuming built artifacts"
fi

grep -Fq '"perform",' "$HARNESS" \
    || fail "smoke harness does not wait through the canonical perform command"
grep -Fq '"command": "action"' "$HARNESS" \
    || fail "smoke harness does not dispatch through the canonical action command"
if grep -Fq '"wait",' "$HARNESS" || grep -Fq '"command": "activate"' "$HARNESS"; then
    fail "smoke harness still uses a removed compatibility command"
fi

run_harness() {
    PATH="$FAKE_BIN:$PATH" \
    FAKE_GIT_LOG="$GIT_LOG" \
        "$HARNESS" \
        --skip-generate \
        --skip-cli-build \
        --skip-heist-playback \
        --sim-udid fixture-simulator \
        --port 24681 \
        "$@" 2>&1
}

set +e
output=$(run_harness --app "$FIXTURE_ROOT/prebuilt/BHDemo.app")
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "smoke harness accepted a missing prebuilt CLI: $output"
[[ "$output" == *"prebuilt ButtonHeistCLI binary not found"* ]] \
    || fail "missing prebuilt CLI lacked a useful diagnostic: $output"
[[ ! -s "$GIT_LOG" ]] || fail "smoke harness invoked git before validating prebuilt inputs"

mkdir -p "$FIXTURE_REPO/ButtonHeistCLI/.build/debug"
touch "$FIXTURE_REPO/ButtonHeistCLI/.build/debug/buttonheist"
chmod +x "$FIXTURE_REPO/ButtonHeistCLI/.build/debug/buttonheist"

missing_app="$FIXTURE_ROOT/missing/BHDemo.app"
set +e
output=$(run_harness --app "$missing_app")
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "smoke harness accepted a missing prebuilt app: $output"
[[ "$output" == *"built app not found at $missing_app"* ]] \
    || fail "missing prebuilt app lacked a useful diagnostic: $output"
[[ ! -s "$GIT_LOG" ]] || fail "smoke harness invoked git while consuming prebuilt inputs"

echo "PASS: smoke harness consumes prebuilt artifacts without initializing submodules"
