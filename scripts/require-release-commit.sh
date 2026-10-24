#!/usr/bin/env bash
# Require a verified signature and successful main CI for one exact release commit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/release-contract.sh
source "$SCRIPT_DIR/release-contract.sh"

REPOSITORY="$BUTTONHEIST_GITHUB_REPO"
TIMEOUT_SECONDS=0
POLL_SECONDS=15

usage() {
    cat <<'EOF'
Usage: scripts/require-release-commit.sh [options] COMMIT [LABEL]

Options:
  --repo OWNER/REPO  GitHub repository. Defaults to the release contract repo.
  --timeout SECONDS  Wait this long for CI. Defaults to an immediate check.
  --poll SECONDS     Poll interval while waiting. Defaults to 15 seconds.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPOSITORY="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
        --poll) POLL_SECONDS="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "Error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
done

COMMIT_SHA="${1:-}"
LABEL="${2:-release commit}"
if [[ -z "$COMMIT_SHA" || -z "$REPOSITORY" ]]; then
    usage >&2
    exit 2
fi
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ && "$POLL_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: timeout must be nonnegative and poll must be positive" >&2
    exit 2
fi

if ! gh api "repos/$REPOSITORY/commits/$COMMIT_SHA" \
    | jq -e --arg commit "$COMMIT_SHA" '
        .sha == $commit
        and .commit.verification.verified == true
        and .commit.verification.reason == "valid"
    ' >/dev/null; then
    echo "Error: $LABEL $COMMIT_SHA must have a GitHub-verified commit signature." >&2
    exit 1
fi

list_ci_runs() {
    gh run list \
        --repo "$REPOSITORY" \
        --workflow CI \
        --branch main \
        --commit "$COMMIT_SHA" \
        --limit 20 \
        --json conclusion,databaseId,event,headSha,status 2>/dev/null || echo '[]'
}

has_successful_exact_sha_suite() {
    local runs_json="$1"
    local expected_workflow_ref="$REPOSITORY/.github/workflows/ci.yml@refs/heads/main"
    local run_id
    while IFS= read -r run_id; do
        [[ -n "$run_id" ]] || continue
        local jobs_json
        jobs_json=$(gh run view "$run_id" --repo "$REPOSITORY" --json jobs 2>/dev/null || echo '{"jobs":[]}')
        if ! jq -e '
            [.jobs[] | select(
                .name == "exact-sha-suite"
                and .status == "completed"
                and .conclusion == "success"
            )] | length == 1
        ' <<< "$jobs_json" >/dev/null; then
            continue
        fi

        local manifest_directory
        manifest_directory=$(mktemp -d)
        if gh run download "$run_id" \
            --repo "$REPOSITORY" \
            --name buttonheist-exact-sha-suite \
            --dir "$manifest_directory" >/dev/null 2>&1 \
            && jq -e \
                --arg commit "$COMMIT_SHA" \
                --arg runId "$run_id" \
                --arg workflowRef "$expected_workflow_ref" \
                -f "$SCRIPT_DIR/exact-sha-suite.jq" \
                "$manifest_directory/exact-sha-suite.json" >/dev/null; then
            rm -rf "$manifest_directory"
            return 0
        fi
        rm -rf "$manifest_directory"
    done < <(jq -r --arg commit "$COMMIT_SHA" '
        .[]
        | select(
            .headSha == $commit
            and .event == "push"
            and .status == "completed"
            and .conclusion == "success"
        )
        | .databaseId
    ' <<< "$runs_json")
    return 1
}

print_ci_runs() {
    gh run list \
        --repo "$REPOSITORY" \
        --workflow CI \
        --branch main \
        --commit "$COMMIT_SHA" \
        --limit 20 || true
}

report_failure() {
    local message="$1"
    print_ci_runs
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        echo "::error::$message"
    else
        echo "Error: $message" >&2
    fi
}

deadline=$((SECONDS + TIMEOUT_SECONDS))
echo "Waiting for main CI on $LABEL (${COMMIT_SHA:0:8})..."
while true; do
    runs_json=$(list_ci_runs)
    if has_successful_exact_sha_suite "$runs_json"; then
        echo "Exact-SHA release suite verified green on commit ${COMMIT_SHA:0:8}"
        exit 0
    fi

    running_count=$(jq --arg commit "$COMMIT_SHA" \
        '[.[] | select(.headSha == $commit and .event == "push" and .status != "completed")] | length' \
        <<< "$runs_json")
    total_count=$(jq --arg commit "$COMMIT_SHA" \
        '[.[] | select(.headSha == $commit and .event == "push")] | length' \
        <<< "$runs_json")
    if [[ "$running_count" -eq 0 && "$total_count" -gt 0 ]]; then
        report_failure "No successful exact-SHA release suite found for $LABEL $COMMIT_SHA."
        exit 1
    fi

    if [[ "$TIMEOUT_SECONDS" -eq 0 || "$SECONDS" -ge "$deadline" ]]; then
        report_failure "No successful main-branch CI push run found for exact $LABEL $COMMIT_SHA."
        exit 1
    fi
    sleep "$POLL_SECONDS"
done
