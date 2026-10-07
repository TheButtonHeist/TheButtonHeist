"""Shared simulator runtime primitives for Python E2E gates."""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import time
import traceback
from pathlib import Path
from typing import Any


BUNDLE_ID = "com.buttonheist.testapp"


def run(
    cmd: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: str | Path | None = None,
    input: str | None = None,
    timeout: float = 60,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            cmd,
            cwd=cwd,
            env=env,
            input=input,
            timeout=timeout,
            text=True,
            capture_output=True,
        )
    except subprocess.TimeoutExpired as error:
        if check:
            raise
        stdout = error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
        stderr = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
        timeout_message = f"timed out after {timeout:g} seconds"
        message = f"{stderr}\n{timeout_message}" if stderr else timeout_message
        result = subprocess.CompletedProcess(cmd, 124, stdout, message)
    if check and result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(cmd)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def port_is_open(port: int, *, timeout: float = 0.25) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


def wait_port(port: int, *, open_expected: bool = True, timeout: float = 20) -> None:
    deadline = time.time() + timeout
    last_error: OSError | None = None
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.25):
                if open_expected:
                    return
        except OSError as error:
            last_error = error
            if not open_expected:
                return
        time.sleep(0.1)
    if open_expected:
        raise TimeoutError(f"port {port} did not open: {last_error}")
    raise TimeoutError(f"port {port} did not close")


def resolve_ios_runtime(requested: str | None = None) -> str:
    data = json.loads(run(["xcrun", "simctl", "list", "runtimes", "-j"]).stdout)
    runtimes = [
        runtime
        for runtime in data.get("runtimes", [])
        if runtime.get("platform") == "iOS" and runtime.get("isAvailable") is True
    ]
    if requested:
        for runtime in runtimes:
            if requested in (runtime.get("identifier"), runtime.get("name"), runtime.get("version")):
                return str(runtime["identifier"])
        raise RuntimeError(f"iOS runtime not found: {requested}")
    if not runtimes:
        raise RuntimeError("iOS runtime not found: latest available")

    def version(runtime: dict[str, Any]) -> tuple[int, ...]:
        return tuple(int(component) for component in str(runtime.get("version", "0")).split("."))

    return str(max(runtimes, key=version)["identifier"])


def simulator_ids_named(name: str) -> list[str]:
    data = json.loads(run(["xcrun", "simctl", "list", "devices", "-j"]).stdout)
    return [
        str(device["udid"])
        for devices in data.get("devices", {}).values()
        for device in devices
        if device.get("name") == name
    ]


def delete_simulator(sim: str) -> None:
    run(["xcrun", "simctl", "shutdown", sim], check=False, timeout=30)
    run(["xcrun", "simctl", "delete", sim], check=False, timeout=30)


def delete_simulators_named(name: str) -> None:
    for sim in simulator_ids_named(name):
        delete_simulator(sim)


def boot_simulator(sim: str) -> None:
    run(["xcrun", "simctl", "boot", sim], check=False, timeout=30)
    run(["xcrun", "simctl", "bootstatus", sim, "-b"], timeout=120)


def install_app(sim: str, app: Path) -> None:
    terminate_app(sim)
    run(["xcrun", "simctl", "uninstall", sim, BUNDLE_ID], check=False, timeout=20)
    run(["xcrun", "simctl", "install", sim, str(app)], timeout=120)


def launch_environment(
    port: int,
    token: str,
    instance_id: str,
    *,
    session_timeout: float | None = None,
) -> dict[str, str]:
    env = {
        **os.environ,
        "SIMCTL_CHILD_INSIDEJOB_PORT": str(port),
        "SIMCTL_CHILD_INSIDEJOB_TOKEN": token,
        "SIMCTL_CHILD_INSIDEJOB_ID": instance_id,
    }
    if session_timeout is not None:
        env["SIMCTL_CHILD_INSIDEJOB_SESSION_TIMEOUT"] = str(session_timeout)
    return env


def launch_app(sim: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return run(["xcrun", "simctl", "launch", sim, BUNDLE_ID], env=env, timeout=45, check=False)


def terminate_app(sim: str) -> subprocess.CompletedProcess[str]:
    return run(["xcrun", "simctl", "terminate", sim, BUNDLE_ID], check=False, timeout=20)


def write_json_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def error_summary(error: BaseException) -> dict[str, Any]:
    return {
        "type": type(error).__name__,
        "message": str(error),
        "traceback": traceback.format_exception(type(error), error, error.__traceback__),
    }


def failure_kind(
    error: BaseException,
    *,
    scenario_started: bool,
    product_failure: str,
    setup_failure: str = "infrastructure-failure",
) -> str:
    if scenario_started:
        return product_failure
    if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)):
        return "infrastructure-timeout"
    return setup_failure


def parse_jsonish(text: str | None) -> Any | None:
    text = (text or "").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    return None


class DemoApp:
    def __init__(
        self,
        sim: str,
        *,
        port: int | None = None,
        token: str | None = None,
        app_id: str | None = None,
        session_timeout: float | None = None,
        token_prefix: str = "buttonheist-e2e",
    ):
        self.sim = sim
        self.port = port or free_port()
        self.token = token or f"{token_prefix}-{self.port}"
        self.app_id = app_id or self.token
        self.session_timeout = session_timeout
        self.pid: int | None = None

    @property
    def device(self) -> str:
        return f"127.0.0.1:{self.port}"

    def launch(self, *, attempts: int = 1, wait_timeout: float = 45) -> int | None:
        env = launch_environment(
            self.port,
            self.token,
            self.app_id,
            session_timeout=self.session_timeout,
        )
        failures: list[dict[str, Any]] = []
        for attempt in range(1, attempts + 1):
            if attempt > 1:
                terminate_app(self.sim)
                time.sleep(attempt)

            result = launch_app(self.sim, env)
            match = re.search(r":\s*(\d+)\s*$", result.stdout.strip())
            self.pid = int(match.group(1)) if match else None

            if result.returncode != 0:
                failures.append(
                    {
                        "attempt": attempt,
                        "returncode": result.returncode,
                        "stdout": result.stdout.strip(),
                        "stderr": result.stderr.strip(),
                    }
                )
                continue

            try:
                wait_port(self.port, open_expected=True, timeout=wait_timeout)
                return self.pid
            except TimeoutError as error:
                failures.append(
                    {
                        "attempt": attempt,
                        "pid": self.pid,
                        "returncode": result.returncode,
                        "stdout": result.stdout.strip(),
                        "stderr": result.stderr.strip(),
                        "error": str(error),
                    }
                )

        raise TimeoutError(f"BHDemo did not open port {self.port} after launch attempts: {failures}")

    def terminate(self, *, require_stopped: bool = False, close_timeout: float = 8) -> bool:
        result = terminate_app(self.sim)
        try:
            wait_port(self.port, open_expected=False, timeout=close_timeout)
            self.pid = None
            return True
        except TimeoutError:
            if require_stopped:
                raise AssertionError(
                    "terminate did not stop BHDemo or close the InsideJob port: "
                    + f"port={self.port} returncode={result.returncode} "
                    + f"stdout={result.stdout.strip()!r} stderr={result.stderr.strip()!r}"
                )
            return False

    def restart(
        self,
        *,
        close_timeout: float = 8,
        attempts: int = 1,
        wait_timeout: float = 45,
    ) -> int | None:
        self.terminate(require_stopped=True, close_timeout=close_timeout)
        return self.launch(attempts=attempts, wait_timeout=wait_timeout)
