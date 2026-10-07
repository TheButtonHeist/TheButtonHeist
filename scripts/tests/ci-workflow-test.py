#!/usr/bin/env python3

import re
import unittest
from pathlib import Path


WORKFLOW = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
PROJECT = (Path(__file__).resolve().parents[2] / "Project.swift").read_text()


def job_blocks() -> dict[str, str]:
    jobs = WORKFLOW.split("\njobs:\n", 1)[1]
    starts = list(re.finditer(r"(?m)^  ([a-z0-9-]+):\n", jobs))
    return {
        match.group(1): jobs[match.end() : starts[index + 1].start()]
        if index + 1 < len(starts)
        else jobs[match.end() :]
        for index, match in enumerate(starts)
    }


class CIWorkflowTests(unittest.TestCase):
    def test_ios_runner_topology(self) -> None:
        blocks = job_blocks()
        self.assertIn("needs: ios-logic", blocks["ios-hosted"])
        self.assertIn(
            "needs: [ios-logic, release-contract]",
            blocks["ios-integration"],
        )
        self.assertIn(
            "needs.release-contract.outputs.run_ios_integration == 'true'",
            blocks["ios-integration"],
        )
        self.assertIn(
            "if: always() && needs.ios-logic.result == 'success'",
            blocks["ios-integration"],
        )
        self.assertNotIn("ios-integration-scope", blocks)
        release = blocks["release-contract"]
        self.assertIn(
            "run_ios_integration: "
            "${{ steps.integration-scope.outputs.run_ios_integration }}",
            release,
        )
        self.assertIn(
            "python3 scripts/select-ci-change-scopes.py "
            '--github-output "$GITHUB_OUTPUT"',
            release,
        )
        self.assertNotIn("grep -Eq", release)

    def test_portable_contracts_stay_on_linux(self) -> None:
        release = job_blocks()["release-contract"]
        self.assertIn("runs-on: ubuntu-latest", release)
        self.assertNotRegex(release, r"\b(?:xcodebuild|tuist)\b")

    def test_hosted_canaries_reuse_the_dedicated_simulator(self) -> None:
        hosted = job_blocks()["ios-hosted"]
        self.assertIn("BUTTONHEIST_TEST_SIMULATOR_NAME:", hosted)
        self.assertNotIn("parallel-testing", hosted)
        hosted_scheme = PROJECT.split('name: "HostedBehaviorTests"', 1)[1]
        self.assertIn("parallelization: .disabled", hosted_scheme)
        self.assertEqual(
            hosted.count("build-for-testing HostedBehaviorTests"),
            1,
        )
        self.assertIn(
            "test-without-building TheInsideJobWindowTests",
            hosted,
        )
        self.assertIn(
            "test-without-building HostedBehaviorTests",
            hosted,
        )
        self.assertIn("scripts/e2e-demo-smoke.py", hosted)

    def test_tuist_test_jobs_do_not_initialize_the_parser_submodule(self) -> None:
        blocks = job_blocks()
        for name in ("macos-tests", "ios-logic", "ios-hosted", "ios-integration"):
            with self.subTest(job=name):
                self.assertNotIn("git submodule update", blocks[name])

    def test_xcode_jobs_use_the_canonical_project_generator(self) -> None:
        blocks = job_blocks()
        for name in (
            "macos-tests",
            "ios-logic",
            "ios-hosted",
            "ios-integration",
        ):
            with self.subTest(job=name):
                self.assertEqual(
                    blocks[name].count(
                        "./scripts/generate-project.sh --no-binary-cache"
                    ),
                    1,
                )
                self.assertNotIn("tuist install", blocks[name])
                self.assertNotIn("--skip-install", blocks[name])

    def test_exact_sha_suite_requires_every_main_validation_job(self) -> None:
        aggregate = job_blocks()["exact-sha-suite"]
        self.assertIn(
            "needs: [release-contract, macos-tests, ios-logic, ios-hosted, ios-integration]",
            aggregate,
        )
        self.assertIn(
            "if: always() && github.event_name == 'push' && github.ref == 'refs/heads/main'",
            aggregate,
        )
        self.assertIn("name: buttonheist-exact-sha-suite", aggregate)
        self.assertIn("-f scripts/exact-sha-suite.jq", aggregate)
        for suite in (
            "release-contract",
            "macos-tests",
            "ios-tests",
            "ios-demo-gates",
            "main-integration",
        ):
            with self.subTest(suite=suite):
                self.assertIn(f'{{name: "{suite}", conclusion:', aggregate)

    def test_macos_frameworks_share_one_test_invocation(self) -> None:
        macos = job_blocks()["macos-tests"]
        self.assertIn(
            "scripts/test-runner.py run MacFrameworkTests",
            macos,
        )
        self.assertNotIn("for scheme in", macos)
        self.assertIn('name: "MacFrameworkTests"', PROJECT)

    def test_xcode_suites_delegate_all_test_driving_to_the_runner(self) -> None:
        for command in (
            "build-for-testing TheInsideJobLogicTests",
            "test-without-building TheInsideJobLogicTests",
            "build-for-testing HostedBehaviorTests",
            "test-without-building TheInsideJobWindowTests",
            "test-without-building HostedBehaviorTests",
            "build-for-testing TheInsideJobIntegrationTests",
            "test-without-building TheInsideJobIntegrationTests",
        ):
            self.assertIn(f"scripts/test-runner.py {command}", WORKFLOW)
        self.assertNotIn("scripts/test-runner.py collect ", WORKFLOW)

        self.assertNotRegex(
            WORKFLOW,
            r"\bxcodebuild\s+(?:test|build-for-testing|test-without-building)\b",
        )
        self.assertNotRegex(WORKFLOW, r"\btuist\s+test\b")
        self.assertNotIn("--selection", WORKFLOW)
        for name in ("macos-tests", "ios-logic", "ios-hosted", "ios-integration"):
            self.assertNotIn("select-ios-ci-simulator.py", job_blocks()[name])
        self.assertNotIn("IOS_TEST_RESULT_BUNDLE", WORKFLOW)
        self.assertNotIn("-destination", WORKFLOW)

    def test_ios_jobs_retain_only_until_unconditional_runner_cleanup(self) -> None:
        blocks = job_blocks()
        jobs = {
            "ios-logic": (
                "TheInsideJobLogicTests",
                "TheInsideJobLogicTests",
            ),
            "ios-hosted": (
                "HostedBehaviorTests",
                "HostedBehaviorTests",
            ),
            "ios-integration": (
                "TheInsideJobIntegrationTests",
                "TheInsideJobIntegrationTests",
            ),
        }
        for name, (build_suite, terminal_suite) in jobs.items():
            with self.subTest(job=name):
                block = blocks[name]
                self.assertIn(
                    f"build-for-testing {build_suite} --retain-simulator",
                    block,
                )
                self.assertIn(
                    f"test-without-building {terminal_suite} --retain-simulator",
                    block,
                )
                self.assertIn("if: always()", block)
                self.assertIn("run: scripts/test-runner.py cleanup", block)

    def test_swift_test_owns_cli_and_mcp_builds(self) -> None:
        macos = job_blocks()["macos-tests"]
        self.assertIn("scripts/swift-test-gate.sh ButtonHeistCLI", macos)
        self.assertIn("scripts/swift-test-gate.sh ButtonHeistMCP", macos)
        self.assertNotIn("swift build --package-path ButtonHeistCLI", macos)
        self.assertNotIn("swift build --package-path ButtonHeistMCP", macos)

    def test_expensive_macos_scopes_follow_the_tested_path_classifier(self) -> None:
        macos = job_blocks()["macos-tests"]
        release = job_blocks()["release-contract"]
        self.assertIn("id: changes", macos)
        self.assertIn("git diff --name-only --no-renames", macos)
        self.assertIn(
            'python3 scripts/select-ci-change-scopes.py --github-output "$GITHUB_OUTPUT"',
            macos,
        )
        self.assertIn(
            "if: github.event_name == 'push' || steps.changes.outputs.run_bumper_rule_tests == 'true'",
            macos,
        )
        self.assertIn("run: scripts/check-source-shape.sh test", macos)
        self.assertIn(
            "if: github.event_name == 'push' || steps.changes.outputs.run_package_api_contracts == 'true'",
            macos,
        )
        self.assertIn(
            "if: github.event_name == 'push' || steps.changes.outputs.run_cli_tool_tests == 'true'",
            macos,
        )
        self.assertIn("python3 scripts/tests/select-ci-change-scopes-test.py", release)


if __name__ == "__main__":
    unittest.main()
