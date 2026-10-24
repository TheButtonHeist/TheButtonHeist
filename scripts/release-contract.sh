#!/usr/bin/env bash
# Shared release/install contract for release scripts and CI workflows.

# shellcheck disable=SC2034
BUTTONHEIST_GITHUB_REPO="TheButtonHeist/TheButtonHeist"
BUTTONHEIST_TAP_REPO="TheButtonHeist/homebrew-tap"
BUTTONHEIST_HOMEBREW_TAP="TheButtonHeist/tap"

# TheScore owns the version. Release tags must match it, while the checked-in
# Homebrew formula templates are rendered by the release job.
BUTTONHEIST_CODE_VERSION_FILE="ButtonHeist/Sources/TheScore/Wire/Messages.swift"
BUTTONHEIST_FORMULA_TEMPLATE="Formula/buttonheist.rb"
BUTTONHEIST_INSIDEJOB_FORMULA_TEMPLATE="Formula/theinsidejob.rb"
BUTTONHEIST_FORMULA_VERSION_PLACEHOLDER="RELEASE_VERSION"
BUTTONHEIST_API_DOCS_FILE="docs/API.md"
BUTTONHEIST_DEMO_VERSION_FILE="TestApp/Sources/DisclosureGroupingDemo.swift"
BUTTONHEIST_PUBLIC_COMMAND_CONTRACT_FILE="tests/fixtures/public-cli-mcp-command-contract.json"

BUTTONHEIST_CLI_ARTIFACT_PREFIX="buttonheist"
BUTTONHEIST_MCP_ARTIFACT_PREFIX="buttonheist-mcp"
BUTTONHEIST_MACOS_ARTIFACT_SUFFIX="macos"
BUTTONHEIST_DEMO_ARTIFACT_PREFIX="bh-demo"
BUTTONHEIST_DEMO_ARTIFACT_SUFFIX="iphonesimulator"
BUTTONHEIST_INSIDEJOB_ARTIFACT_PREFIX="theinsidejob"

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

buttonheist_insidejob_archive_name() {
    local version="$1"
    printf '%s-%s.zip' "$BUTTONHEIST_INSIDEJOB_ARTIFACT_PREFIX" "$version"
}

buttonheist_upgrade_installed_formulas() {
    local version="$1"
    command -v brew &>/dev/null || return 0
    local formula prefix installed_version
    local installed_formulas=()
    for formula in buttonheist theinsidejob; do
        formula="$BUTTONHEIST_HOMEBREW_TAP/$formula"
        if brew list --versions "$formula" &>/dev/null; then
            installed_formulas+=("$formula")
        fi
    done
    if [[ ${#installed_formulas[@]} -gt 0 ]]; then
        echo "  Upgrading installed Homebrew formulas..."
        brew update --quiet
        for formula in "${installed_formulas[@]}"; do
            brew upgrade "$formula"
            prefix="$(brew --prefix "$formula")"
            case "${formula##*/}" in
                buttonheist) installed_version="$("$prefix/bin/buttonheist" --version)" ;;
                theinsidejob) installed_version="$(cat "$prefix/libexec/TheInsideJob.xcframework/VERSION")" ;;
            esac
            if [[ "$installed_version" != "$version" ]]; then
                echo "Error: $formula reports '$installed_version', expected '$version'"
                return 1
            fi
            echo "  ✓ $formula upgraded to $installed_version"
        done
    fi
}
