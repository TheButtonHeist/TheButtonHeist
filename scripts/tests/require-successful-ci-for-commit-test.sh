#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/require-successful-ci-for-commit.sh"
COMMIT="0123456789abcdef0123456789abcdef01234567"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == "run list" ]]; then
    printf '%s\n' "$GH_RUNS_JSON"
    exit 0
fi
if [[ "${1:-} ${2:-}" == "run view" ]]; then
    printf '%s\n' "$GH_JOBS_JSON"
    exit 0
fi
if [[ "${1:-} ${2:-}" == "run download" ]]; then
    destination=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--dir" ]]; then
            destination="${2:-}"
            break
        fi
        shift
    done
    [[ -n "$destination" ]]
    mkdir -p "$destination"
    printf '%s\n' "$GH_MANIFEST_JSON" > "$destination/exact-sha-suite.json"
    exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 2
EOF
chmod +x "$TMP_DIR/gh"

run_guard() {
    GH_RUNS_JSON="$1" GH_JOBS_JSON="$2" PATH="$TMP_DIR:$PATH" \
        GH_MANIFEST_JSON="$3" \
        bash "$GUARD" --repo TheButtonHeist/TheButtonHeist --timeout 0 "$COMMIT" test-commit
}

expect_success() {
    local label="$1"
    local runs="$2"
    local jobs="$3"
    local manifest="$4"
    if ! run_guard "$runs" "$jobs" "$manifest" > "$TMP_DIR/output" 2>&1; then
        echo "FAIL: expected success for $label" >&2
        cat "$TMP_DIR/output" >&2
        exit 1
    fi
}

expect_failure() {
    local label="$1"
    local runs="$2"
    local jobs="$3"
    local manifest="$4"
    local expected_output="${5:-}"
    if run_guard "$runs" "$jobs" "$manifest" > "$TMP_DIR/output" 2>&1; then
        echo "FAIL: expected failure for $label" >&2
        cat "$TMP_DIR/output" >&2
        exit 1
    fi
    if [[ -n "$expected_output" ]] && ! grep -Fq "$expected_output" "$TMP_DIR/output"; then
        echo "FAIL: missing diagnostic for $label: $expected_output" >&2
        cat "$TMP_DIR/output" >&2
        exit 1
    fi
}

successful_run=$(jq -cn --arg sha "$COMMIT" '[{
    databaseId: 41,
    event: "push",
    headSha: $sha,
    status: "completed",
    conclusion: "success"
}]')
successful_suite='{"jobs":[{"name":"exact-sha-suite","status":"completed","conclusion":"success"}]}'
successful_manifest=$(jq -cn --arg sha "$COMMIT" '{
    schemaVersion: 1,
    commit: $sha,
    workflow: {
        ref: "TheButtonHeist/TheButtonHeist/.github/workflows/ci.yml@refs/heads/main",
        sha: $sha,
        runId: "41",
        runAttempt: "1"
    },
    suites: [
        {name: "release-contract", conclusion: "success"},
        {name: "macos-tests", conclusion: "success"},
        {name: "ios-tests", conclusion: "success"},
        {name: "ios-demo-gates", conclusion: "success"},
        {name: "main-integration", conclusion: "success"}
    ]
}')

expect_success "complete exact-SHA aggregate" "$successful_run" "$successful_suite" "$successful_manifest"

for conclusion in failure cancelled timed_out action_required startup_failure stale; do
    rejected_manifest=$(jq -c --arg conclusion "$conclusion" \
        '.suites[0].conclusion = $conclusion' <<< "$successful_manifest")
    expect_failure \
        "required suite conclusion $conclusion" \
        "$successful_run" \
        "$successful_suite" \
        "$rejected_manifest"
done
skipped_manifest=$(jq -c '.suites[0].conclusion = "skipped"' <<< "$successful_manifest")
expect_failure \
    "required suite conclusion skipped" \
    "$successful_run" \
    "$successful_suite" \
    "$skipped_manifest" \
    "release-contract=skipped"
