#!/usr/bin/env bash
# Render the checked-in Homebrew formula template with release checksums.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/release-contract.sh
source "$SCRIPT_DIR/release-contract.sh"

usage() {
    echo "Usage: $0 <version> <cli-sha256> <mcp-sha256> [output]"
}

if [[ $# -lt 3 || $# -gt 4 ]]; then
    usage
    exit 2
fi

VERSION="$1"
CLI_SHA="$2"
MCP_SHA="$3"
OUTPUT="${4:-}"
TEMPLATE="$REPO_ROOT/$BUTTONHEIST_FORMULA_TEMPLATE"
CLI_URL="$(buttonheist_release_url "$VERSION")/$(buttonheist_cli_archive_name "$VERSION")"
MCP_URL="$(buttonheist_release_url "$VERSION")/$(buttonheist_mcp_archive_name "$VERSION")"
CLI_TEMPLATE_URL="$(buttonheist_release_url '#{version}')/$(buttonheist_cli_archive_name '#{version}')"
MCP_TEMPLATE_URL="$(buttonheist_release_url '#{version}')/$(buttonheist_mcp_archive_name '#{version}')"

RELEASE_VERSION_REGEX='^[0-9]+\.[0-9]+\.[0-9]+$'
SHA256_REGEX='^[0-9a-f]{64}$'

if ! [[ "$VERSION" =~ $RELEASE_VERSION_REGEX ]]; then
    echo "Error: '$VERSION' is not a valid release version (e.g. 0.2.0 or 1.0.0)"
    exit 1
fi
if ! [[ "$CLI_SHA" =~ $SHA256_REGEX ]]; then
    echo "Error: CLI checksum must be a lowercase SHA-256 hex digest"
    exit 1
fi
if ! [[ "$MCP_SHA" =~ $SHA256_REGEX ]]; then
    echo "Error: MCP checksum must be a lowercase SHA-256 hex digest"
    exit 1
fi
if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: formula template not found: $BUTTONHEIST_FORMULA_TEMPLATE"
    exit 1
fi

TMP_OUTPUT=$(mktemp)
trap 'rm -f "$TMP_OUTPUT"' EXIT

awk \
    -v version="$VERSION" \
    -v cli_sha="$CLI_SHA" \
    -v mcp_sha="$MCP_SHA" \
    -v cli_url="$CLI_URL" \
    -v mcp_url="$MCP_URL" \
    -v cli_template_url="$CLI_TEMPLATE_URL" \
    -v mcp_template_url="$MCP_TEMPLATE_URL" '
    function fail(message) {
        print "Error: " message > "/dev/stderr"
        failed = 1
        exit 1
    }
    function formula_url_value(line) {
        sub(/^[[:space:]]*url "/, "", line)
        sub(/".*$/, "", line)
        return line
    }
    function url_kind(url_value) {
        if (url_value == cli_template_url || url_value == cli_url) {
            return "cli"
        }
        if (url_value == mcp_template_url || url_value == mcp_url) {
            return "mcp"
        }
        return ""
    }
    BEGIN {
        version_count = 0
        cli_url_count = 0
        mcp_url_count = 0
        cli_sha_count = 0
        mcp_sha_count = 0
        pending_sha_kind = ""
        failed = 0
    }
    /^[[:space:]]*version "[^"]+"/ {
        sub(/version "[^"]+"/, "version \"" version "\"")
        version_count += 1
    }
    /^[[:space:]]*url "[^"]+"/ {
        if (pending_sha_kind != "") {
            fail("formula url appeared before sha256 for previous " pending_sha_kind " archive url")
        }
        current_url_kind = url_kind(formula_url_value($0))
        if (current_url_kind == "cli") {
            sub(/url "[^"]+"/, "url \"" cli_url "\"")
            cli_url_count += 1
        } else if (current_url_kind == "mcp") {
            sub(/url "[^"]+"/, "url \"" mcp_url "\"")
            mcp_url_count += 1
        } else {
            fail("formula url does not match release contract: " formula_url_value($0))
        }
        pending_sha_kind = current_url_kind
    }
    /^[[:space:]]*sha256 "[^"]+"/ {
        if (pending_sha_kind == "cli") {
            sub(/sha256 "[^"]+"/, "sha256 \"" cli_sha "\"")
            cli_sha_count += 1
        } else if (pending_sha_kind == "mcp") {
            sub(/sha256 "[^"]+"/, "sha256 \"" mcp_sha "\"")
            mcp_sha_count += 1
        } else {
            fail("formula sha256 is not bound to a known archive url")
        }
        pending_sha_kind = ""
    }
    { print }
    END {
        if (failed) {
            exit 1
        }
        if (pending_sha_kind != "") {
            print "Error: formula is missing sha256 for " pending_sha_kind " archive url" > "/dev/stderr"
            exit 1
        }
        if (version_count != 1) {
            print "Error: expected exactly one formula version line, found " version_count > "/dev/stderr"
            exit 1
        }
        if (cli_url_count != 1) {
            print "Error: expected exactly one CLI formula url line, found " cli_url_count > "/dev/stderr"
            exit 1
        }
        if (mcp_url_count != 1) {
            print "Error: expected exactly one MCP formula url line, found " mcp_url_count > "/dev/stderr"
            exit 1
        }
        if (cli_sha_count != 1) {
            print "Error: expected exactly one CLI formula sha256 line, found " cli_sha_count > "/dev/stderr"
            exit 1
        }
        if (mcp_sha_count != 1) {
            print "Error: expected exactly one MCP formula sha256 line, found " mcp_sha_count > "/dev/stderr"
            exit 1
        }
    }
' "$TEMPLATE" > "$TMP_OUTPUT"

if [[ -n "$OUTPUT" ]]; then
    mv "$TMP_OUTPUT" "$OUTPUT"
else
    cat "$TMP_OUTPUT"
fi
