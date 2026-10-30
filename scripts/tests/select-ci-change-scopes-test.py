#!/usr/bin/env python3

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "select-ci-change-scopes.py"
SPEC = importlib.util.spec_from_file_location("select_ci_change_scopes", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SELECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SELECTOR)


class ChangeScopeSelectionTests(unittest.TestCase):
    def assert_scopes(
        self,
        paths: list[str],
        *,
        package_api: bool,
        cli_tools: bool,
        ios_integration: bool,
    ) -> None:
        self.assertEqual(
            SELECTOR.select_scopes(paths),
            {
                SELECTOR.PACKAGE_API: package_api,
                SELECTOR.CLI_TOOLS: cli_tools,
                SELECTOR.IOS_INTEGRATION: ios_integration,
            },
        )

    def test_docs_only_skips_optional_scopes(self) -> None:
        self.assert_scopes(
            ["README.md", "docs/CI.md", "ButtonHeistCLI/README.md"],
            package_api=False,
            cli_tools=False,
            ios_integration=False,
        )

    def test_ios_test_helper_skips_optional_scopes(self) -> None:
        self.assert_scopes(
            ["ButtonHeist/Tests/TheInsideJobTests/Helpers/HostedTestAssertions.swift"],
            package_api=False,
            cli_tools=False,
            ios_integration=False,
        )

    def test_hosted_fixture_and_ios_automation_skip_optional_scopes(self) -> None:
        self.assert_scopes(
            [
                "ButtonHeist/Tests/HostedTestSupport/DogfoodFixtures.swift",
                "TestApp/Sources/DashboardView.swift",
                "scripts/check-e2e-adversarial-lab-timing.py",
                "scripts/select-ios-ci-simulator.py",
            ],
            package_api=False,
            cli_tools=False,
            ios_integration=True,
        )

    def test_public_source_runs_package_contracts_and_tool_tests(self) -> None:
        self.assert_scopes(
            ["ButtonHeist/Sources/TheScore/AccessibilityObservationChange.swift"],
            package_api=True,
            cli_tools=True,
            ios_integration=True,
        )

    def test_cli_change_runs_only_tool_tests(self) -> None:
        self.assert_scopes(
            ["ButtonHeistCLI/Sources/Commands/ActivateCommand.swift"],
            package_api=False,
            cli_tools=True,
            ios_integration=False,
        )

    def test_compiled_example_runs_tool_tests(self) -> None:
        self.assert_scopes(
            ["examples/heist-program.swift"],
            package_api=False,
            cli_tools=True,
            ios_integration=False,
        )

    def test_package_manifest_runs_package_contracts_and_tool_tests(self) -> None:
        self.assert_scopes(
            ["./Package.swift"],
            package_api=True,
            cli_tools=True,
            ios_integration=False,
        )

    def test_bumper_policy_changes_use_always_on_source_validation(self) -> None:
        for path in (
            "BumperBowling.swift",
            ".bumper/Sources/ButtonHeistCustomRules.swift",
            ".bumper/Tests/AnyBoundaryRuleTests.swift",
            "docs/BUMPER-RULES.md",
        ):
            with self.subTest(path=path):
                self.assert_scopes(
                    [path],
                    package_api=False,
                    cli_tools=False,
                    ios_integration=False,
                )

    def test_workflow_and_unknown_changes_fail_open(self) -> None:
        for path in (".github/workflows/ci.yml", "mise.toml", "NewComponent/file.swift"):
            with self.subTest(path=path):
                self.assert_scopes(
                    [path],
                    package_api=True,
                    cli_tools=True,
                    ios_integration=True,
                )

    def test_mixed_paths_union_their_scopes(self) -> None:
        self.assert_scopes(
            [
                "ButtonHeistCLI/Sources/Support/CLIUtilities.swift",
                "scripts/check-source-shape.sh",
                "docs/API.md",
            ],
            package_api=False,
            cli_tools=True,
            ios_integration=False,
        )

    def test_empty_input_fails_open(self) -> None:
        self.assert_scopes(
            [],
            package_api=True,
            cli_tools=True,
            ios_integration=True,
        )

    def test_output_is_stable_github_boolean_syntax(self) -> None:
        scopes = SELECTOR.select_scopes(["docs/API.md"])
        self.assertEqual(
            SELECTOR.format_outputs(scopes),
            "run_package_api_contracts=false\n"
            "run_cli_tool_tests=false\n"
            "run_ios_integration=false",
        )


if __name__ == "__main__":
    unittest.main()
