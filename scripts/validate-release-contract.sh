#!/usr/bin/env bash
# Validate release/install contract drift without publishing a release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/release-contract.sh
source "$SCRIPT_DIR/release-contract.sh"

fail() {
    echo "Error: $*"
    exit 1
}

SEMVER_REGEX='^[0-9]+\.[0-9]+\.[0-9]+$'
SEMVER_GREP='[0-9]+\.[0-9]+\.[0-9]+'

extract_formula_version() {
    grep -E '^[[:space:]]*version "[^"]+"' "$BUTTONHEIST_FORMULA_TEMPLATE" \
        | sed -E 's/.*"([^"]+)".*/\1/'
}

CANONICAL_VERSION=$(buttonheist_code_version)
FORMULA_TEMPLATE_VERSION=$(extract_formula_version || true)
FORMULA_VERSION_COUNT=$(printf '%s\n' "$FORMULA_TEMPLATE_VERSION" | sed '/^$/d' | wc -l | tr -d '[:space:]')

[[ "$CANONICAL_VERSION" =~ $SEMVER_REGEX ]] || fail "$BUTTONHEIST_CODE_VERSION_FILE ($CANONICAL_VERSION) is not MAJOR.MINOR.PATCH"
[[ "$FORMULA_VERSION_COUNT" == "1" ]] \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE must contain exactly one version placeholder, found $FORMULA_VERSION_COUNT"
[[ "$FORMULA_TEMPLATE_VERSION" == "$BUTTONHEIST_FORMULA_VERSION_PLACEHOLDER" ]] \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE version must be $BUTTONHEIST_FORMULA_VERSION_PLACEHOLDER, found $FORMULA_TEMPLATE_VERSION"

if grep -Fq "$CANONICAL_VERSION" "$BUTTONHEIST_API_DOCS_FILE"; then
    fail "$BUTTONHEIST_API_DOCS_FILE must not duplicate release version $CANONICAL_VERSION"
fi
if grep -Eq "$SEMVER_GREP" "$BUTTONHEIST_API_DOCS_FILE"; then
    fail "$BUTTONHEIST_API_DOCS_FILE must use placeholders instead of concrete release versions"
fi

if awk '
    /^## CLI Reference$/ { in_cli = 1; next }
    in_cli && /^## / { in_cli = 0 }
    in_cli && /^\*\*Version\*\*:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$/ { found = 1 }
    END { exit found ? 0 : 1 }
' "$BUTTONHEIST_API_DOCS_FILE"; then
    fail "$BUTTONHEIST_API_DOCS_FILE must not duplicate the CLI release version"
fi

if grep -Fq "$CANONICAL_VERSION" "$BUTTONHEIST_DEMO_VERSION_FILE"; then
    fail "$BUTTONHEIST_DEMO_VERSION_FILE must not duplicate release version $CANONICAL_VERSION"
fi

if grep -Eq "\"$SEMVER_GREP\"" "$BUTTONHEIST_DEMO_VERSION_FILE"; then
    fail "$BUTTONHEIST_DEMO_VERSION_FILE must use buttonHeistVersion instead of a hardcoded release version"
fi

[[ -s "$BUTTONHEIST_PUBLIC_COMMAND_CONTRACT_FILE" ]] \
    || fail "$BUTTONHEIST_PUBLIC_COMMAND_CONTRACT_FILE must contain the generated public CLI/MCP command contract"
git ls-files --error-unmatch "$BUTTONHEIST_PUBLIC_COMMAND_CONTRACT_FILE" >/dev/null 2>&1 \
    || fail "$BUTTONHEIST_PUBLIC_COMMAND_CONTRACT_FILE must be committed"

if grep -Eq 'LabeledContent\([[:space:]]*"Version"' "$BUTTONHEIST_DEMO_VERSION_FILE"; then
    grep -Eq 'LabeledContent\([[:space:]]*"Version"[[:space:]]*,[[:space:]]*value:[[:space:]]*(TheScore\.)?buttonHeistVersion\.description[[:space:]]*\)' "$BUTTONHEIST_DEMO_VERSION_FILE" \
        || fail "$BUTTONHEIST_DEMO_VERSION_FILE must source Version from TheScore.buttonHeistVersion or remove the Version row"
fi

RAW_HEIST_FILES=$(git ls-files '*.heist' || true)
if [[ -n "$RAW_HEIST_FILES" ]]; then
    fail "tracked .heist paths must be generated package directories, not raw files: $RAW_HEIST_FILES"
fi

HEIST_PACKAGE_DIRS=$(git ls-files | sed -n 's#^\(.*\.heist\)/.*#\1#p' | sort -u)
while IFS= read -r package; do
    [[ -z "$package" ]] && continue
    [[ -d "$package" ]] || fail "$package must be a .heist package directory"
    [[ -f "$package/manifest.json" ]] || fail "$package is missing manifest.json"
    [[ -f "$package/plan.json" ]] || fail "$package is missing plan.json"
done <<< "$HEIST_PACKAGE_DIRS"

EXPECTED_HOMEPAGE="homepage \"https://github.com/$BUTTONHEIST_GITHUB_REPO\""
grep -Fq "$EXPECTED_HOMEPAGE" "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE homepage does not match $BUTTONHEIST_GITHUB_REPO"

CLI_TEMPLATE_PATH="$(buttonheist_cli_archive_name '#{version}')"
MCP_TEMPLATE_PATH="$(buttonheist_mcp_archive_name '#{version}')"
EXPECTED_RELEASE_URL="https://github.com/$BUTTONHEIST_GITHUB_REPO/releases/download/v#{version}"

