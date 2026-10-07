#!/usr/bin/env python3
"""Direct contract checks for adversarial sample isolation and classification."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path


SCRIPT = Path(__file__).with_name("e2e-adversarial-lab.py")
SPEC = importlib.util.spec_from_file_location("e2e_adversarial_lab", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
lab = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = lab
SPEC.loader.exec_module(lab)


def scenario(
    expectation: str,
    evidence: list[dict[str, str]],
) -> lab.Scenario:
    return lab.Scenario.decode(
        {
            "name": "directContract",
            "route": "/direct-contract",
            "plan": "catalog projection",
            "classification": "statistical",
            "expectedOutcome": expectation,
            "expectedEvidence": evidence,
        }
    )


def run_heist_output(
    *,
    element_value: str = "1",
    announcement: str | None = "Saved",
    measurements: list[dict[str, object]] | None = None,
    ceilings: list[dict[str, object]] | None = None,
) -> str:
    result = {
        "delta": {
            "kind": "elementsChanged",
            "elementCount": 1,
            "edits": {
                "updated": [{
                    "after": {
                        "traits": ["staticText"],
                        "label": "Activations",
                        "value": element_value,
                    }
                }]
            },
        }
    }
    if announcement is not None:
        result["announcement"] = announcement
    return json.dumps({
        "status": "ok",
        "report": {
            "metrics": {
                "measurements": measurements if measurements is not None else [{
                    "name": "heistDurationMs",
                    "valueMs": 40,
                    "path": "$.body[0]",
                    "kind": "action",
                    "status": "passed",
                }],
                "ceilings": ceilings if ceilings is not None else [],
            },
            "nodes": [{
                "path": "$.body[0]",
                "kind": "action",
                "status": "passed",
                "evidence": {"action": {"result": result}},
                "children": [],
            }]
        },
    })


passing = scenario(
    "command-succeeds",
    [
        {"kind": "element", "label": "Activations", "value": "1"},
        {"kind": "notification", "label": "Saved"},
    ],
)
assert passing.expected_evidence == (
    lab.EvidenceFact(lab.EvidenceKind.ELEMENT, "Activations", "1"),
    lab.EvidenceFact(lab.EvidenceKind.NOTIFICATION, "Saved", None),
)
expected_failure = scenario(
    "command-fails-with-diagnostic",
    [{"kind": "diagnostic", "label": "expected diagnostic"}],
)
try:
    lab.select_nightly_scenarios([passing])
except RuntimeError as error:
    assert str(error) == "typed adversarial catalog must contain exactly 9 statistical scenarios"
else:
    raise AssertionError("nightly must retain exactly nine statistical scenarios")
assert lab.select_nightly_scenarios([passing] * 9) == [passing] * 9
success = lab.observe_primary(
    passing,
    subprocess.CompletedProcess(["buttonheist"], 0, run_heist_output(), ""),
)
product_failure = lab.observe_primary(
    passing,
    subprocess.CompletedProcess(["buttonheist"], 1, "{}", "recoverable failure"),
)
diagnostic = lab.observe_primary(
    expected_failure,
    subprocess.CompletedProcess(["buttonheist"], 1, "{}", "Expected Diagnostic"),
)
missing_notification = lab.observe_primary(
    passing,
    subprocess.CompletedProcess(
        ["buttonheist"],
        0,
        run_heist_output(announcement=None),
        "",
    ),
)
mismatched_value = lab.observe_primary(
    passing,
    subprocess.CompletedProcess(
        ["buttonheist"],
        0,
        run_heist_output(element_value="2"),
        "",
    ),
)
assert success["status"] == "passed" and success["evidenceMatched"] is True
assert product_failure["status"] == "failed"
assert diagnostic["status"] == "passed" and diagnostic["diagnosticMatched"] is True
assert missing_notification["status"] == "failed"
assert missing_notification["missingEvidence"] == [
    {"kind": "notification", "label": "Saved"}
]
assert mismatched_value["status"] == "failed"
assert mismatched_value["missingEvidence"] == [
    {"kind": "element", "label": "Activations", "value": "1"}
]

malformed_measurement = lab.observe_primary(
    passing,
    subprocess.CompletedProcess(
        ["buttonheist"],
        0,
        run_heist_output(measurements=[{"name": "heistDurationMs", "valueMs": -1}]),
        "",
    ),
)
malformed_ceiling = lab.observe_primary(
    passing,
    subprocess.CompletedProcess(
        ["buttonheist"],
        0,
        run_heist_output(ceilings=[{
            "source": "caseSelection.timeout",
            "budgetMs": 10,
            "elapsedMs": -1,
            "path": "$.body[0]",
            "kind": "conditional",
            "status": "passed",
        }]),
        "",
    ),
)
assert malformed_measurement["status"] == "failed"
assert malformed_measurement["evidenceMatched"] is False
assert malformed_measurement["evidenceError"] == "run_heist metric measurement requires non-negative valueMs"
assert malformed_ceiling["status"] == "failed"
assert malformed_ceiling["evidenceMatched"] is False
assert malformed_ceiling["evidenceError"] == "run_heist metric ceiling requires non-negative budgetMs and elapsedMs"

clamped_near_budget = lab.observe_primary(
    passing,
    subprocess.CompletedProcess(
        ["buttonheist"],
        0,
        run_heist_output(ceilings=[{
            "source": "caseSelection.timeout",
            "budgetMs": 10,
            "elapsedMs": 0,
            "path": "$.body[0]",
            "kind": "conditional",
            "status": "passed",
        }]),
        "",
    ),
)
assert clamped_near_budget["status"] == "passed"
assert clamped_near_budget["ceilingHits"][0]["elapsedMs"] == 0

timed = lab.observe_primary(
    passing,
    subprocess.CompletedProcess(
        ["buttonheist"],
        0,
        run_heist_output(
            measurements=[
                {"name": "heistDurationMs", "valueMs": 1},
                {"name": "actionPipeline.totalMs", "valueMs": 20, "path": "$.body[0]", "kind": "action", "status": "passed"},
            ],
            ceilings=[{
                "source": "caseSelection.timeout",
                "budgetMs": 100,
                "elapsedMs": 76,
                "path": "$.body[0]",
                "kind": "conditional",
                "status": "passed",
            }],
        ),
        "",
    ),
)
assert timed["receiptMeasurements"] == [
    {"name": "heistDurationMs", "valueMs": 1},
    {
        "name": "actionPipeline.totalMs",
        "valueMs": 20,
        "path": "$.body[0]",
        "kind": "action",
        "status": "passed",
    },
]
assert timed["ceilingHits"] == [{
    "source": "caseSelection.timeout",
    "budgetMs": 100,
    "elapsedMs": 76,
    "path": "$.body[0]",
    "kind": "conditional",
    "status": "passed",
}]
try:
    lab.parse_successful_run_heist_report(json.dumps({"status": "ok", "report": {"nodes": []}}))
except ValueError as error:
    assert str(error) == "successful run_heist report must contain metrics"
else:
    raise AssertionError("current receipt metrics are required")

assert lab.timing_statistics([12, 1, 9, 5, 7]) == {
    "count": 5,
    "min": 1,
    "p50": 7,
    "p95": 12,
    "max": 12,
}

samples = lab.execute_samples(
    5,
    lambda iteration: {
        "iteration": iteration,
        "primary": product_failure if iteration == 1 else success,
        "infrastructure": {"status": "passed"},
        "recovery": {"status": "passed"},
    },
)
assert lab.scenario_report(passing, 5, samples)["recorded"] == 5
assert [sample["iteration"] for sample in samples] == [1, 2, 3, 4, 5]

timing_report = lab.scenario_report(
    passing,
    2,
    [
        {
            "iteration": 1,
            "primary": {"status": "passed", "cliWallDurationMs": 12, **timed},
            "infrastructure": {"status": "passed"},
            "recovery": {"status": "passed"},
        },
        {
            "iteration": 2,
            "primary": {
                "status": "passed",
                "cliWallDurationMs": 8,
                "receiptMeasurements": [{"name": "heistDurationMs", "valueMs": 3}],
                "ceilingHits": [],
            },
            "infrastructure": {"status": "passed"},
            "recovery": {"status": "passed"},
        },
    ],
)
assert timing_report["cliWallDurationMs"] == {
    "count": 2,
    "min": 8,
    "p50": 8,
    "p95": 12,
    "max": 12,
}
assert timing_report["receiptTimingMs"]["heistDurationMs"] == {
    "count": 2,
    "min": 1,
    "p50": 1,
    "p95": 3,
    "max": 3,
}
assert len(timing_report["ceilingHits"]) == 1
assert not lab.gate_failed(lab.gate_summary([timing_report]))


class FakeApp:
    instances = []

    def __init__(self, simulator: str, *, token_prefix: str):
        self.token = token_prefix
        self.instances.append(self)

    def launch(self) -> None:
        if len(self.instances) == 1:
            raise RuntimeError("first launch failed")

    def terminate(self, *, require_stopped: bool) -> None:
        if len(self.instances) == 1:
            raise RuntimeError("first recovery failed")


def fake_heist(*_args) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(["buttonheist"], 0, run_heist_output(), "")


class FakeMonotonicClock:
    def __init__(self, values: list[int]):
        self.values = iter(values)

    def __call__(self) -> int:
        return next(self.values)

isolated = lab.execute_samples(
    3,
    lambda iteration: lab.execute_sample(
        Path("buttonheist"),
        "simulator",
        passing,
        iteration,
        app_factory=FakeApp,
        heist_runner=fake_heist,
        monotonic_ns=FakeMonotonicClock([0, 7_000_000]),
    ),
)
assert len({app.token for app in FakeApp.instances}) == 3
assert isolated[0]["recovery"]["status"] == "failed"
assert isolated[0]["infrastructure"]["status"] == "failed"
assert isolated[0]["primary"]["status"] == "not-run"
assert all(sample["primary"]["status"] == "passed" for sample in isolated[1:])
assert all(sample["primary"]["cliWallDurationMs"] == 7 for sample in isolated[1:])