null_conclusion_manifest=$(jq -c '.suites[0].conclusion = null' <<< "$successful_manifest")
expect_failure \
    "required suite null conclusion" \
    "$successful_run" \
    "$successful_suite" \
    "$null_conclusion_manifest"

for status in queued pending requested waiting in_progress; do
    incomplete_run=$(jq -cn --arg sha "$COMMIT" --arg status "$status" '[{
        databaseId: 41,
        event: "push",
        headSha: $sha,
        status: $status,
        conclusion: "success"
    }]')
    expect_failure \
        "aggregate status $status" \
        "$incomplete_run" \
        "$successful_suite" \
        "$successful_manifest"
done

expect_failure \
    "missing aggregate" \
    "$successful_run" \
    '{"jobs":[{"name":"release-contract","status":"completed","conclusion":"success"}]}' \
    "$successful_manifest"
expect_failure \
    "skipped aggregate" \
    "$successful_run" \
    '{"jobs":[{"name":"exact-sha-suite","status":"completed","conclusion":"skipped"}]}' \
    "$successful_manifest"
expect_failure \
    "cancelled aggregate" \
    "$successful_run" \
    '{"jobs":[{"name":"exact-sha-suite","status":"completed","conclusion":"cancelled"}]}' \
    "$successful_manifest"

incomplete_manifest=$(jq -c 'del(.suites[-1])' <<< "$successful_manifest")
expect_failure "incomplete manifest" "$successful_run" "$successful_suite" "$incomplete_manifest"

duplicate_manifest=$(jq -c '.suites += [.suites[0]]' <<< "$successful_manifest")
expect_failure "duplicate suite" "$successful_run" "$successful_suite" "$duplicate_manifest"

optional_substitution_manifest=$(jq -c \
    'del(.suites[-1]) | .suites += [{name: "optional", conclusion: "success"}]' \
    <<< "$successful_manifest")
expect_failure \
    "optional suite substitution" \
    "$successful_run" \
    "$successful_suite" \
    "$optional_substitution_manifest"

wrong_manifest_sha=$(jq -c '.commit = "ffffffffffffffffffffffffffffffffffffffff"' <<< "$successful_manifest")
expect_failure "wrong manifest SHA" "$successful_run" "$successful_suite" "$wrong_manifest_sha"

wrong_workflow_sha=$(jq -c '.workflow.sha = "ffffffffffffffffffffffffffffffffffffffff"' <<< "$successful_manifest")
expect_failure "wrong workflow SHA" "$successful_run" "$successful_suite" "$wrong_workflow_sha"

wrong_workflow_ref=$(jq -c \
    '.workflow.ref = "TheButtonHeist/TheButtonHeist/.github/workflows/release.yml@refs/heads/main"' \
    <<< "$successful_manifest")
expect_failure "wrong workflow ref" "$successful_run" "$successful_suite" "$wrong_workflow_ref"

wrong_run_id=$(jq -c '.workflow.runId = "99"' <<< "$successful_manifest")
expect_failure "wrong run ID" "$successful_run" "$successful_suite" "$wrong_run_id"

wrong_sha_run=$(jq -cn '[{
    databaseId: 42,
    event: "push",
    headSha: "ffffffffffffffffffffffffffffffffffffffff",
    status: "completed",
    conclusion: "success"
}]')
expect_failure "wrong SHA" "$wrong_sha_run" "$successful_suite" "$successful_manifest"

pull_request_run=$(jq -cn --arg sha "$COMMIT" '[{
    databaseId: 43,
    event: "pull_request",
    headSha: $sha,
    status: "completed",
    conclusion: "success"
}]')
expect_failure "pull request result" "$pull_request_run" "$successful_suite" "$successful_manifest"

echo "PASS: release admission requires the successful exact-SHA aggregate"
