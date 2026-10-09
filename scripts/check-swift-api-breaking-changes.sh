#!/usr/bin/env bash
# Check public Swift API compatibility against the latest release tag.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BASELINE_TAG="${BUTTONHEIST_SWIFT_API_BASELINE_TAG:-}"
if [[ -z "$BASELINE_TAG" ]]; then
    git fetch --quiet --force --tags origin +refs/heads/main:refs/remotes/origin/main
    BASELINE_TAG="$(git tag --merged origin/main --sort=-v:refname 'v*' | head -1 || true)"
fi

if [[ -z "$BASELINE_TAG" ]]; then
    echo "No release tag found on origin/main; skipping Swift API breakage check."
    exit 0
fi

MODE="${BUTTONHEIST_SWIFT_API_BREAKAGE_MODE:-strict}"
case "$MODE" in
    strict|report) ;;
    *)
        echo "Error: BUTTONHEIST_SWIFT_API_BREAKAGE_MODE must be 'strict' or 'report', got '$MODE'"
        exit 2
        ;;
esac

PUBLIC_PRODUCTS=()
while IFS= read -r product; do
    PUBLIC_PRODUCTS+=("$product")
done < <(grep -E '^[[:space:]]*[.]library[(]name:[[:space:]]*"[^"]+"' Package.swift \
    | sed -E 's/.*name:[[:space:]]*"([^"]+)".*/\1/')

if [[ "${#PUBLIC_PRODUCTS[@]}" -eq 0 ]]; then
    echo "Error: no Swift library products found in Package.swift."
    exit 2
fi

echo "Checking Swift API breakage against $BASELINE_TAG"
set +e
swift package diagnose-api-breaking-changes "$BASELINE_TAG" \
    --products "${PUBLIC_PRODUCTS[@]}"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    exit 0
fi

if [[ "$MODE" == "report" ]]; then
    echo "Swift API breakage reported in non-blocking mode."
    echo "Run with BUTTONHEIST_SWIFT_API_BREAKAGE_MODE=strict to fail on this diagnostic."
    exit 0
fi

# v0.6.38 includes intentional source removals that collapse connection
# targeting, diagnostic failure, JSON admission, and environment parsing onto
# their canonical types. This waiver is bound to that baseline and expires
# when v0.6.39 becomes the API baseline.
if [[ "$BASELINE_TAG" == "v0.6.38" ]]; then
    echo "Intentional source removals against $BASELINE_TAG: legacy connection/failure wrappers, duplicate public-JSON adapters and request metadata, permissive environment aliases, validation-error aliases, and obsolete resolver overloads."
    echo "The exemption expires when the next release tag becomes the API baseline."
    exit 0
fi

exit "$status"
