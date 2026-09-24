#!/usr/bin/env bash
# Shared release/install contract for release scripts and CI workflows.

# shellcheck disable=SC2034
BUTTONHEIST_GITHUB_REPO="TheButtonHeist/TheButtonHeist"
BUTTONHEIST_TAP_REPO="TheButtonHeist/homebrew-tap"

# TheScore owns the version. The release file and formula are checked mirrors.
BUTTONHEIST_CODE_VERSION_FILE="ButtonHeist/Sources/TheScore/Wire/Messages.swift"
BUTTONHEIST_RELEASE_VERSION_FILE="RELEASE_VERSION"
BUTTONHEIST_FORMULA_TEMPLATE="Formula/buttonheist.rb"
BUTTONHEIST_API_DOCS_FILE="docs/API.md"
BUTTONHEIST_DEMO_VERSION_FILE="TestApp/Sources/DisclosureGroupingDemo.swift"
BUTTONHEIST_PUBLIC_COMMAND_CONTRACT_FILE="tests/fixtures/public-cli-mcp-command-contract.json"

BUTTONHEIST_CLI_ARTIFACT_PREFIX="buttonheist"
BUTTONHEIST_MCP_ARTIFACT_PREFIX="buttonheist-mcp"
BUTTONHEIST_MACOS_ARTIFACT_SUFFIX="macos"
BUTTONHEIST_DEMO_ARTIFACT_PREFIX="bh-demo"
BUTTONHEIST_DEMO_ARTIFACT_SUFFIX="iphonesimulator"

buttonheist_code_version() {
    local versions
    local count

    versions="$(
        grep -E '^[[:space:]]*public let buttonHeistVersion: ButtonHeistVersion = "[^"]+"' \
            "$BUTTONHEIST_CODE_VERSION_FILE" \
            | sed -E 's/.*"([^"]+)".*/\1/' \
            || true
    )"
    count=$(printf '%s\n' "$versions" | sed '/^$/d' | wc -l | tr -d '[:space:]')
    if [[ "$count" != "1" ]]; then
        echo "Error: $BUTTONHEIST_CODE_VERSION_FILE must declare exactly one buttonHeistVersion" >&2
        return 1
    fi
    printf '%s' "$versions"
}

buttonheist_release_url() {
    local version="$1"
    printf 'https://github.com/%s/releases/download/v%s' "$BUTTONHEIST_GITHUB_REPO" "$version"
}

buttonheist_cli_archive_name() {
    local version="$1"
    printf '%s-%s-%s.tar.gz' \
        "$BUTTONHEIST_CLI_ARTIFACT_PREFIX" \
        "$version" \
        "$BUTTONHEIST_MACOS_ARTIFACT_SUFFIX"
}

buttonheist_mcp_archive_name() {
    local version="$1"
    printf '%s-%s-%s.tar.gz' \
        "$BUTTONHEIST_MCP_ARTIFACT_PREFIX" \
        "$version" \
        "$BUTTONHEIST_MACOS_ARTIFACT_SUFFIX"
}

buttonheist_demo_archive_name() {
    local version="$1"
    printf '%s-%s-%s.zip' \
        "$BUTTONHEIST_DEMO_ARTIFACT_PREFIX" \
        "$version" \
        "$BUTTONHEIST_DEMO_ARTIFACT_SUFFIX"
}
