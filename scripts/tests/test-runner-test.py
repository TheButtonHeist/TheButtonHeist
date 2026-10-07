#!/usr/bin/env python3

import os
import runpy
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


RUNNER = runpy.run_path(str(Path(__file__).resolve().parents[1] / "test-runner.py"))
SUITES = RUNNER["SUITES"]
FOCUSES = RUNNER["FOCUSES"]
SIMULATOR = {
    "udid": "TEST-UDID",
    "name": "test-simulator",
    "device": "iPhone 16 Pro",
    "os": "26.3",
    "sdk": "26.5",
}
SELECTOR_OUTPUT = (
    "sim_udid=TEST-UDID\nsim_name=test-simulator\n"
    "sim_device_type=iPhone 16 Pro\nsim_os=26.3\nsim_sdk=26.5\n"
)


def select_simulator_during_execute(
    _args: object,
    _name: str,
    _only_tests: object,
    selected_simulators: list[dict[str, str]],
) -> int:
    selected_simulators.append(SIMULATOR)
    return 0


class TestRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = mock.patch.dict(
            os.environ,
            {
                "BUTTONHEIST_TEST_ARTIFACTS_DIR": "/artifacts",
                "BUTTONHEIST_TEST_DERIVED_DATA_ROOT": "/derived",
            },
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_catalog_has_only_canonical_suite_spellings(self) -> None:
        self.assertEqual(
            set(SUITES),
            {
                "TheScoreTests",
                "ButtonHeistTests",
                "TheInsideJobLogicTests",
                "TheInsideJobWindowTests",
                "TheInsideJobIntegrationTests",
                "HostedBehaviorTests",
                "MacFrameworkTests",
            },
        )

    def test_focus_catalog_owns_bounded_maintained_projections(self) -> None:
        self.assertEqual(
            set(FOCUSES),
            {
                "contract-actions",
                "contract-predicates",
                "contract-results",
                "contract-wire",
                "contract-targets",
            },
        )

    def test_arguments_expand_suites_in_source_order(self) -> None:
        args = RUNNER["parse_args"](["run", "TheScoreTests", "ButtonHeistTests"])
        self.assertEqual(args.suites, ["TheScoreTests", "ButtonHeistTests"])

    def test_arguments_parse_simulator_runtime(self) -> None:
        args = RUNNER["parse_args"]([
            "run",
            "TheInsideJobLogicTests",
            "--simulator-runtime",
            "26.3",
        ])
        self.assertEqual(args.simulator_runtime, "26.3")

    def test_prepare_simulator_requires_one_explicit_name_and_no_suite(self) -> None:
        args = RUNNER["parse_args"]([
            "prepare-simulator",
            "--simulator-name",
            "buttonheist-ci-adversarial-123-1",
            "--simulator-runtime",
            "26.3",
        ])

        self.assertEqual(args.suites, [])
        self.assertEqual(
            args.simulator_name,
            "buttonheist-ci-adversarial-123-1",
        )
        self.assertEqual(args.simulator_runtime, "26.3")
        with self.assertRaisesRegex(
            ValueError,
            "prepare-simulator requires --simulator-name",
        ):
            RUNNER["parse_args"](["prepare-simulator"])
        with self.assertRaisesRegex(
            ValueError,
            "prepare-simulator does not accept suites",
        ):
            RUNNER["parse_args"]([
                "prepare-simulator",
                "TheInsideJobLogicTests",
                "--simulator-name",
                "buttonheist-ci-adversarial-123-1",
            ])
        with self.assertRaisesRegex(
            ValueError,
            "prepare-simulator does not accept --test",
        ):
            RUNNER["parse_args"]([
                "prepare-simulator",
                "--simulator-name",
                "buttonheist-ci-adversarial-123-1",
                "--test",
                "AnyTarget/AnySuite/anyMethod",
            ])

    def test_arguments_preserve_arbitrary_test_identifiers_without_selection_api(self) -> None:
        identifier = "AnyTarget/AnySuite/anyMethod"
        args = RUNNER["parse_args"]([
            "run",
            "TheInsideJobWindowTests",
            "--test",
            identifier,
        ])

        self.assertEqual(args.test, [identifier])
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            RUNNER["parse_args"]([
                "run",
                "TheInsideJobWindowTests",
                "--selection",
                "full",
            ])

    def test_arguments_accept_focus_instead_of_suites(self) -> None:
        args = RUNNER["parse_args"]([
            "run",
            "--focus",
            "contract-actions",
            "--focus",
            "contract-results",
        ])

        self.assertEqual(args.suites, [])
        self.assertEqual(args.focus, ["contract-actions", "contract-results"])

    def test_arguments_reject_mixed_or_missing_selection(self) -> None:
        with self.assertRaises(ValueError):
            RUNNER["parse_args"]([
                "run",
                "TheScoreTests",
                "--focus",
                "contract-actions",
            ])
        with self.assertRaises(ValueError):
            RUNNER["parse_args"](["run"])

    def test_retain_simulator_is_limited_to_simulator_using_test_modes(self) -> None:
        args = RUNNER["parse_args"]([
            "build-for-testing",
            "TheInsideJobLogicTests",
            "--retain-simulator",
        ])
        self.assertTrue(args.retain_simulator)

        with self.assertRaisesRegex(ValueError, "requires an iOS suite"):
            RUNNER["parse_args"]([
                "run",
                "MacFrameworkTests",
                "--retain-simulator",
            ])

        with self.assertRaisesRegex(
            ValueError,
            "cleanup does not accept --retain-simulator",
        ):
            RUNNER["parse_args"]([
                "cleanup",
                "--retain-simulator",
            ])

    def test_simulator_runtime_precedence_is_cli_then_env_then_automatic(self) -> None:
        suite = SUITES["TheInsideJobLogicTests"]
        cases = (
            ("26.4", "26.3", ("--runtime", "26.3", "--wait")),
            ("26.4", None, ("--runtime", "26.4", "--wait")),
            ("", None, ("--wait",)),
        )
        for environment, argument, expected in cases:
            with self.subTest(environment=environment, argument=argument), mock.patch.dict(
                os.environ, {"BUTTONHEIST_TEST_SIMULATOR_RUNTIME": environment}
            ), mock.patch.object(
                Path, "read_text", return_value=SELECTOR_OUTPUT
            ), mock.patch.object(RUNNER["subprocess"], "run") as run:
                RUNNER["select_simulator"]("run", suite, None, argument)

            command = run.call_args.args[0]
            self.assertEqual(tuple(command[-len(expected):]), expected)

    def test_macos_simulator_selection_does_not_query_ios_sdk(self) -> None:
        with mock.patch.object(RUNNER["subprocess"], "run") as run:
            selected = RUNNER["select_simulator"]("run", SUITES["MacFrameworkTests"], None, "26.3")

        self.assertIsNone(selected)
        run.assert_not_called()

    def test_prepare_simulator_publishes_the_resolved_ci_environment(self) -> None:
        prepare = mock.Mock(return_value=SIMULATOR)
        publish = mock.Mock()
        with mock.patch.dict(
            RUNNER["main"].__globals__,
            {
                "prepare_simulator": prepare,
                "publish_environment": publish,
            },
        ):
            status = RUNNER["main"]([
                "prepare-simulator",
                "--simulator-name",
                "buttonheist-ci-adversarial-123-1",
            ])

        self.assertEqual(status, 0)
        prepare.assert_called_once_with(
            "prepare-simulator",
            "buttonheist-ci-adversarial-123-1",
            None,
        )
        publish.assert_called_once_with(
            {
                "SIM_UDID": "TEST-UDID",
                "SIM_NAME": "test-simulator",
                "SIM_DEVICE_TYPE": "iPhone 16 Pro",
                "SIM_OS": "26.3",
                "SIM_SDK": "26.5",
            }
        )

    def test_focus_expansion_merges_tests_per_suite_without_duplicates(self) -> None:
        selected = RUNNER["focus_runs"]([
            "contract-predicates",
            "contract-results",
            "contract-predicates",
        ])

        self.assertEqual(list(selected), ["TheScoreTests"])
        self.assertEqual(
            selected["TheScoreTests"],
            (
                "TheScoreTests/AccessibilityPredicateTests",
                "TheScoreTests/HeistResultContractTests",
            ),
        )

    def test_paths_are_deterministic(self) -> None:
        for name in SUITES:
            paths = RUNNER["suite_paths"](name)
            self.assertEqual(
                paths["result_bundle"],
                Path(f"/artifacts/{name}/result-bundles/{name}.xcresult"),
            )
            self.assertEqual(
                paths["heist_results"],
                Path(f"/artifacts/{name}/heist-results"),
            )
            self.assertEqual(paths["diagnostics"], Path(f"/artifacts/{name}/diagnostics"))
            derived_suite = SUITES[name].get("derived_suite", name)
            self.assertEqual(paths["derived"], Path(f"/derived/{derived_suite}"))
            self.assertEqual(paths["record"], Path(f"/artifacts/{name}/run.json"))

    def test_run_drives_xcodebuild_directly_and_never_tuist(self) -> None:
        # `tuist test` reports a failing suite as "✖ Error" plus a forum link.
        # Plain xcodebuild names the test and its assertion, which is the whole
        # reason a runner exists.
        suite = SUITES["TheScoreTests"]
        paths = RUNNER["suite_paths"]("TheScoreTests")
        command = RUNNER["test_command"]("run", "TheScoreTests", suite, paths, None)
        self.assertNotIn("tuist", command)
        self.assertIn("xcodebuild", command)
        self.assertIn("test", command)
        self.assertIn("platform=macOS", command)
        self.assertIn(str(paths["result_bundle"]), command)
        self.assertIn(str(paths["heist_results"]), command)

    def test_focused_run_passes_only_testing_identifiers_to_canonical_command(self) -> None:
        suite = SUITES["TheScoreTests"]
        paths = RUNNER["suite_paths"]("TheScoreTests")
        command = RUNNER["test_command"](
            "run",
            "TheScoreTests",
            suite,
            paths,
            None,
            (
                "TheScoreTests/AccessibilityPredicateTests",
                "TheScoreTests/HeistResultContractTests",
            ),
        )

        self.assertIn("-only-testing:TheScoreTests/AccessibilityPredicateTests", command)
        self.assertIn(
            "-only-testing:TheScoreTests/HeistResultContractTests",
            command,
        )

    def test_catalog_manifest_is_a_deterministic_projection_of_one_owner(self) -> None:
        manifest = RUNNER["catalog_manifest"]()

        self.assertEqual(list(manifest["suites"]), list(SUITES))
        self.assertEqual(list(manifest["focuses"]), list(FOCUSES))
        self.assertEqual(
            manifest["focuses"]["contract-predicates"],
            {"TheScoreTests": ["TheScoreTests/AccessibilityPredicateTests"]},
        )

    def test_source_state_records_commit_and_cleanliness(self) -> None:
        commit = mock.Mock(stdout="abc123\n")
        status = mock.Mock(stdout=" M source.swift\n")
        with mock.patch.object(RUNNER["subprocess"], "run", side_effect=[commit, status]):
            source = RUNNER["source_state"]()

        self.assertEqual(source.commit, "abc123")
        self.assertFalse(source.clean)

    def test_result_summary_rejects_zero_tests(self) -> None:
        completed = mock.Mock(stdout='{"totalTestCount": 0}')
        with mock.patch.object(RUNNER["subprocess"], "run", return_value=completed):
            with self.assertRaisesRegex(RuntimeError, "zero tests"):
                RUNNER["require_executed_tests"](Path("/results/tests.xcresult"))

    def test_result_summary_returns_executed_test_count(self) -> None:
        completed = mock.Mock(stdout='{"totalTestCount": 7}')
        with mock.patch.object(RUNNER["subprocess"], "run", return_value=completed):
            self.assertEqual(
                RUNNER["require_executed_tests"](Path("/results/tests.xcresult")),
                7,
            )

    def test_phase_timeout_terminates_the_process_group_and_is_classified(self) -> None:
        process = mock.Mock(pid=123)
        process.wait.side_effect = [subprocess.TimeoutExpired(["test"], 3), 0]
        with mock.patch.object(RUNNER["subprocess"], "Popen", return_value=process), \
             mock.patch.object(RUNNER["os"], "killpg") as kill_group, \
             mock.patch.object(RUNNER["time"], "monotonic", side_effect=[10.0, 13.0]):
            result = RUNNER["run_phase"](["test"], "tests", 3)

        self.assertEqual(result.exit_code, 124)
        self.assertEqual(result.phase, "tests")
        self.assertTrue(result.timed_out)
        self.assertEqual(result.duration_seconds, 3.0)
        kill_group.assert_called_once_with(123, RUNNER["signal"].SIGTERM)

    def test_split_modes_share_destination_and_paths(self) -> None:
        suite = SUITES["TheInsideJobIntegrationTests"]
        paths = RUNNER["suite_paths"]("TheInsideJobIntegrationTests")
        build = RUNNER["test_command"](
            "build-for-testing", "TheInsideJobIntegrationTests",
            suite, paths, SIMULATOR
        )
        test = RUNNER["test_command"](
            "test-without-building", "TheInsideJobIntegrationTests",
            suite, paths, SIMULATOR
        )
        expected_destination = "platform=iOS Simulator,id=TEST-UDID,arch=arm64"
        self.assertIn(expected_destination, build)
        self.assertIn(expected_destination, test)
        self.assertIn(str(paths["derived"]), build)
        self.assertIn(str(paths["derived"]), test)
        self.assertNotIn(str(RUNNER["WRAPPER"]), build)
        self.assertIn(str(RUNNER["WRAPPER"]), test)
        self.assertIn("--ios-sandbox", test)
        self.assertIn(str(paths["result_bundle"]), test)

    def test_hosted_suites_disable_ambient_animations(self) -> None:
        window_suite = SUITES["TheInsideJobWindowTests"]
        window_paths = RUNNER["suite_paths"]("TheInsideJobWindowTests")
        window_command = RUNNER["test_command"](
            "run",
            "TheInsideJobWindowTests",
            window_suite,
            window_paths,
            SIMULATOR,
        )
        integration_suite = SUITES["TheInsideJobIntegrationTests"]
        integration_paths = RUNNER["suite_paths"]("TheInsideJobIntegrationTests")
        integration_command = RUNNER["test_command"](
            "run",
            "TheInsideJobIntegrationTests",
            integration_suite,
            integration_paths,
            SIMULATOR,
        )
        hosted_suite = SUITES["HostedBehaviorTests"]
        hosted_paths = RUNNER["suite_paths"]("HostedBehaviorTests")
        hosted_command = RUNNER["test_command"](
            "run", "HostedBehaviorTests", hosted_suite, hosted_paths, SIMULATOR
        )

        self.assertIn("BUTTONHEIST_TEST_DISABLE_ANIMATIONS=1", window_command)
        self.assertIn("BUTTONHEIST_TEST_DISABLE_ANIMATIONS=1", integration_command)
        self.assertIn("BUTTONHEIST_TEST_DISABLE_ANIMATIONS=1", hosted_command)

    def test_logic_suite_has_no_host_configuration(self) -> None:
        suite = SUITES["TheInsideJobLogicTests"]
        paths = RUNNER["suite_paths"]("TheInsideJobLogicTests")
        command = RUNNER["test_command"](
            "run",
            "TheInsideJobLogicTests",
            suite,
            paths,
            SIMULATOR,
        )

        self.assertNotIn("BUTTONHEIST_TEST_DISABLE_ANIMATIONS=1", command)
        self.assertIn("-scheme", command)
        self.assertEqual(command[command.index("-scheme") + 1], "TheInsideJobLogicTests")

    def test_window_and_behavior_share_one_build_without_overlapping_runs(self) -> None:
        window = RUNNER["test_command"](
            "test-without-building",
            "TheInsideJobWindowTests",
            SUITES["TheInsideJobWindowTests"],
            RUNNER["suite_paths"]("TheInsideJobWindowTests"),
            SIMULATOR,
        )
        behavior = RUNNER["test_command"](
            "test-without-building",
            "HostedBehaviorTests",
            SUITES["HostedBehaviorTests"],
            RUNNER["suite_paths"]("HostedBehaviorTests"),
            SIMULATOR,
        )

        for command in (window, behavior):
            self.assertEqual(command[command.index("-scheme") + 1], "HostedBehaviorTests")
            self.assertIn("/derived/HostedBehaviorTests", command)
        self.assertIn("-only-testing:TheInsideJobWindowTests", window)
        self.assertIn("-skip-testing:TheInsideJobWindowTests", behavior)

    def test_arbitrary_test_replaces_a_suite_default_only_testing_projection(self) -> None:
        identifier = "TheInsideJobWindowTests/PresentationObscuringTests/testModal"
        command = RUNNER["test_command"](
            "run",
            "TheInsideJobWindowTests",
            SUITES["TheInsideJobWindowTests"],
            RUNNER["suite_paths"]("TheInsideJobWindowTests"),
            SIMULATOR,
            (identifier,),
        )

        self.assertIn(f"-only-testing:{identifier}", command)
        self.assertNotIn("-only-testing:TheInsideJobWindowTests", command)

    def test_macos_supports_prebuilt_focused_feedback(self) -> None:
        suite = SUITES["TheScoreTests"]
        paths = RUNNER["suite_paths"]("TheScoreTests")
        selected = ("TheScoreTests/HeistResultContractTests",)
        build = RUNNER["test_command"](
            "build-for-testing",
            "TheScoreTests",
            suite,
            paths,
            None,
            selected,
        )
        test = RUNNER["test_command"](
            "test-without-building",
            "TheScoreTests",
            suite,
            paths,
            None,
            selected,
        )

        self.assertIn("platform=macOS", build)
        self.assertIn("platform=macOS", test)
        self.assertIn(
            "-only-testing:TheScoreTests/HeistResultContractTests",
            build,
        )
        self.assertIn(
            "-only-testing:TheScoreTests/HeistResultContractTests",
            test,
        )

    def test_hosted_behavior_is_serial(self) -> None:
        suite = SUITES["HostedBehaviorTests"]
        paths = RUNNER["suite_paths"]("HostedBehaviorTests")
        command = RUNNER["test_command"](
            "test-without-building", "HostedBehaviorTests",
            suite, paths, SIMULATOR
        )
        index = command.index("-parallel-testing-enabled")
        self.assertEqual(command[index + 1], "NO")

    def test_mac_framework_tests_are_serial(self) -> None:
        suite = SUITES["MacFrameworkTests"]
        paths = RUNNER["suite_paths"]("MacFrameworkTests")
        command = RUNNER["test_command"](
            "run", "MacFrameworkTests", suite, paths, None
        )
        index = command.index("-parallel-testing-enabled")
        self.assertEqual(command[index + 1], "NO")

    def test_simulator_result_cleanup_is_scoped_to_selected_device(self) -> None:
        with mock.patch.object(RUNNER["Path"], "home", return_value=Path("/Users/test")), \
             mock.patch.object(RUNNER["Path"], "exists", return_value=True), \
             mock.patch.object(RUNNER["Path"], "glob", return_value=[Path("/result-dir")]), \
             mock.patch.object(RUNNER["shutil"], "rmtree") as remove:
            RUNNER["clear_simulator_results"](SIMULATOR)

        remove.assert_called_once_with(Path("/result-dir"))

    def test_failure_diagnostics_bound_logs_to_button_heist_processes(self) -> None:
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ,
            {"SIM_UDID": "TEST-UDID"},
        ), mock.patch.object(RUNNER["subprocess"], "run") as run:
            root = Path(directory)
            RUNNER["collect"](
                SUITES["TheInsideJobWindowTests"],
                {
                    "heist_results": root / "heist-results",
                    "diagnostics": root / "diagnostics",
                },
                include_diagnostics=True,
            )

        log_call = run.call_args_list[2]
        self.assertIn("--predicate", log_call.args[0])
        self.assertIn(
            'process == "BHDemo" OR subsystem BEGINSWITH "com.buttonheist."',
            log_call.args[0],
        )
        self.assertEqual(log_call.kwargs["timeout"], 60)

    def test_simulator_deletion_shuts_down_and_deletes_the_selected_udid(self) -> None:
        completed = mock.Mock(returncode=0, stderr="", stdout="")
        with mock.patch.object(
            RUNNER["subprocess"],
            "run",
            return_value=completed,
        ) as run:
            deleted = RUNNER["delete_simulator"](SIMULATOR)

        self.assertTrue(deleted)
        self.assertEqual(
            run.call_args_list,
            [
                mock.call(
                    ["xcrun", "simctl", "shutdown", "TEST-UDID"],
                    check=False,
                    text=True,
                    capture_output=True,
                ),
                mock.call(
                    ["xcrun", "simctl", "delete", "TEST-UDID"],
                    check=False,
                    text=True,
                    capture_output=True,
                ),
            ],
        )

    def test_cleanup_resolves_only_exactly_named_simulators(self) -> None:
        completed = mock.Mock(
            stdout=(
                '{"devices":{"runtime":['
                '{"udid":"owned","name":"accra-owned","isAvailable":true},'
                '{"udid":"owned-unavailable","name":"accra-owned","isAvailable":false},'
                '{"udid":"other","name":"accra-other","isAvailable":true}]}}'
            )
        )
        with mock.patch.object(
            RUNNER["subprocess"],
            "run",
            return_value=completed,
        ):
            simulators = RUNNER["simulators_named"]("accra-owned")

        self.assertEqual(
            simulators,
            [
                {"udid": "owned", "name": "accra-owned"},
                {"udid": "owned-unavailable", "name": "accra-owned"},
            ],
        )

    def test_runner_deletes_selected_simulators_unless_retained(self) -> None:
        for mode in ("run", "build-for-testing", "test-without-building"):
            with self.subTest(mode=mode), mock.patch.dict(
                RUNNER["main"].__globals__,
                {
                    "execute": select_simulator_during_execute,
                    "delete_simulators": mock.Mock(return_value=True),
                },
            ):
                status = RUNNER["main"]([mode, "TheInsideJobLogicTests"])
                delete = RUNNER["main"].__globals__["delete_simulators"]

                self.assertEqual(status, 0)
                delete.assert_called_once_with([SIMULATOR])

    def test_retained_terminal_run_leaves_cleanup_to_its_caller(self) -> None:
        with mock.patch.dict(
            RUNNER["main"].__globals__,
            {
                "execute": select_simulator_during_execute,
                "delete_simulators": mock.Mock(return_value=True),
            },
        ):
            status = RUNNER["main"]([
                "run",
                "TheInsideJobLogicTests",
                "--retain-simulator",
            ])
            delete = RUNNER["main"].__globals__["delete_simulators"]

        self.assertEqual(status, 0)
        delete.assert_not_called()

    def test_cleanup_command_deletes_every_simulator_with_the_owned_name(self) -> None:
        owned = [
            {"udid": "first", "name": "accra-owned"},
            {"udid": "second", "name": "accra-owned"},
        ]
        with mock.patch.dict(
            RUNNER["main"].__globals__,
            {
                "simulators_named": mock.Mock(return_value=owned),
                "delete_simulators": mock.Mock(return_value=True),
            },
        ):
            status = RUNNER["main"]([
                "cleanup",
                "--simulator-name",
                "accra-owned",
            ])
            delete = RUNNER["main"].__globals__["delete_simulators"]

        self.assertEqual(status, 0)
        delete.assert_called_once_with(owned)

    @mock.patch.object(RUNNER["subprocess"], "run")
    def test_dependency_install_runs_once_for_multiple_suites(
        self,
        run: mock.Mock,
    ) -> None:
        run.return_value.returncode = 0
        with mock.patch.dict(
            RUNNER["main"].__globals__,
            {"execute": mock.Mock(return_value=0)},
        ):
            status = RUNNER["main"]([
                "run",
                "TheScoreTests",
                "ButtonHeistTests",
                "--install-dependencies",
            ])

        self.assertEqual(status, 0)
        run.assert_called_once_with(["tuist", "install"], check=True)


if __name__ == "__main__":
    unittest.main()
