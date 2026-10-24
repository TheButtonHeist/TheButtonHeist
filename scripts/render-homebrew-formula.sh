#!/usr/bin/env bash
# Render both formula templates from one release version and its checksums.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/release-contract.sh
source "$SCRIPT_DIR/release-contract.sh"

if [[ $# != 5 ]]; then
    echo "Usage: $0 <version> <cli-sha256> <mcp-sha256> <insidejob-sha256> <output-directory>" >&2
    exit 2
fi

VERSION="$1"
CLI_SHA="$2"
MCP_SHA="$3"
INSIDEJOB_SHA="$4"
OUTPUT="$5"

RELEASE_VERSION_REGEX='^[0-9]+\.[0-9]+\.[0-9]+$'
SHA256_REGEX='^[0-9a-f]{64}$'
[[ "$VERSION" =~ $RELEASE_VERSION_REGEX ]] || { echo "Error: invalid release version: $VERSION" >&2; exit 1; }

validate_sha() {
    [[ "$2" =~ $SHA256_REGEX ]] || { echo "Error: $1 checksum must be a lowercase SHA-256 hex digest" >&2; exit 1; }
}
validate_sha CLI "$CLI_SHA"
validate_sha MCP "$MCP_SHA"
validate_sha TheInsideJob "$INSIDEJOB_SHA"

mkdir -p "$OUTPUT"
STAGING=$(mktemp -d "$OUTPUT/.formula.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

for formula in buttonheist theinsidejob; do
    case "$formula" in
        buttonheist) template="$BUTTONHEIST_FORMULA_TEMPLATE" ;;
        theinsidejob) template="$BUTTONHEIST_INSIDEJOB_FORMULA_TEMPLATE" ;;
    esac
    awk \
        -v formula="$formula" \
        -v version="$VERSION" \
        -v cli_sha="$CLI_SHA" \
        -v mcp_sha="$MCP_SHA" \
        -v insidejob_sha="$INSIDEJOB_SHA" \
        -v release_url="$(buttonheist_release_url "$VERSION")" \
        -v template_release_url="$(buttonheist_release_url '#{version}')" \
        -v cli_archive="$(buttonheist_cli_archive_name "$VERSION")" \
        -v mcp_archive="$(buttonheist_mcp_archive_name "$VERSION")" \
        -v insidejob_archive="$(buttonheist_insidejob_archive_name "$VERSION")" \
        -v cli_template_archive="$(buttonheist_cli_archive_name '#{version}')" \
        -v mcp_template_archive="$(buttonheist_mcp_archive_name '#{version}')" \
        -v insidejob_template_archive="$(buttonheist_insidejob_archive_name '#{version}')" '
        function fail(message) {
            print "Error: " formula ": " message > "/dev/stderr"
            failed = 1
            exit 1
        }
        function url_kind(value, kind) {
            for (kind in expected) {
                if (expected[kind] && (value == urls[kind] || value == templates[kind])) {
                    return kind
                }
            }
            return ""
        }
        BEGIN {
            expected["cli"] = formula == "buttonheist"
            expected["mcp"] = formula == "buttonheist"
            expected["insidejob"] = formula == "theinsidejob"
            urls["cli"] = release_url "/" cli_archive
            urls["mcp"] = release_url "/" mcp_archive
            urls["insidejob"] = release_url "/" insidejob_archive
            templates["cli"] = template_release_url "/" cli_template_archive
            templates["mcp"] = template_release_url "/" mcp_template_archive
            templates["insidejob"] = template_release_url "/" insidejob_template_archive
            checksums["cli"] = cli_sha
            checksums["mcp"] = mcp_sha
            checksums["insidejob"] = insidejob_sha
        }
        /^[[:space:]]*version "[^"]+"/ {
            sub(/version "[^"]+"/, "version \"" version "\"")
            version_count++
        }
        /^[[:space:]]*url "[^"]+"/ {
            if (pending != "") {
                fail("missing checksum for " pending " URL")
            }
            value = $0
            sub(/^[[:space:]]*url "/, "", value)
            sub(/".*$/, "", value)
            pending = url_kind(value)
            if (pending == "") {
                fail("URL does not match the release contract: " value)
            }
            sub(/url "[^"]+"/, "url \"" urls[pending] "\"")
            url_count[pending]++
        }
        /^[[:space:]]*sha256 "[^"]+"/ {
            if (pending == "") {
                fail("checksum has no archive URL")
            }
            sub(/sha256 "[^"]+"/, "sha256 \"" checksums[pending] "\"")
            sha_count[pending]++
            pending = ""
        }
        { print }
        END {
            if (failed) {
                exit 1
            }
            if (version_count != 1 || pending != "") {
                fail("expected one version and a checksum for every URL")
            }
            for (kind in expected) {
                if (url_count[kind] + 0 != expected[kind] || sha_count[kind] + 0 != expected[kind]) {
                    fail("incorrect number of " kind " URLs or checksums")
                }
            }
        }
    ' "$REPO_ROOT/$template" > "$STAGING/$formula.rb"
done

mv "$STAGING/buttonheist.rb" "$STAGING/theinsidejob.rb" "$OUTPUT/"
