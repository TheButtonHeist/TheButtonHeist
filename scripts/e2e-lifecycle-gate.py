#!/usr/bin/env python3
"""End-to-end lifecycle gate for BHDemo and the Button Heist CLI.

This script exercises the production lifecycle cases that unit tests and the
happy-path demo smoke do not prove: session locks, reconnect after app relaunch,
and background/foreground behavior. It fails when a command hangs, returns
unstructured output, or crashes the host app.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import random
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from e2e_runtime import (  # noqa: E402
    DemoApp,
    boot_simulator,
    error_summary,
    failure_kind,
    free_port,
    install_app,
    parse_jsonish,
    run,
    write_json_report,
)

DEFAULT_REPORT = Path(os.environ.get("TMPDIR", "/tmp")) / "buttonheist-lifecycle-report.json"
TRANSIENT_FLOW_ROUTE_PLAN = '''HeistPlan("LifecycleRoute") {
    WaitFor(.exists(.label("Transient Flow")), timeout: 4)
    Activate(.label("Transient Flow")).expect(.screenChanged, timeout: 4)
    WaitFor(.exists(.label("Submit")), timeout: 4)
}'''
ACTIVE_LIFECYCLE_PLAN = '''HeistPlan("LifecycleBackgroundForeground") {
    WaitFor(.exists(.label("Submit")), timeout: 4)
    Activate(.label("Submit"))
        .withoutExpectation("The lifecycle gate owns the active expectation transition")
    WaitFor(.exists(.label("Transaction complete")), timeout: 8)
}'''
ACTIVE_LIFECYCLE_DRIVER = "lifecycle-active-driver"
ACTIVE_LIFECYCLE_PROBE_DRIVER = "lifecycle-active-probe"
TRANSIENT_FLOW_ROUTE_FACT = "Transient Flow"


def write_report(path: Path, report: dict[str, Any]) -> None:
    write_json_report(path, report)


def lifecycle_failure_kind(error: BaseException, *, scenario_started: bool) -> str:
    return failure_kind(
        error,
        scenario_started=scenario_started,
        product_failure="product-lifecycle-failure",
        setup_failure="infrastructure-setup-failure",
    )


def contains_text(obj: Any | None, needle: str) -> bool:
    return needle in json.dumps(obj, sort_keys=True) if obj is not None else False


def choose_simulator(explicit: str | None) -> str:
    if explicit:
        return explicit
    if os.environ.get("BH_LIFECYCLE_SIM"):
        return os.environ["BH_LIFECYCLE_SIM"]
    data = json.loads(run(["xcrun", "simctl", "list", "-j", "devices", "available"]).stdout)
    candidates: list[dict[str, Any]] = []
    for runtime, devices in data["devices"].items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("state") == "Booted":
                candidates.append(device)
    if not candidates:
        raise RuntimeError("no booted iOS simulator found; pass --sim-udid or boot one first")
    for preferred in ("buttonheist-e2e-accra", "iPhone 16 Pro", "iPhone 17"):
        for device in candidates:
            if device.get("name") == preferred:
                return str(device["udid"])
    return str(candidates[0]["udid"])


def prepare_app(sim: str, app_path: str | None, demo_zip: str | None, work_dir: Path) -> Path:
    if app_path:
        app = Path(app_path)
        if not (app / "BHDemo").exists():
            raise RuntimeError(f"demo app did not contain executable at {app / 'BHDemo'}")
    elif demo_zip:
        archive = Path(demo_zip)
        if not archive.exists():
            raise RuntimeError(f"missing demo zip: {archive}")
        extract_dir = work_dir / "demo-app"
        if extract_dir.exists():
            shutil.rmtree(extract_dir)
        extract_dir.mkdir(parents=True)
        run(["ditto", "-x", "-k", str(archive), str(extract_dir)])
        app = extract_dir / "BHDemo.app"
        if not (app / "BHDemo").exists():
            raise RuntimeError(f"demo zip did not contain executable at {app / 'BHDemo'}")
    else:
        raise RuntimeError("pass --app or --demo-zip")

    install_app(sim, app)
    return app


class PersistentJSONLines:
    def __init__(self, cli: Path, app: DemoApp, driver_id: str):
        self.cli = cli
        self.app = app
        self.driver_id = driver_id
        env = os.environ.copy()
        env.update(
            {
                "BUTTONHEIST_TOKEN": app.token,
                "BUTTONHEIST_DRIVER_ID": driver_id,
            }
        )
        self.proc = subprocess.Popen(
            [
                str(cli),
                "json_lines",
                "--device",
                app.device,
                "--token",
                app.token,
                "--idle-timeout",
                "0",
                "--format",
                "json",
            ],
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.stdout: queue.Queue[str] = queue.Queue()
        self.stderr: queue.Queue[str] = queue.Queue()
        self._threads = [
            threading.Thread(target=self._reader, args=(self.proc.stdout, self.stdout), daemon=True),
            threading.Thread(target=self._reader, args=(self.proc.stderr, self.stderr), daemon=True),
        ]
        for thread in self._threads:
            thread.start()

    @staticmethod
    def _reader(stream: Any, out: queue.Queue[str]) -> None:
        if stream is None:
            return
        for line in stream:
            out.put(line)

    def command(self, payload: dict[str, Any], *, timeout: float = 20) -> Any:
        if self.proc.poll() is not None:
            raise RuntimeError(f"JSON-lines process exited early: {self.proc.returncode}")
        if self.proc.stdin is None:
            raise RuntimeError("JSON-lines stdin is unavailable")
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()
        deadline = time.time() + timeout
        non_json: list[str] = []
        while time.time() < deadline:
            try:
                line = self.stdout.get(timeout=0.2)
            except queue.Empty:
                if self.proc.poll() is not None:
                    raise RuntimeError(f"JSON-lines process exited while waiting: {self.proc.returncode}")
                continue
            stripped = line.strip()
            if not stripped:
                continue
            try:
                return json.loads(stripped)
            except json.JSONDecodeError:
                non_json.append(stripped)
        stderr_lines: list[str] = []
        while not self.stderr.empty():
            stderr_lines.append(self.stderr.get_nowait().strip())
        raise TimeoutError(f"timed out waiting for JSON; stdout={non_json}; stderr={stderr_lines}")

    def close(self) -> None:
        if self.proc.poll() is not None:
            return
        try:
            if self.proc.stdin is not None:
                self.proc.stdin.close()
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=3)


def cli_once(cli: Path, app: DemoApp, driver_id: str, command: str, *, connect_timeout: float, timeout: float = 20) -> dict[str, Any]:
    env = os.environ.copy()
    env.update(
        {
            "BUTTONHEIST_TOKEN": app.token,
            "BUTTONHEIST_DRIVER_ID": driver_id,
        }
    )
    result = run(
        [
            str(cli),
            command,
            "--device",
            app.device,
            "--token",
            app.token,
            "--connect-timeout",
            str(connect_timeout),
            "--format",
            "json",
            "--quiet",
        ],
        env=env,
        timeout=timeout,
        check=False,
    )
    return {
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "json": parse_jsonish(result.stdout) or parse_jsonish(result.stderr),
    }


def heist_command(
    cli: Path,
    app: DemoApp,
    plan: str,
    *,
    connect_timeout: float,
) -> list[str]:
    return [
        str(cli),
        "run_heist",
        "--plan",
        plan,
        "--device",
        app.device,
        "--token",
        app.token,
        "--connect-timeout",
        str(connect_timeout),
        "--format",
        "json",
        "--quiet",
    ]


def heist_environment(app: DemoApp, driver_id: str) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "BUTTONHEIST_TOKEN": app.token,
            "BUTTONHEIST_DRIVER_ID": driver_id,
        }
    )
    return env


def run_heist_once(
    cli: Path,
    app: DemoApp,
    driver_id: str,
    plan: str,
    *,
    connect_timeout: float,
    timeout: float = 20,
) -> dict[str, Any]:
    result = run(
        heist_command(cli, app, plan, connect_timeout=connect_timeout),
        env=heist_environment(app, driver_id),
        timeout=timeout,
        check=False,
    )
    return {
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "json": parse_jsonish(result.stdout) or parse_jsonish(result.stderr),
    }


def start_heist(
    cli: Path,
    app: DemoApp,
    driver_id: str,
    plan: str,
    *,
    connect_timeout: float,
    popen_factory: Any = subprocess.Popen,
) -> subprocess.Popen[str]:
    return popen_factory(
        heist_command(cli, app, plan, connect_timeout=connect_timeout),
        env=heist_environment(app, driver_id),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def collect_heist(process: subprocess.Popen[str], *, timeout: float) -> dict[str, Any]:
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        process.kill()
        stdout, stderr = process.communicate()
        raise TimeoutError(
            f"active run_heist did not complete within {timeout:g}s; "
            f"stdout={stdout!r}; stderr={stderr!r}"
        ) from error
    return {
        "returncode": process.returncode,
        "stdout": stdout,
        "stderr": stderr,
        "json": parse_jsonish(stdout) or parse_jsonish(stderr),
    }


def session_is_locked(response: dict[str, Any]) -> bool:
    return response["returncode"] != 0 and contains_text(response["json"], "session.locked")


def wait_for_active_heist(
    cli: Path,
    app: DemoApp,
    *,
    connect_timeout: float,
    timeout: float = 10,
    request: Any = cli_once,
    now: Any = time.monotonic,
    sleep: Any = time.sleep,
) -> list[dict[str, Any]]:
    deadline = now() + timeout
    attempts: list[dict[str, Any]] = []
    while now() < deadline:
        response = request(
            cli,
            app,
            ACTIVE_LIFECYCLE_PROBE_DRIVER,
            "get_interface",
            connect_timeout=connect_timeout,
            timeout=5,
        )
        attempts.append(response)
        if session_is_locked(response):
            return attempts
        sleep(0.2)
    raise AssertionError(f"active run_heist never acquired the session lock: attempts={attempts}")


def report_nodes(nodes: list[Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for node in nodes:
        if not isinstance(node, dict):
            raise AssertionError("run_heist report nodes must be objects")
        result.append(node)
        children = node.get("children")
        if not isinstance(children, list):
            raise AssertionError("run_heist report node children must be arrays")
        result.extend(report_nodes(children))
    return result


def terminal_lifecycle_outcome(response: dict[str, Any]) -> dict[str, Any]:
    if response["returncode"] == 124:
        raise AssertionError("active run_heist hung")
    payload = response["json"]
    if not isinstance(payload, dict):
        raise AssertionError(f"active run_heist returned no structured JSON: {response}")
    status = payload.get("status")
    if status not in {"ok", "partial"}:
        raise AssertionError(f"active run_heist returned a non-canonical status: {payload}")
    if status == "ok" and response["returncode"] != 0:
        raise AssertionError("successful active run_heist must exit zero")
    if status == "partial" and response["returncode"] == 0:
        raise AssertionError("partial active run_heist must exit non-zero")
    report = payload.get("report")
    if not isinstance(report, dict):
        raise AssertionError("active run_heist response must contain a report")
    summary = report.get("summary")
    nodes = report.get("nodes")
    if not isinstance(summary, dict) or not isinstance(nodes, list):
        raise AssertionError("active run_heist report must contain summary and nodes")
    if summary.get("executedTopLevelStepCount") != 3:
        raise AssertionError(f"active run_heist must execute one three-step plan: {summary}")

    flattened = report_nodes(nodes)
    terminal = next((node for node in flattened if node.get("status") == "failed"), None)
    final_summaries = [
        node.get("evidence", {}).get("wait", {}).get("finalSummary")
        for node in flattened
        if isinstance(node.get("evidence"), dict)
    ]
    current_evidence = any(
        isinstance(summary, dict) and contains_text(summary, TRANSIENT_FLOW_ROUTE_FACT)
        for summary in final_summaries
    )
    if status == "ok":
        if terminal is not None:
            raise AssertionError(f"successful active run_heist reported a failed node: {terminal}")
        if not current_evidence:
            raise AssertionError("successful active run_heist omitted its current Transient Flow evidence")
        return {"outcome": "completed", "currentEvidence": True}

    if terminal is None:
        raise AssertionError("partial active run_heist must identify its failed terminal step")
    failure = terminal.get("failure")
    if not isinstance(failure, dict):
        raise AssertionError("partial active run_heist terminal step must carry typed failure evidence")
    category = failure.get("category")
    observed = failure.get("observed")
    cancelled = category == "wait" and isinstance(observed, str) and "cancel" in observed.lower()
    if not cancelled and not current_evidence:
        raise AssertionError(
            "active run_heist failure must be a canonical cancellation or contain current Transient Flow evidence"
        )
    return {
        "outcome": "cancelled" if cancelled else "current-evidence-failure",
        "currentEvidence": current_evidence,
        "failureCategory": category,
    }


def assert_success(response: Any, label: str) -> Any:
    if response is None:
        raise AssertionError(f"{label}: no JSON response")
    if isinstance(response, dict) and response.get("status") == "error":
        raise AssertionError(f"{label}: error response: {json.dumps(response, sort_keys=True)}")
    return response


def one_shot_success(result: dict[str, Any], label: str) -> Any:
    if result["returncode"] != 0:
        raise AssertionError(f"{label}: command failed: {result}")
    return assert_success(result["json"], label)


def wait_one_shot_success(
    cli: Path,
    app: DemoApp,
    driver_id: str,
    command: str,
    label: str,
    *,
    connect_timeout: float,
    timeout: float = 15,
) -> tuple[Any, list[dict[str, Any]]]:
    deadline = time.time() + timeout
    attempts: list[dict[str, Any]] = []
    while time.time() < deadline:
        result = cli_once(cli, app, driver_id, command, connect_timeout=connect_timeout, timeout=8)
        attempts.append(
            {
                "returncode": result["returncode"],
                "json": result["json"],
                "stderr": result["stderr"],
            }
        )
        if result["returncode"] == 0:
            try:
                return assert_success(result["json"], label), attempts
            except AssertionError:
                pass
        time.sleep(0.5)
    raise AssertionError(f"{label}: did not recover before timeout; attempts={attempts}")


def start_app(sim: str, label: str, timeout: float) -> tuple[DemoApp, int | None]:
    port = free_port()
    token = f"lifecycle-{label}-{random.randint(1000, 9999)}"
    app = DemoApp(sim, port=port, token=token, session_timeout=timeout)
    app.terminate()
    return app, app.launch(attempts=3)


def scenario_session_lock(cli: Path, sim: str, connect_timeout: float) -> dict[str, Any]:
    app, pid = start_app(sim, "lock", timeout=2.0)
    session = PersistentJSONLines(cli, app, "driver-a")
    try:
        first = session.command({"command": "get_interface"}, timeout=20)
        assert_success(first, "driver-a persistent initial interface")
        other_driver = cli_once(cli, app, "driver-b", "get_interface", connect_timeout=connect_timeout)
        if other_driver["returncode"] == 0 or not contains_text(other_driver["json"], "session.locked"):
            raise AssertionError(f"different driver should receive session.locked: {other_driver}")
        session.close()
        same_driver_drain = cli_once(cli, app, "driver-a", "get_interface", connect_timeout=connect_timeout)
        one_shot_success(same_driver_drain, "same driver during drain")
        draining_driver = cli_once(cli, app, "driver-b", "get_interface", connect_timeout=connect_timeout)
        if draining_driver["returncode"] == 0 or not contains_text(draining_driver["json"], "session.locked"):
            raise AssertionError(f"different driver should remain locked during drain: {draining_driver}")
        if app.session_timeout is None:
            raise AssertionError("session lock scenario requires a server timeout")
        time.sleep(app.session_timeout + 1.25)
        released_driver = cli_once(cli, app, "driver-b", "get_interface", connect_timeout=connect_timeout)
        one_shot_success(released_driver, "different driver after lock timeout")
        return {
            "initial_pid": pid,
            "same_driver_drain_returncode": same_driver_drain["returncode"],
            "locked_code_seen": contains_text(other_driver["json"], "session.locked"),
            "drain_lock_seen": contains_text(draining_driver["json"], "session.locked"),
            "release_returncode": released_driver["returncode"],
        }
    finally:
        session.close()
        app.terminate()


def scenario_reconnect(cli: Path, sim: str) -> dict[str, Any]:
    app, pid1 = start_app(sim, "reconnect", timeout=5.0)
    session = PersistentJSONLines(cli, app, "reconnect-driver")
    try:
        before = session.command({"command": "get_interface"}, timeout=20)
        assert_success(before, "persistent session before app restart")
        app.terminate(require_stopped=True)
        time.sleep(1.0)
        pid2 = app.launch()
        if pid1 is None or pid2 is None:
            raise AssertionError(f"reconnect scenario could not prove process identity: before={pid1} after={pid2}")
        if pid1 == pid2:
            raise AssertionError(f"reconnect scenario did not relaunch BHDemo: pid stayed {pid1}")
        after = session.command({"command": "get_interface"}, timeout=30)
        assert_success(after, "persistent session after app restart")
        return {"pid_before": pid1, "pid_after": pid2, "pid_changed": pid1 != pid2}
    finally:
        session.close()
        app.terminate()


def background_app(sim: str) -> dict[str, Any]:
    result = run(["xcrun", "simctl", "launch", sim, "com.apple.Preferences"], check=False, timeout=20)
    if result.returncode == 0:
        return {"method": "settings", "stdout": result.stdout.strip()}
    fallback = run(["xcrun", "simctl", "ui", sim, "home"], check=False, timeout=20)
    return {
        "method": "home",
        "settings_error": result.stderr.strip(),
        "returncode": fallback.returncode,
        "stdout": fallback.stdout.strip(),
        "stderr": fallback.stderr.strip(),
    }


def scenario_background_foreground(cli: Path, sim: str, connect_timeout: float) -> dict[str, Any]:
    app, pid1 = start_app(sim, "background", timeout=3.0)
    try:
        foreground_before = cli_once(cli, app, "bg-driver", "get_interface", connect_timeout=connect_timeout)
        one_shot_success(foreground_before, "foreground get_interface before background")
        background_method = background_app(sim)
        time.sleep(1.0)
        while_background = cli_once(cli, app, "bg-driver", "get_interface", connect_timeout=connect_timeout, timeout=25)
        if while_background["json"] is None:
            raise AssertionError(f"background command did not return structured JSON: {while_background}")
        if (
            while_background["returncode"] == 0
            or not isinstance(while_background["json"], dict)
            or while_background["json"].get("status") != "error"
        ):
            raise AssertionError(f"background command should return a structured error: {while_background}")
        pid2 = app.launch()
        if pid1 is None or pid2 is None:
            raise AssertionError(f"background scenario could not prove process identity: before={pid1} after={pid2}")
        if pid1 != pid2:
            raise AssertionError(f"BHDemo relaunched during background/foreground scenario: before={pid1} after={pid2}")
        _, foreground_attempts = wait_one_shot_success(
            cli,
            app,
            "bg-driver",
            "get_interface",
            "foreground get_interface after background",
            connect_timeout=connect_timeout,
            timeout=15,
        )
        return {
            "pid_before": pid1,
            "pid_after_foreground": pid2,
            "same_pid_after_foreground": pid1 == pid2,
            "background_method": background_method,
            "background_returncode": while_background["returncode"],
            "background_structured": while_background["json"] is not None,
            "foreground_attempt_count": len(foreground_attempts),
            "foreground_transient_failures": [
                attempt for attempt in foreground_attempts if attempt["returncode"] != 0
            ],
        }
    finally:
        app.terminate()


def scenario_active_execution_lifecycle(
    cli: Path,
    sim: str,
    connect_timeout: float,
) -> dict[str, Any]:
    app, pid_before = start_app(sim, "active-execution", timeout=5.0)
    process: subprocess.Popen[str] | None = None
    try:
        route = run_heist_once(
            cli,
            app,
            ACTIVE_LIFECYCLE_DRIVER,
            TRANSIENT_FLOW_ROUTE_PLAN,
            connect_timeout=connect_timeout,
        )
        one_shot_success(route, "open Transient Flow before active lifecycle execution")

        process = start_heist(
            cli,
            app,
            ACTIVE_LIFECYCLE_DRIVER,
            ACTIVE_LIFECYCLE_PLAN,
            connect_timeout=connect_timeout,
        )
        lock_attempts = wait_for_active_heist(
            cli,
            app,
            connect_timeout=connect_timeout,
        )
        background_method = background_app(sim)
        time.sleep(1.0)
        pid_after_foreground = app.launch()
        if pid_before is None or pid_after_foreground is None:
            raise AssertionError(
                "active lifecycle scenario could not prove process identity: "
                + f"before={pid_before} after={pid_after_foreground}"
            )
        if pid_before != pid_after_foreground:
            raise AssertionError(
                "BHDemo relaunched during active lifecycle execution: "
                + f"before={pid_before} after={pid_after_foreground}"
            )

        terminal = collect_heist(process, timeout=20)
        process = None
        outcome = terminal_lifecycle_outcome(terminal)
        foreground, attempts = wait_one_shot_success(
            cli,
            app,
            ACTIVE_LIFECYCLE_DRIVER,
            "get_interface",
            "foreground command after active lifecycle execution",
            connect_timeout=connect_timeout,
            timeout=15,
        )
        if not contains_text(foreground, TRANSIENT_FLOW_ROUTE_FACT):
            raise AssertionError("foreground interface after active lifecycle execution lost the current route")
        return {
            "pid_before": pid_before,
            "pid_after_foreground": pid_after_foreground,
            "same_pid_after_foreground": pid_before == pid_after_foreground,
            "background_method": background_method,
            "session_lock_attempt_count": len(lock_attempts),
            "session_lock_seen": True,
            "terminal_returncode": terminal["returncode"],
            "terminal": outcome,
            "foreground_attempt_count": len(attempts),
            "foreground_transient_failures": [
                attempt for attempt in attempts if attempt["returncode"] != 0
            ],
        }
    finally:
        if process is not None:
            process.kill()
            process.communicate()
        app.terminate()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run BHDemo lifecycle release gate")
    parser.add_argument("--cli", default=os.environ.get("BUTTONHEIST_CLI", "ButtonHeistCLI/.build/debug/buttonheist"))
    parser.add_argument("--app", default=os.environ.get("BH_DEMO_APP"))
    parser.add_argument("--demo-zip", default=os.environ.get("BH_DEMO_ZIP"))
    parser.add_argument("--sim-udid", default=os.environ.get("BH_LIFECYCLE_SIM"))
    parser.add_argument("--report", default=str(DEFAULT_REPORT))
    parser.add_argument("--connect-timeout", type=float, default=float(os.environ.get("BH_CONNECT_TIMEOUT", "5")))
    parser.add_argument("--work-dir", default=str(Path(os.environ.get("TMPDIR", "/tmp")) / "buttonheist-lifecycle-gate"))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    report_path = Path(args.report)
    cli = Path(args.cli).resolve()
    report = {
        "cli": str(cli),
        "version": "",
        "simulator": "",
        "demo_app": "",
        "status": "starting",
        "scenarios": {},
    }

    try:
        if not cli.exists():
            raise RuntimeError(f"missing CLI: {cli}")
        work_dir = Path(args.work_dir)
        work_dir.mkdir(parents=True, exist_ok=True)
        sim = choose_simulator(args.sim_udid)
        report["simulator"] = sim
        report["status"] = "booting-simulator"
        write_report(report_path, report)
        boot_simulator(sim)
        app = prepare_app(sim, args.app, args.demo_zip, work_dir)
        report["demo_app"] = str(app)
        version = run([str(cli), "--version"]).stdout.strip()
        report["version"] = version
        report["status"] = "running"
        write_report(report_path, report)

        scenarios = [
            ("session_lock", lambda: scenario_session_lock(cli, sim, args.connect_timeout)),
            ("reconnect", lambda: scenario_reconnect(cli, sim)),
            ("background_foreground", lambda: scenario_background_foreground(cli, sim, args.connect_timeout)),
            ("active_execution_lifecycle", lambda: scenario_active_execution_lifecycle(
                cli,
                sim,
                args.connect_timeout,
            )),
        ]
        for name, run_scenario in scenarios:
            report["current_scenario"] = name
            write_report(report_path, report)
            try:
                report["scenarios"][name] = run_scenario()
            except Exception as exc:
                report["status"] = "failed"
                report["failureKind"] = lifecycle_failure_kind(exc, scenario_started=True)
                report["failed_scenario"] = name
                report["scenarios"][name] = {
                    "status": "failed",
                    "error": error_summary(exc),
                }
                write_report(report_path, report)
                raise
            write_report(report_path, report)

        report.pop("current_scenario", None)
        report["status"] = "passed"
        report["failureKind"] = "none"
        write_report(report_path, report)
        print(json.dumps(report, indent=2, sort_keys=True))
    except Exception as exc:
        report["status"] = "failed"
        report.setdefault(
            "failureKind",
            lifecycle_failure_kind(exc, scenario_started="current_scenario" in report),
        )
        report["error"] = error_summary(exc)
        write_report(report_path, report)
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - script gate needs the concrete failure in CI logs.
        print(f"Lifecycle gate failed: {exc}", file=sys.stderr)
        raise
