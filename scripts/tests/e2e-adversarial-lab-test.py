#!/usr/bin/env python3

import importlib.util
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "e2e-adversarial-lab.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("e2e_adversarial_lab", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ScenarioLaunchTests(unittest.TestCase):
    def test_sample_routes_the_demo_during_launch_without_opening_a_url(self) -> None:
        environment_key = MODULE.SIMCTL_CHILD_ADVERSARIAL_ROUTE_ENVIRONMENT_KEY
        app = FakeDemoApp(environment_key)
        scenario = MODULE.Scenario(
            name="nestedScrollPass",
            route="/nested-scroll",
            plan="WaitFor(.exists(.label(\"Nested Scroll\")))",
            classification=MODULE.ScenarioClassification.STATISTICAL,
            expectation=MODULE.ScenarioExpectation.COMMAND_SUCCEEDS,
            expected_evidence=(
                MODULE.EvidenceFact(MODULE.EvidenceKind.ELEMENT, "Nested Scroll", None),
            ),
        )

        with mock.patch.dict(os.environ, {environment_key: "original-route"}):
            sample = MODULE.execute_sample(
                Path("buttonheist"),
                "simulator",
                scenario,
                1,
                app_factory=lambda *args, **kwargs: app,
                heist_runner=lambda *args: subprocess.CompletedProcess([], 1, "", ""),
            )
            self.assertEqual(os.environ.get(environment_key), "original-route")

        self.assertEqual(app.route_at_launch, scenario.route)
        self.assertEqual(sample["infrastructure"]["status"], "passed")
        self.assertEqual(sample["recovery"]["status"], "passed")


class FakeDemoApp:
    token = "adversarial-test-token"
    device = "127.0.0.1:12345"

    def __init__(self, environment_key: str) -> None:
        self.environment_key = environment_key
        self.route_at_launch: str | None = None

    def launch(self) -> None:
        self.route_at_launch = os.environ.get(self.environment_key)

    def terminate(self, *, require_stopped: bool) -> None:
        del require_stopped


if __name__ == "__main__":
    unittest.main()