grep -Fq "$EXPECTED_RELEASE_URL/$CLI_TEMPLATE_PATH" "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE CLI URL does not match release contract"
grep -Fq "$EXPECTED_RELEASE_URL/$MCP_TEMPLATE_PATH" "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE MCP URL does not match release contract"
grep -Fq 'bin.install "heist-plan"' "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE must install the heist-plan compiler"
grep -Fq 'bin.install "buttonheist-mcp"' "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE must install the MCP server"
grep -Fq 'assert_predicate bin/"buttonheist-mcp", :executable?' "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE test must assert installed buttonheist-mcp is executable"
if grep -Eq 'bin\.install[[:space:]]+"ButtonHeistFrameworks"' "$BUTTONHEIST_FORMULA_TEMPLATE"; then
    fail "$BUTTONHEIST_FORMULA_TEMPLATE must not install ambiguous ButtonHeistFrameworks"
fi
if grep -Fq 'ButtonHeistFrameworks' .github/workflows/release.yml; then
    fail ".github/workflows/release.yml must not package ambiguous ButtonHeistFrameworks"
fi
grep -Fq 'lib.install "ThePlans"' "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE must install ThePlans compiler artifacts under lib"
grep -Fq 'depends_on arch: :arm64' "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE must declare Button Heist Homebrew artifacts as arm64-only"
grep -Fq 'ThePlans/arm64-apple-macosx/release/Modules/ThePlans.swiftinterface' "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE test must assert installed arm64 ThePlans artifacts"
grep -Fq 'refute_predicate lib/"ThePlans/arm64-apple-macosx/release/Modules/ThePlans.swiftmodule"' "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE test must reject installed binary ThePlans.swiftmodule"
grep -Fq 'ThePlans/arm64-apple-macosx/release/description.json' "$BUTTONHEIST_FORMULA_TEMPLATE" \
    || fail "$BUTTONHEIST_FORMULA_TEMPLATE test must assert installed ThePlans description.json"

"$SCRIPT_DIR/check-parser-contract.sh"

TMP_FORMULA=$(mktemp)
trap 'rm -f "$TMP_FORMULA"' EXIT

DUMMY_CLI_SHA="1111111111111111111111111111111111111111111111111111111111111111"
DUMMY_MCP_SHA="2222222222222222222222222222222222222222222222222222222222222222"

"$SCRIPT_DIR/render-homebrew-formula.sh" "$CANONICAL_VERSION" "$DUMMY_CLI_SHA" "$DUMMY_MCP_SHA" "$TMP_FORMULA"

assert_rendered_url_checksum_pair() {
    local label="$1"
    local expected_url="$2"
    local expected_sha="$3"

    awk -v label="$label" -v expected_url="$expected_url" -v expected_sha="$expected_sha" '
        /^[[:space:]]*url "[^"]+"/ {
            if (pending) {
                print "Error: rendered formula is missing sha256 bound to " label " URL" > "/dev/stderr"
                failed = 1
                exit 1
            }
            url_value = $0
            sub(/^[[:space:]]*url "/, "", url_value)
            sub(/".*$/, "", url_value)
            pending = (url_value == expected_url)
            saw_url = saw_url || pending
            next
        }
        pending && /^[[:space:]]*sha256 "[^"]+"/ {
            sha_value = $0
            sub(/^[[:space:]]*sha256 "/, "", sha_value)
            sub(/".*$/, "", sha_value)
            if (sha_value != expected_sha) {
                print "Error: rendered formula binds " label " URL to sha256 " sha_value ", expected " expected_sha > "/dev/stderr"
                failed = 1
                exit 1
            }
            found = 1
            pending = 0
        }
        END {
            if (failed) {
                exit 1
            }
            if (!saw_url) {
                print "Error: rendered formula is missing " label " URL" > "/dev/stderr"
                exit 1
            }
            if (!found) {
                print "Error: rendered formula is missing sha256 bound to " label " URL" > "/dev/stderr"
                exit 1
            }
        }
    ' "$TMP_FORMULA" || fail "rendered formula does not bind $label checksum to matching URL"
}

grep -Fq "version \"$CANONICAL_VERSION\"" "$TMP_FORMULA" \
    || fail "rendered formula version does not match $CANONICAL_VERSION"
grep -Fq "url \"$(buttonheist_release_url "$CANONICAL_VERSION")/$(buttonheist_cli_archive_name "$CANONICAL_VERSION")\"" "$TMP_FORMULA" \
    || fail "rendered formula is missing concrete CLI URL"
grep -Fq "url \"$(buttonheist_release_url "$CANONICAL_VERSION")/$(buttonheist_mcp_archive_name "$CANONICAL_VERSION")\"" "$TMP_FORMULA" \
    || fail "rendered formula is missing concrete MCP URL"
grep -Fq "sha256 \"$DUMMY_CLI_SHA\"" "$TMP_FORMULA" \
    || fail "rendered formula is missing CLI checksum"
grep -Fq "sha256 \"$DUMMY_MCP_SHA\"" "$TMP_FORMULA" \
    || fail "rendered formula is missing MCP checksum"
assert_rendered_url_checksum_pair "CLI" "$(buttonheist_release_url "$CANONICAL_VERSION")/$(buttonheist_cli_archive_name "$CANONICAL_VERSION")" "$DUMMY_CLI_SHA"
assert_rendered_url_checksum_pair "MCP" "$(buttonheist_release_url "$CANONICAL_VERSION")/$(buttonheist_mcp_archive_name "$CANONICAL_VERSION")" "$DUMMY_MCP_SHA"
if grep -Fq 'PLACEHOLDER' "$TMP_FORMULA"; then
    fail "rendered formula still contains checksum placeholder"
fi
