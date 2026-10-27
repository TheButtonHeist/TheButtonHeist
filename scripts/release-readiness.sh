#!/usr/bin/env bash
# Local release-readiness preflight that composes the smallest release contract checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

run_step() {
    local label="$1"
    shift
    echo "==> $label"
    "$@"
    echo ""
}

run_step "Release contract and parser pin" "$SCRIPT_DIR/validate-release-contract.sh"
run_step "Homebrew formula rendering and upgrades" python3 "$SCRIPT_DIR/tests/render-homebrew-formula-test.py"
run_step "Release publication failures and retries" python3 "$SCRIPT_DIR/tests/publish-release-test.py"
run_step "Release preparation and admission" python3 "$SCRIPT_DIR/tests/release-test.py"
run_step "Release boundary regressions" python3 "$SCRIPT_DIR/tests/release-boundaries-test.py"
run_step "Signed exact-commit release gate" bash "$SCRIPT_DIR/tests/require-release-commit-test.sh"
run_step "Swift public API breakage" "$SCRIPT_DIR/check-swift-api-breaking-changes.sh"
run_step "Generate Xcode project" "$SCRIPT_DIR/generate-project.sh"
run_step "External ButtonHeist import fixture" "$SCRIPT_DIR/check-buttonheist-import-contract.sh"
run_step "Build ThePlans" swift build --target ThePlans
run_step "Build buttonheist" swift build --package-path ButtonHeistCLI
run_step "plan compile smoke" "$SCRIPT_DIR/test-plan-compile.sh"
run_step "Installed artifact smoke when available" "$SCRIPT_DIR/installed-artifact-smoke.sh"

echo "Release readiness checks passed."
