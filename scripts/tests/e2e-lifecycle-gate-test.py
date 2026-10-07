#!/usr/bin/env python3

import importlib.util
import subprocess
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "e2e-lifecycle-gate.py"
SPEC = importlib.util.spec_from_file_location("e2e_lifecycle_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FailureKindTests(unittest.TestCase):
    def test_scenario_failure_is_a_product_failure(self) -> None:
        self.assertEqual(
            MODULE.lifecycle_failure_kind(AssertionError("contract"), scenario_started=True),
            "product-lifecycle-failure",
        )

    def test_setup_timeout_is_an_infrastructure_timeout(self) -> None:
        timeout = subprocess.TimeoutExpired(["xcrun"], 10)
        self.assertEqual(
            MODULE.lifecycle_failure_kind(timeout, scenario_started=False),
            "infrastructure-timeout",
        )

    def test_other_setup_failure_is_infrastructure(self) -> None:
        self.assertEqual(
            MODULE.lifecycle_failure_kind(RuntimeError("missing app"), scenario_started=False),
            "infrastructure-setup-failure",
        )


class ActiveLifecycleContractTests(unittest.TestCase):
    def test_active_heist_uses_external_cli_plan_and_driver_session(self) -> None:
        app = MODULE.DemoApp("simulator", port=4567, token="active-token")

        command = MODULE.heist_command(
            Path("buttonheist"),
            app,
            MODULE.ACTIVE_LIFECYCLE_PLAN,
            connect_timeout=7,
        )
        environment = MODULE.heist_environment(app, MODULE.ACTIVE_LIFECYCLE_DRIVER)

        self.assertEqual(command[1], "run_heist")
        self.assertIn("--plan", command)
        self.assertEqual(command[command.index("--plan") + 1], MODULE.ACTIVE_LIFECYCLE_PLAN)
        self.assertEqual(command[command.index("--device") + 1], "127.0.0.1:4567")
        self.assertEqual(environment["BUTTONHEIST_TOKEN"], "active-token")
        self.assertEqual(environment["BUTTONHEIST_DRIVER_ID"], MODULE.ACTIVE_LIFECYCLE_DRIVER)

    def test_session_lock_requires_a_structured_lock_refusal(self) -> None:
        self.assertTrue(MODULE.session_is_locked({
            "returncode": 1,
            "json": {"status": "error", "error": {"code": "session.locked"}},
        }))
        self.assertFalse(MODULE.session_is_locked({
            "returncode": 0,
            "json": {"status": "ok"},
        }))

    def test_active_execution_waits_for_lock_before_lifecycle_transition(self) -> None:
        app = MODULE.DemoApp("simulator", port=4567, token="active-token")
        responses = iter([
            {"returncode": 1, "json": {"status": "error", "error": {"code": "connecting"}}},
            {"returncode": 1, "json": {"status": "error", "error": {"code": "session.locked"}}},
        ])
        sleeps: list[float] = []

        attempts = MODULE.wait_for_active_heist(
            Path("buttonheist"),
            app,
            connect_timeout=7,
            request=lambda *args, **kwargs: next(responses),
            now=lambda: 0,
            sleep=sleeps.append,
        )

        self.assertEqual(len(attempts), 2)
        self.assertEqual(sleeps, [0.2])

    def test_terminal_completion_requires_current_route_evidence(self) -> None:
        outcome = MODULE.terminal_lifecycle_outcome({
            "returncode": 0,
            "json": self.heist_response(
                status="ok",
                terminal_status="passed",
                evidence={"wait": {"finalSummary": {"screen": "Transient Flow"}}},
            ),
        })

        self.assertEqual(outcome, {"outcome": "completed", "currentEvidence": True})

    def test_terminal_cancellation_is_admitted_without_a_final_capture(self) -> None:
        outcome = MODULE.terminal_lifecycle_outcome({
            "returncode": 1,
            "json": self.heist_response(
                status="partial",
                terminal_status="failed",
                failure={"category": "wait", "observed": "wait observation was cancelled"},
            ),
        })

        self.assertEqual(
            outcome,
            {"outcome": "cancelled", "currentEvidence": False, "failureCategory": "wait"},
        )

    def test_terminal_status_must_match_the_cli_exit_status(self) -> None:
        response = {
            "returncode": 1,
            "json": self.heist_response(
                status="ok",
                terminal_status="passed",
                evidence={"wait": {"finalSummary": {"screen": "Transient Flow"}}},
            ),
        }

        with self.assertRaisesRegex(AssertionError, "must exit zero"):
            MODULE.terminal_lifecycle_outcome(response)

    def test_current_evidence_failure_rejects_a_stale_route(self) -> None:
        response = {
            "returncode": 1,
            "json": self.heist_response(
                status="partial",
                terminal_status="failed",
                failure={"category": "timeout", "observed": "wait deadline expired"},
                evidence={"wait": {"finalSummary": {"screen": "ButtonHeist Demo"}}},
            ),
        }

        with self.assertRaisesRegex(AssertionError, "current Transient Flow evidence"):
            MODULE.terminal_lifecycle_outcome(response)

    @staticmethod
    def heist_response(
        *,
        status: str,
        terminal_status: str,
        evidence: dict[str, object] | None = None,
        failure: dict[str, str] | None = None,
    ) -> dict[str, object]:
        terminal: dict[str, object] = {
            "path": "$.body[2]",
            "status": terminal_status,
            "children": [],
        }
        if evidence is not None:
            terminal["evidence"] = evidence
        if failure is not None:
            terminal["failure"] = failure
        return {
            "status": status,
            "report": {
                "summary": {"executedTopLevelStepCount": 3},
                "nodes": [
                    {"path": "$.body[0]", "status": "passed", "children": []},
                    {"path": "$.body[1]", "status": "passed", "children": []},
                    terminal,
                ],
            },
        }

if __name__ == "__main__":
    unittest.main()
