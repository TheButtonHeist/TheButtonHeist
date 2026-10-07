#!/usr/bin/env python3
"""Repeat typed adversarial contracts against independently launched BH Demo sessions."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Iterator

from e2e_runtime import (
    DemoApp,
    boot_simulator,
    error_summary,
    install_app,
    run,
    write_json_report,
)


STATISTICAL_SUCCESS_SCENARIO_COUNT = 9
SIMCTL_CHILD_ADVERSARIAL_ROUTE_ENVIRONMENT_KEY = "SIMCTL_CHILD_BUTTONHEIST_ADVERSARIAL_ROUTE"


class ScenarioExpectation(str, Enum):
    COMMAND_SUCCEEDS = "command-succeeds"
    COMMAND_FAILS_WITH_DIAGNOSTIC = "command-fails-with-diagnostic"


class ScenarioClassification(str, Enum):
    DETERMINISTIC = "deterministic"
    STATISTICAL = "statistical"


class OutcomeStatus(str, Enum):
    PASSED = "passed"
    FAILED = "failed"
    NOT_RUN = "not-run"


class EvidenceKind(str, Enum):
    DIAGNOSTIC = "diagnostic"
    ELEMENT = "element"
    NOTIFICATION = "notification"


@dataclass(frozen=True)
class EvidenceFact:
    kind: EvidenceKind
    label: str
    value: str | None

    @classmethod
    def decode(cls, value: Any) -> EvidenceFact:
        if not isinstance(value, dict):
            raise ValueError("catalog evidence must be an object")
        label = value.get("label")
        semantic_value = value.get("value")
        if not isinstance(label, str) or not label:
            raise ValueError("catalog evidence requires a non-empty label")
        if semantic_value is not None and not isinstance(semantic_value, str):
            raise ValueError("catalog evidence value must be a string")
        return cls(
            kind=EvidenceKind(required_string(value, "kind")),
            label=label,
            value=semantic_value,
        )

    def matches(self, observed: EvidenceFact) -> bool:
        return (
            self.kind is observed.kind
            and self.label == observed.label
            and (self.value is None or self.value == observed.value)
        )

    def json_value(self) -> dict[str, str]:
        result = {"kind": self.kind.value, "label": self.label}
        if self.value is not None:
            result["value"] = self.value
        return result


@dataclass(frozen=True)
class Scenario:
    name: str
    route: str
    plan: str
    classification: ScenarioClassification
    expectation: ScenarioExpectation
    expected_evidence: tuple[EvidenceFact, ...]

    @classmethod
    def decode(cls, value: Any) -> Scenario:
        if not isinstance(value, dict):
            raise ValueError("catalog scenario must be an object")
        encoded_evidence = value.get("expectedEvidence")
        if not isinstance(encoded_evidence, list) or not encoded_evidence:
            raise ValueError("catalog scenario requires expected evidence")
        evidence = tuple(EvidenceFact.decode(row) for row in encoded_evidence)
        expectation = ScenarioExpectation(required_string(value, "expectedOutcome"))
        diagnostics = [
            fact
            for fact in evidence
            if fact.kind is EvidenceKind.DIAGNOSTIC
        ]
        if expectation is ScenarioExpectation.COMMAND_FAILS_WITH_DIAGNOSTIC:
            if len(diagnostics) != 1:
                raise ValueError("failing catalog scenarios require one diagnostic contract")
        elif diagnostics:
            raise ValueError("passing catalog scenarios cannot require diagnostic evidence")
        return cls(
            name=required_string(value, "name"),
            route=required_string(value, "route"),
            plan=required_string(value, "plan"),
            classification=ScenarioClassification(required_string(value, "classification")),
            expectation=expectation,
            expected_evidence=evidence,
        )


def required_string(value: dict[str, Any], key: str) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result:
        raise ValueError(f"catalog scenario requires non-empty {key}")
    return result


def load_catalog(cli: Path) -> list[Scenario]:
    result = run([str(cli), "adversarial_catalog"], timeout=30, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"adversarial catalog command failed: {result.stderr or result.stdout}")
    decoded = json.loads(result.stdout)
    if not isinstance(decoded, list):
        raise ValueError("adversarial catalog command must return an array")
    scenarios = [Scenario.decode(value) for value in decoded]
    if len({scenario.name for scenario in scenarios}) != len(scenarios):
        raise ValueError("adversarial catalog scenario names must be unique")
    return scenarios


def select_nightly_scenarios(catalog: list[Scenario]) -> list[Scenario]:
    scenarios = [
        scenario
        for scenario in catalog
        if scenario.classification is ScenarioClassification.STATISTICAL
    ]
    if len(scenarios) != STATISTICAL_SUCCESS_SCENARIO_COUNT:
        raise RuntimeError(
            "typed adversarial catalog must contain exactly "
            f"{STATISTICAL_SUCCESS_SCENARIO_COUNT} statistical scenarios"
        )
    if any(scenario.expectation is not ScenarioExpectation.COMMAND_SUCCEEDS for scenario in scenarios):
        raise RuntimeError("nightly statistical scenarios must be successful contracts")
    return scenarios


def observe_primary(
    scenario: Scenario,
    result: subprocess.CompletedProcess[str],
) -> dict[str, Any]:
    diagnostic_matched: bool | None = None
    evidence_matched: bool | None = None
    missing_evidence: list[dict[str, str]] = []
    evidence_error: str | None = None
    receipt_measurement_rows: list[dict[str, Any]] | None = None
    ceiling_hit_rows: list[dict[str, Any]] | None = None
    if scenario.expectation is ScenarioExpectation.COMMAND_SUCCEEDS:
        matched = False
        if result.returncode == 0:
            try:
                report = parse_successful_run_heist_report(result.stdout)
                observed = evidence_facts_from_report(report)
                missing_evidence = [
                    expected.json_value()
                    for expected in scenario.expected_evidence
                    if not any(expected.matches(fact) for fact in observed)
                ]
                receipt_measurement_rows = receipt_measurements(report)
                ceiling_hit_rows = ceiling_hits(report)
                evidence_matched = not missing_evidence
                matched = evidence_matched
            except ValueError as error:
                evidence_matched = False
                evidence_error = str(error)
    else:
        diagnostics = [
            fact.label
            for fact in scenario.expected_evidence
            if fact.kind is EvidenceKind.DIAGNOSTIC
        ]
        if len(diagnostics) != 1:
            raise ValueError("failing scenario is missing its admitted diagnostic")
        diagnostic = diagnostics[0]
        diagnostic_matched = diagnostic.casefold() in f"{result.stdout}\n{result.stderr}".casefold()
        matched = result.returncode != 0 and diagnostic_matched
    observation: dict[str, Any] = {
        "status": (OutcomeStatus.PASSED if matched else OutcomeStatus.FAILED).value,
        "returncode": result.returncode,
        "diagnosticMatched": diagnostic_matched,
        "evidenceMatched": evidence_matched,
    }
    if missing_evidence:
        observation["missingEvidence"] = missing_evidence
    if evidence_error is not None:
        observation["evidenceError"] = evidence_error
    if receipt_measurement_rows is not None and ceiling_hit_rows is not None:
        # The successful response is decoded once above; these are diagnostic
        # projections of its canonical receipt metrics, not a second wire model.
        observation["receiptMeasurements"] = receipt_measurement_rows
        observation["ceilingHits"] = ceiling_hit_rows
    return observation


def parse_successful_run_heist_report(output: str) -> dict[str, Any]:
    try:
        response = json.loads(output)
    except json.JSONDecodeError as error:
        raise ValueError(f"run_heist returned invalid JSON: {error.msg}") from error
    if not isinstance(response, dict) or response.get("status") != "ok":
        raise ValueError("successful run_heist JSON must have status ok")
    report = response.get("report")
    if not isinstance(report, dict):
        raise ValueError("successful run_heist JSON must contain a report")
    nodes = report.get("nodes")
    if not isinstance(nodes, list):
        raise ValueError("successful run_heist report must contain nodes")
    metrics = report.get("metrics")
    if not isinstance(metrics, dict):
        raise ValueError("successful run_heist report must contain metrics")
    if not isinstance(metrics.get("measurements"), list):
        raise ValueError("successful run_heist metrics must contain measurements")
    if not isinstance(metrics.get("ceilings"), list):
        raise ValueError("successful run_heist metrics must contain ceilings")
    return report


def evidence_facts_from_report(report: dict[str, Any]) -> tuple[EvidenceFact, ...]:
    nodes = report["nodes"]
    facts: list[EvidenceFact] = []
    for node in nodes:
        facts.extend(evidence_facts_from_node(node))
    return tuple(facts)


def receipt_measurements(report: dict[str, Any]) -> list[dict[str, Any]]:
    measurements = report["metrics"]["measurements"]
    decoded: list[dict[str, Any]] = []
    for measurement in measurements:
        if not isinstance(measurement, dict):
            raise ValueError("run_heist metrics measurements must be objects")
        name = measurement.get("name")
        value_ms = measurement.get("valueMs")
        if not isinstance(name, str) or not name:
            raise ValueError("run_heist metric measurement requires a name")
        if isinstance(value_ms, bool) or not isinstance(value_ms, int) or value_ms < 0:
            raise ValueError("run_heist metric measurement requires non-negative valueMs")
        row: dict[str, Any] = {"name": name, "valueMs": value_ms}
        for key in ("path", "kind", "status"):
            value = measurement.get(key)
            if value is not None:
                if not isinstance(value, str):
                    raise ValueError(f"run_heist metric measurement {key} must be a string")
                row[key] = value
        decoded.append(row)
    return decoded


def ceiling_hits(report: dict[str, Any], *, tolerance_ms: int = 25) -> list[dict[str, Any]]:
    ceilings = report["metrics"]["ceilings"]
    hits: list[dict[str, Any]] = []
    for ceiling in ceilings:
        if not isinstance(ceiling, dict):
            raise ValueError("run_heist metric ceilings must be objects")
        source = ceiling.get("source")
        budget_ms = ceiling.get("budgetMs")
        elapsed_ms = ceiling.get("elapsedMs")
        path = ceiling.get("path")
        kind = ceiling.get("kind")
        status = ceiling.get("status")
        required_strings = (source, path, kind, status)
        if not all(isinstance(value, str) and value for value in required_strings):
            raise ValueError("run_heist metric ceiling requires source, path, kind, and status")
        if (
            isinstance(budget_ms, bool)
            or isinstance(elapsed_ms, bool)
            or not isinstance(budget_ms, int)
            or not isinstance(elapsed_ms, int)
            or budget_ms < 0
            or elapsed_ms < 0
        ):
            raise ValueError("run_heist metric ceiling requires non-negative budgetMs and elapsedMs")
        if elapsed_ms >= max(0, budget_ms - tolerance_ms):
            hits.append({
                "source": source,
                "budgetMs": budget_ms,
                "elapsedMs": elapsed_ms,
                "path": path,
                "kind": kind,
                "status": status,
            })
    return hits


def evidence_facts_from_node(value: Any) -> list[EvidenceFact]:
    if not isinstance(value, dict):
        raise ValueError("run_heist report nodes must be objects")
    facts: list[EvidenceFact] = []
    evidence = value.get("evidence")
    if isinstance(evidence, dict):
        action = evidence.get("action")
        if isinstance(action, dict):
            result = action.get("result")
            if isinstance(result, dict):
                announcement = result.get("announcement")
                if isinstance(announcement, str):
                    facts.append(EvidenceFact(EvidenceKind.NOTIFICATION, announcement, None))
                facts.extend(element_facts_from_delta(result.get("delta")))
            facts.extend(evidence_facts_from_expectation(action.get("expectation")))
        wait = evidence.get("wait")
        if isinstance(wait, dict):
            facts.extend(element_facts_from_delta(wait.get("delta")))
            facts.extend(evidence_facts_from_expectation(wait.get("expectation")))
    facts.extend(evidence_facts_from_expectation(value.get("expectation")))
    children = value.get("children")
    if not isinstance(children, list):
        raise ValueError("run_heist report node children must be an array")
    for child in children:
        facts.extend(evidence_facts_from_node(child))
    return facts


def element_facts_from_delta(value: Any) -> list[EvidenceFact]:
    if not isinstance(value, dict):
        return []
    facts: list[EvidenceFact] = []
    edits = value.get("edits")
    if isinstance(edits, dict):
        added = edits.get("added")
        if isinstance(added, list):
            facts.extend(filter_element_facts(added))
        updated = edits.get("updated")
        if isinstance(updated, list):
            facts.extend(
                fact
                for update in updated
                if isinstance(update, dict)
                for fact in filter_element_facts([update.get("after")])
            )
    screen = value.get("screen")
    if isinstance(screen, dict):
        elements = screen.get("elements")
        if isinstance(elements, list):
            facts.extend(filter_element_facts(elements))
    return facts


def filter_element_facts(values: list[Any]) -> list[EvidenceFact]:
    facts: list[EvidenceFact] = []
    for value in values:
        if not isinstance(value, dict) or not isinstance(value.get("traits"), list):
            continue
        label = value.get("label")
        semantic_value = value.get("value")
        if not isinstance(label, str):
            continue
        facts.append(EvidenceFact(
            kind=EvidenceKind.ELEMENT,
            label=label,
            value=semantic_value if isinstance(semantic_value, str) else None,
        ))
    return facts


def evidence_facts_from_expectation(value: Any) -> list[EvidenceFact]:
    if not isinstance(value, dict) or value.get("met") is not True:
        return []
    expected = value.get("expected")
    if not isinstance(expected, dict):
        return []
    if expected.get("type") == EvidenceKind.NOTIFICATION.value:
        actual = value.get("actual")
        return (
            [EvidenceFact(EvidenceKind.NOTIFICATION, actual, None)]
            if isinstance(actual, str)
            else []
        )
    if expected.get("type") not in {"exists", "appeared", "updated"}:
        return []
    target = expected.get("target")
    return element_facts_from_target(target)


def element_facts_from_target(value: Any) -> list[EvidenceFact]:
    if not isinstance(value, dict):
        return []
    facts: list[EvidenceFact] = []
    checks = value.get("checks")
    if isinstance(checks, list):
        label: str | None = None
        semantic_value: str | None = None
        for check in checks:
            if not isinstance(check, dict):
                continue
            match = check.get("match")
            if (
                not isinstance(match, dict)
                or match.get("mode") != "exact"
                or not isinstance(match.get("value"), str)
            ):
                continue
            if check.get("kind") == "label":
                label = match["value"]
            elif check.get("kind") == "value":
                semantic_value = match["value"]
        if label is not None:
            facts.append(EvidenceFact(EvidenceKind.ELEMENT, label, semantic_value))
    for nested in value.values():
        if isinstance(nested, dict):
            facts.extend(element_facts_from_target(nested))
        elif isinstance(nested, list):
            for item in nested:
                facts.extend(element_facts_from_target(item))
    return facts


def run_heist(
    cli: Path,
    app: DemoApp,
    plan: str,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update({"BUTTONHEIST_TOKEN": app.token, "BUTTONHEIST_DRIVER_ID": app.token})
    result = run(
        [
            str(cli),
            "run_heist",
            "--plan",
            plan,
            "--device",
            app.device,
            "--token",
            app.token,
            "--connect-timeout",
            "10",
            "--format",
            "json",
            "--quiet",
        ],
        env=env,
        timeout=60,
        check=False,
    )
    if result.returncode == 124:
        raise TimeoutError(result.stderr)
    return result


@contextmanager
def adversarial_route_launch_environment(route: str) -> Iterator[None]:
    key = SIMCTL_CHILD_ADVERSARIAL_ROUTE_ENVIRONMENT_KEY
    previous = os.environ.get(key)
    os.environ[key] = route
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = previous


def execute_sample(
    cli: Path,
    simulator: str,
    scenario: Scenario,
    iteration: int,
    *,
    app_factory: Callable[..., DemoApp] = DemoApp,
    heist_runner: Callable[[Path, DemoApp, str], subprocess.CompletedProcess[str]] = run_heist,
    monotonic_ns: Callable[[], int] = time.monotonic_ns,
) -> dict[str, Any]:
    app: DemoApp | None = None
    cli_wall_duration_ms: int | None = None
    sample: dict[str, Any] = {
        "iteration": iteration,
        "primary": {"status": OutcomeStatus.NOT_RUN.value},
        "infrastructure": {"status": OutcomeStatus.NOT_RUN.value},
        "recovery": {"status": OutcomeStatus.NOT_RUN.value},
    }
    try:
        app = app_factory(
            simulator,
            token_prefix=f"adversarial-{scenario.name}-{iteration}",
        )
        with adversarial_route_launch_environment(scenario.route):
            app.launch()
        sample["infrastructure"]["status"] = OutcomeStatus.PASSED.value
        started_ns = monotonic_ns()
        try:
            result = heist_runner(cli, app, scenario.plan)
        finally:
            cli_wall_duration_ms = max(0, (monotonic_ns() - started_ns) // 1_000_000)
        sample["primary"] = observe_primary(scenario, result)
        sample["primary"]["cliWallDurationMs"] = cli_wall_duration_ms
    except Exception as error:
        if cli_wall_duration_ms is not None:
            sample["primary"]["cliWallDurationMs"] = cli_wall_duration_ms
        sample["infrastructure"] = {
            "status": OutcomeStatus.FAILED.value,
            "diagnostics": error_summary(error),
        }
    finally:
        if app is not None:
            try:
                app.terminate(require_stopped=True)
                sample["recovery"]["status"] = OutcomeStatus.PASSED.value
            except Exception as error:
                sample["recovery"] = {
                    "status": OutcomeStatus.FAILED.value,
                    "diagnostics": error_summary(error),
                }
    return sample


def execute_samples(
    requested: int,
    execute: Callable[[int], dict[str, Any]],
) -> list[dict[str, Any]]:
    return [execute(iteration) for iteration in range(1, requested + 1)]


def timing_statistics(values: list[int]) -> dict[str, int]:
    if not values:
        return {}
    ordered = sorted(values)

    def nearest_rank(percentile: int) -> int:
        # Nearest-rank percentile: rank = ceil(percentile * count / 100).
        return ordered[(percentile * len(ordered) + 99) // 100 - 1]

    return {
        "count": len(ordered),
        "min": ordered[0],
        "p50": nearest_rank(50),
        "p95": nearest_rank(95),
        "max": ordered[-1],
    }


def aggregate_receipt_timing(observations: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    values_by_name: dict[str, list[int]] = {}
    for sample in observations:
        for measurement in sample["primary"].get("receiptMeasurements", []):
            values_by_name.setdefault(measurement["name"], []).append(measurement["valueMs"])
    return {
        name: timing_statistics(values)
        for name, values in sorted(values_by_name.items())
    }


def aggregate_ceiling_hits(observations: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {"iteration": sample["iteration"], **hit}
        for sample in observations
        for hit in sample["primary"].get("ceilingHits", [])
    ]


def scenario_report(
    scenario: Scenario,
    requested: int,
    observations: list[dict[str, Any]],
) -> dict[str, Any]:
    primary = [
        sample["primary"]
        for sample in observations
        if sample["primary"]["status"] != OutcomeStatus.NOT_RUN.value
    ]
    cli_wall_duration_ms = [
        item["cliWallDurationMs"]
        for item in primary
        if isinstance(item.get("cliWallDurationMs"), int)
    ]
    return {
        "name": scenario.name,
        "requested": requested,
        "recorded": len(observations),
        "productFailed": sum(item["status"] == OutcomeStatus.FAILED.value for item in primary),
        "infrastructureFailed": sum(
            sample["infrastructure"]["status"] == OutcomeStatus.FAILED.value
            for sample in observations
        ),
        "recoveryFailed": sum(
            sample["recovery"]["status"] == OutcomeStatus.FAILED.value
            for sample in observations
        ),
        "cliWallDurationMs": timing_statistics(cli_wall_duration_ms),
        "receiptTimingMs": aggregate_receipt_timing(observations),
        "ceilingHits": aggregate_ceiling_hits(observations),
        "samples": observations,
    }


def gate_summary(scenarios: list[dict[str, Any]]) -> dict[str, Any]:
    product_failed = sum(scenario["productFailed"] for scenario in scenarios)
    infrastructure_failed = sum(scenario["infrastructureFailed"] for scenario in scenarios)
    recovery_failed = sum(scenario["recoveryFailed"] for scenario in scenarios)
    failure_kinds = []
    if product_failed:
        failure_kinds.append("product-scenario-failure")
    if infrastructure_failed:
        failure_kinds.append("infrastructure-failure")
    if recovery_failed:
        failure_kinds.append("recovery-failure")
    cli_wall_duration_ms = [
        sample["primary"]["cliWallDurationMs"]
        for scenario in scenarios
        for sample in scenario["samples"]
        if isinstance(sample["primary"].get("cliWallDurationMs"), int)
    ]
    return {
        "requested": sum(scenario["requested"] for scenario in scenarios),
        "recorded": sum(scenario["recorded"] for scenario in scenarios),
        "productFailed": product_failed,
        "infrastructureFailed": infrastructure_failed,
        "recoveryFailed": recovery_failed,
        "cliWallDurationMs": timing_statistics(cli_wall_duration_ms),
        "failureKinds": failure_kinds,
    }


def gate_failed(summary: dict[str, Any]) -> bool:
    return any(
        summary[key]
        for key in ("productFailed", "infrastructureFailed", "recoveryFailed")
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the BH Demo adversarial lab nightly gate")
    parser.add_argument("--cli", default=os.environ.get("BUTTONHEIST_CLI", "ButtonHeistCLI/.build/debug/buttonheist"))
    parser.add_argument("--app", default=os.environ.get("BH_DEMO_APP"))
    parser.add_argument("--sim-udid", default=os.environ.get("SIM_UDID"))
    parser.add_argument("--repeat-count", type=int, default=int(os.environ.get("BUTTONHEIST_ADVERSARIAL_REPEAT_COUNT", "5")))
    parser.add_argument("--report", default=str(Path(os.environ.get("TMPDIR", "/tmp")) / "buttonheist-adversarial-nightly-report.json"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report_path = Path(args.report)
    report: dict[str, Any] = {
        "gate": "ios-demo-adversarial-lab-nightly",
        "status": "starting",
        "configuration": {"repeatCount": args.repeat_count},
        "scenarios": [],
        "summary": gate_summary([]),
    }
    write_json_report(report_path, report)

    try:
        if args.repeat_count < 1:
            raise RuntimeError("--repeat-count must be at least 1")
        if not args.app:
            raise RuntimeError("--app is required")
        if not args.sim_udid:
            raise RuntimeError("--sim-udid is required")
        cli = Path(args.cli).resolve()
        app_path = Path(args.app).resolve()
        if not cli.exists():
            raise RuntimeError(f"missing CLI: {cli}")
        if not (app_path / "BHDemo").exists():
            raise RuntimeError(f"missing BHDemo executable under {app_path}")

        scenarios = select_nightly_scenarios(load_catalog(cli))
        boot_simulator(args.sim_udid)
        install_app(args.sim_udid, app_path)

        report["status"] = "running"

        for scenario in scenarios:
            observations = execute_samples(
                args.repeat_count,
                lambda iteration, selected=scenario: execute_sample(
                    cli,
                    args.sim_udid,
                    selected,
                    iteration,
                ),
            )
            report["scenarios"].append(scenario_report(scenario, args.repeat_count, observations))
            report["summary"] = gate_summary(report["scenarios"])
            write_json_report(report_path, report)

        failed = gate_failed(report["summary"])
        report["status"] = "failed" if failed else "passed"
        report["failureKind"] = ", ".join(report["summary"]["failureKinds"]) if failed else "none"
        write_json_report(report_path, report)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 1 if failed else 0
    except Exception as error:
        report["status"] = "failed"
        report["failureKind"] = (
            "infrastructure-timeout"
            if isinstance(error, (TimeoutError, subprocess.TimeoutExpired))
            else "infrastructure-failure"
        )
        report["error"] = error_summary(error)
        write_json_report(report_path, report)
        print(f"Adversarial lab gate failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
