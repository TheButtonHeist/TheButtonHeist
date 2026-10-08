#!/usr/bin/env python3
"""Select expensive CI scopes from repository-relative changed paths."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Iterable
from pathlib import Path


PACKAGE_API = "run_package_api_contracts"
CLI_TOOLS = "run_cli_tool_tests"
BUMPER_RULE_TESTS = "run_bumper_rule_tests"
IOS_INTEGRATION = "run_ios_integration"
SCOPES = (PACKAGE_API, CLI_TOOLS, BUMPER_RULE_TESTS, IOS_INTEGRATION)

DOCUMENTATION_FILES = {
    "AGENTS.md",
    "CLAUDE.md",
    "LICENSE",
    "README.md",
    "SECURITY.md",
}
DOCUMENTATION_PREFIXES = ("docs/",)

BUMPER_RULE_PATHS = {
    "BumperBowling.swift",
    "docs/BUMPER-RULES.md",
    "scripts/check-source-shape.sh",
}
BUMPER_RULE_PREFIXES = (".bumper/",)

PACKAGE_CONTRACT_PATHS = {
    "Package.resolved",
    "Package.swift",
    "Project.swift",
    "scripts/check-buttonheist-import-contract.sh",
    "scripts/check-swift-api-breaking-changes.sh",
}
PACKAGE_CONTRACT_PREFIXES = (
    "ButtonHeist/Sources/",
    "submodules/AccessibilitySnapshotBH/",
    "tests/fixtures/buttonheist-external-import-contract/",
    "tests/fixtures/buttonheist-ios-public-products-import-contract/",
    "tests/fixtures/buttonheist-public-products-import-contract/",
    "tests/fixtures/theplans-authoring-import-contract/",
)

CLI_TOOL_PREFIXES = (
    "ButtonHeistCLI/",
    "ButtonHeistMCP/",
    "HeistPlanTests/",
    "examples/",
)
CLI_TOOL_PATHS = {
    "scripts/swift-test-gate.sh",
    "scripts/test-heist-plan-compile.sh",
}

# These paths are covered by the always-on lint/framework/iOS lanes. They do not
# affect the three optional macOS scopes selected by this script.
IOS_OR_FRAMEWORK_TEST_PREFIXES = (
    "ButtonHeist/Tests/",
    "TestApp/",
)
IOS_AUTOMATION_PATHS = {
    "scripts/check-e2e-adversarial-lab-timing.py",
    "scripts/collect-ios-heist-results.sh",
    "scripts/e2e-adversarial-lab.py",
    "scripts/e2e-demo-smoke.py",
    "scripts/e2e-lifecycle-gate.py",
    "scripts/e2e_runtime.py",
    "scripts/select-ios-ci-simulator.py",
    "scripts/tests/adversarial-nightly-workflow-test.py",
    "scripts/tests/e2e-lifecycle-gate-test.py",
    "scripts/tests/select-ios-ci-simulator-test.py",
}

IOS_INTEGRATION_PATHS = {
    ".github/workflows/ci.yml",
    "Project.swift",
    "Workspace.swift",
    "Tuist/Package.swift",
    "scripts/select-ios-ci-simulator.py",
    "scripts/test-runner.py",
}
IOS_INTEGRATION_PREFIXES = (
    "ButtonHeist/Sources/ButtonHeistSupport/",
    "ButtonHeist/Sources/ButtonHeistTesting/",
    "ButtonHeist/Sources/TheInsideJob/",
    "ButtonHeist/Sources/ThePlant/",
    "ButtonHeist/Sources/TheScore/",
    "ButtonHeist/Tests/TheInsideJobTests/Integration/",
    "ButtonHeist/Tests/TheInsideJobTests/Shared/Socket/",
    "TestApp/",
)


def normalize_path(path: str) -> str:
    """Normalize common git path spellings without accepting paths outside the repo."""
    normalized = path.strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def has_prefix(path: str, prefixes: tuple[str, ...]) -> bool:
    return any(path.startswith(prefix) for prefix in prefixes)


def matches(path: str, paths: set[str], prefixes: tuple[str, ...] = ()) -> bool:
    return path in paths or has_prefix(path, prefixes)


def is_documentation(path: str) -> bool:
    return (
        path in DOCUMENTATION_FILES
        or path.endswith("/README.md")
        or has_prefix(path, DOCUMENTATION_PREFIXES)
    )


def scopes_for_path(path: str) -> set[str]:
    """Return scopes affected by one path, failing open for unknown paths."""
    integration = (
        {IOS_INTEGRATION}
        if matches(path, IOS_INTEGRATION_PATHS, IOS_INTEGRATION_PREFIXES)
        else set()
    )
    if matches(path, BUMPER_RULE_PATHS, BUMPER_RULE_PREFIXES):
        return integration.union([BUMPER_RULE_TESTS])

    if is_documentation(path):
        return integration

    if matches(path, PACKAGE_CONTRACT_PATHS, PACKAGE_CONTRACT_PREFIXES):
        return integration.union([PACKAGE_API, CLI_TOOLS])

    if matches(path, CLI_TOOL_PATHS, CLI_TOOL_PREFIXES):
        return integration.union([CLI_TOOLS])

    if matches(path, IOS_AUTOMATION_PATHS, IOS_OR_FRAMEWORK_TEST_PREFIXES):
        return integration

    # Workflow, toolchain, project-generation, and unclassified changes run every
    # optional scope. A new path must earn a narrower classification explicitly.
    return set(SCOPES)


def select_scopes(paths: Iterable[str]) -> dict[str, bool]:
    normalized_paths = sorted({path for path in map(normalize_path, paths) if path})
    if not normalized_paths:
        return dict.fromkeys(SCOPES, True)

    selected: set[str] = set()
    for path in normalized_paths:
        selected.update(scopes_for_path(path))

    return {scope: scope in selected for scope in SCOPES}


def format_outputs(scopes: dict[str, bool]) -> str:
    return "\n".join(f"{scope}={str(scopes[scope]).lower()}" for scope in SCOPES)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Select expensive macOS CI scopes from changed paths",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Repository-relative changed paths; stdin is used when none are supplied",
    )
    parser.add_argument(
        "--github-output",
        type=Path,
        help="Also append the key/value results to a GitHub Actions output file",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    paths = list(args.paths)
    if not paths:
        paths.extend(sys.stdin.read().splitlines())

    output = format_outputs(select_scopes(paths))
    print(output)
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as handle:
            handle.write(f"{output}\n")


if __name__ == "__main__":
    main()
