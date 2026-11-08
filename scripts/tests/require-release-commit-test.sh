#!/usr/bin/env bash
# GitHub job metadata remains usable after diagnostic artifacts expire.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../require-release-commit.sh"
COMMIT=0123456789abcdef0123456789abcdef01234567
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
cat > "$TMP_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "run list" ]]; then
    printf '%s\n' "$GH_RUNS_JSON"
elif [[ "$1" == api ]]; then
    case "$2" in
        */commits/*) [[ "${GH_SIGNATURE_API_OK:-true}" == true ]] || exit 1; echo "$GH_VERIFICATION_JSON" ;;
        */attempts/*/jobs) [[ "${GH_JOBS_API_OK:-true}" == true ]] || exit 1; echo "$GH_JOBS_JSON" ;;
        */actions/runs/41) [[ "${GH_RUN_API_OK:-true}" == true ]] || exit 1; echo "$GH_RUN_JSON" ;;
        *) exit 64 ;;
    esac
else
    echo "unexpected gh invocation: $*" >&2
    exit 64
fi
EOF
chmod +x "$TMP_DIR/gh"
export PATH="$TMP_DIR:$PATH"
GH_VERIFICATION_JSON=$(jq -cn --arg sha "$COMMIT" '{sha:$sha,commit:{verification:{verified:true,reason:"valid"}}}')
GH_RUNS_JSON=$(jq -cn --arg sha "$COMMIT" '[{databaseId:41,event:"push",headSha:$sha,status:"completed",conclusion:"success"}]')
GH_RUN_JSON=$(jq -cn --arg sha "$COMMIT" '{id:41,head_sha:$sha,head_branch:"main",event:"push",path:".github/workflows/ci.yml",status:"completed",conclusion:"success",run_attempt:2}')
GH_JOBS_JSON=$(jq -cn -L "$SCRIPT_DIR/.." 'include "release-suites";
    [{jobs: [(required_release_suites + ["exact-sha-suite"])[] | {name:.,status:"completed",conclusion:"success"}]}]')
export GH_VERIFICATION_JSON GH_RUNS_JSON GH_RUN_JSON GH_JOBS_JSON

expect_success() {
    if ! bash "$GUARD" --timeout 0 "$COMMIT" > "$TMP_DIR/output" 2>&1; then
        echo "FAIL: $1" >&2; cat "$TMP_DIR/output" >&2; exit 1
    fi
}
expect_failure() {
    if bash "$GUARD" --timeout 0 "$COMMIT" > "$TMP_DIR/output" 2>&1; then
        echo "FAIL: unexpectedly admitted $1" >&2; exit 1
    fi
}

expect_success "signed main CI, current attempt and all required jobs, without downloading artifacts"
# A paginated response must include every page, including jobs after the first 100.
GH_JOBS_JSON=$(jq '[{jobs: .[0].jobs[:2]}, {jobs: .[0].jobs[2:]}]' <<< "$GH_JOBS_JSON")     expect_success "paginated jobs"
for reason in unsigned bad_email expired_key unknown_key; do
    GH_VERIFICATION_JSON=$(jq -cn --arg sha "$COMMIT" --arg reason "$reason"         '{sha:$sha,commit:{verification:{verified:false,reason:$reason}}}') expect_failure "signature $reason"
done
GH_VERIFICATION_JSON=$(jq '.sha = "wrong"' <<< "$GH_VERIFICATION_JSON") expect_failure "wrong signature SHA"
GH_SIGNATURE_API_OK=false expect_failure "signature API failure"
GH_RUN_API_OK=false expect_failure "run API failure"
GH_JOBS_API_OK=false expect_failure "jobs API failure"
for field in head_sha head_branch event path id run_attempt; do
    GH_RUN_JSON=$(jq --arg field "$field" '.[$field] = "wrong"' <<< "$GH_RUN_JSON") expect_failure "wrong $field"
done
for status in queued in_progress waiting; do
    GH_RUN_JSON=$(jq --arg value "$status" '.status = $value' <<< "$GH_RUN_JSON") expect_failure "run $status"
    GH_JOBS_JSON=$(jq --arg value "$status" '.[0].jobs[0].status = $value' <<< "$GH_JOBS_JSON") expect_failure "job $status"
done
for conclusion in failure cancelled timed_out skipped null; do
    GH_JOBS_JSON=$(jq --arg value "$conclusion" '.[0].jobs[0].conclusion = (if $value == "null" then null else $value end)' <<< "$GH_JOBS_JSON")         expect_failure "job $conclusion"
done
for name in release-contract macos-tests ios-logic ios-hosted ios-integration exact-sha-suite; do
    GH_JOBS_JSON=$(jq --arg name "$name" '.[0].jobs |= map(select(.name != $name))' <<< "$GH_JOBS_JSON")         expect_failure "missing $name"
    GH_JOBS_JSON=$(jq --arg name "$name" '.[0].jobs += [.[0].jobs[] | select(.name == $name)]' <<< "$GH_JOBS_JSON")         expect_failure "duplicate $name"
done
GH_RUNS_JSON=$(jq '.[0].headSha = "wrong"' <<< "$GH_RUNS_JSON") expect_failure "wrong run SHA"
GH_RUNS_JSON=$(jq '.[0].event = "pull_request"' <<< "$GH_RUNS_JSON") expect_failure "PR run"
GH_RUNS_JSON='[]' expect_failure "missing CI"
echo "PASS: release admission verifies the signed SHA and current main CI jobs without expiring artifacts"
