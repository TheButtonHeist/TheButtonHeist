#!/usr/bin/env bash
# Write a small manifest so recorded heist result bundles are discoverable.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/write-ci-heist-result-manifest.sh DEST_DIR [JOB_LABEL]

Creates DEST_DIR when needed and writes:
  manifest.txt       CI context and result counts
  result-files.txt   Result file list with byte counts, or "(none)"

The manifest is intentionally plain text so it remains useful from a browser,
terminal, or downloaded GitHub Actions artifact without extra tooling.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

DEST_DIR="${1:-}"
JOB_LABEL="${2:-${GITHUB_JOB:-unknown}}"

if [[ -z "$DEST_DIR" ]]; then
    usage >&2
    exit 2
fi

mkdir -p "$DEST_DIR"

MANIFEST="$DEST_DIR/manifest.txt"
FILE_LIST="$DEST_DIR/result-files.txt"
result_count=0
result_bytes=0

: > "$FILE_LIST"
while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    size="$(wc -c < "$file" | tr -d '[:space:]')"
    relative_path="${file#"$DEST_DIR"/}"
    printf '%s\t%s\n' "$size" "$relative_path" >> "$FILE_LIST"
    result_count=$((result_count + 1))
    result_bytes=$((result_bytes + size))
done < <(
    find "$DEST_DIR" \
        \( -path "$DEST_DIR/diagnostics" -o -path "$DEST_DIR/diagnostics/*" \) -prune -o \
        -type f \
        \( -name '*.json' -o -name '*.json.gz' \) \
        -print \
        | LC_ALL=C sort
)

if [[ "$result_count" -eq 0 ]]; then
    echo "(none)" > "$FILE_LIST"
fi

{
    echo "buttonheistResultArtifact=1"
    echo "job=$JOB_LABEL"
    echo "githubJob=${GITHUB_JOB:-}"
    echo "workflow=${GITHUB_WORKFLOW:-}"
    echo "runId=${GITHUB_RUN_ID:-}"
    echo "runAttempt=${GITHUB_RUN_ATTEMPT:-}"
    echo "event=${GITHUB_EVENT_NAME:-}"
    echo "ref=${GITHUB_REF:-}"
    echo "sha=${GITHUB_SHA:-}"
    echo "resultMode=${BUTTONHEIST_RESULTS_MODE:-}"
    echo "resultDirectory=$DEST_DIR"
    echo "resultFileCount=$result_count"
    echo "resultBytes=$result_bytes"
    echo "resultList=result-files.txt"
    if [[ -f "$DEST_DIR/collection-diagnostics.txt" ]]; then
        echo "collectionDiagnostics=collection-diagnostics.txt"
    fi
    if [[ -f "$DEST_DIR/demo-diagnostics.txt" ]]; then
        echo "demoDiagnostics=demo-diagnostics.txt"
    fi
    if [[ -d "$DEST_DIR/diagnostics" ]]; then
        echo "diagnosticsDirectory=diagnostics"
    fi
    echo "createdAt=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
} > "$MANIFEST"
