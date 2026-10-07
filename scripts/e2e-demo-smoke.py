#!/usr/bin/env python3
"""Deterministic BH Demo smoke test through the Button Heist CLI."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import time
import zlib
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from e2e_runtime import (  # noqa: E402
    BUNDLE_ID,
    DemoApp,
    boot_simulator,
    delete_simulator,
    delete_simulators_named,
    install_app,
    parse_jsonish,
    port_is_open,
    resolve_ios_runtime,
    run,
)


class SmokeFailure(RuntimeError):
    """A setup or product-contract failure with an actionable message."""


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Deterministic end-to-end smoke test for BH Demo through the Button Heist CLI.",
        epilog=(
            "This harness is intentionally CLI-only: it does not require an MCP server "
            "or a loaded MCP host session."
        ),
    )
    result.add_argument("--keep-simulator", action="store_true", help="Leave a created simulator booted.")
    result.add_argument("--skip-generate", action="store_true", help="Skip project generation.")
    result.add_argument("--skip-cli-build", action="store_true", help="Reuse an already-built CLI binary.")
    result.add_argument("--sim-name", help="Simulator name. Defaults to buttonheist-e2e-{worktree}.")
    result.add_argument("--sim-udid", help="Reuse an existing simulator instead of creating one.")
    result.add_argument("--device-type", default="iPhone 16 Pro", help="Simulator device type.")
    result.add_argument("--runtime", help="Runtime identifier, name, or version. Defaults to latest iOS.")
    result.add_argument("--port", type=int, help="InsideJob port. Defaults to a stable worktree-derived port.")
    result.add_argument("--token", help="InsideJob token and driver ID. Defaults to the simulator name.")
    result.add_argument("--app", type=Path, help="Reuse a prebuilt BHDemo.app instead of building it.")
    result.add_argument(
        "--cli-configuration",
        choices=("debug", "release"),
        default="debug",
        help="SwiftPM CLI configuration.",
    )
    result.add_argument("--heist", type=Path, help="Heist fixture to replay.")
    result.add_argument("--skip-heist-playback", action="store_true", help="Skip heist replay.")
    result.add_argument("--results-dir", type=Path, help="Write heist result artifacts to this directory.")
    result.add_argument("--results-mode", choices=("failures", "all", "off"), help="Heist result mode.")
    return result


def sanitize_identifier(value: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", value.lower())).strip("-")


def stable_port(seed: str) -> int:
    return 20_000 + zlib.crc32(seed.encode()) % 10_000


def require_tool(name: str) -> None:
    if shutil.which(name) is None:
        raise SmokeFailure(f"missing required tool: {name}")


def require_executable(path: Path) -> None:
    if not path.is_file() or not os.access(path, os.X_OK):
        raise SmokeFailure(f"prebuilt ButtonHeistCLI binary not found at {path}")


def decode_response(result: Any, context: str) -> dict[str, Any]:
    payload = parse_jsonish(result.stdout) or parse_jsonish(result.stderr)
    if not isinstance(payload, dict):
        raise SmokeFailure(
            f"{context} output is not valid JSON: "
            f"returncode={result.returncode} stdout={result.stdout.strip()!r} "
            f"stderr={result.stderr.strip()!r}"
        )
    if result.returncode != 0:
        raise SmokeFailure(f"{context} failed: {json.dumps(payload, sort_keys=True)}")
    return payload


def expect_ok(payload: dict[str, Any], context: str) -> None:
    status = payload.get("status", "missing")
    if status != "ok":
        raise SmokeFailure(f"{context} failed: expected status=ok, got {status}")


def expect_screen_title(payload: dict[str, Any], expected: str) -> None:
    try:
        actual = payload["interface"]["navigation"].get("screenTitle", "")
    except (KeyError, TypeError):
        actual = ""
    if actual != expected:
        raise SmokeFailure(f"expected screen title {expected!r}, got {actual!r}")


def canonical_target(payload: dict[str, Any], label: str) -> Any:
    matches: list[Any] = []

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            element = value.get("element")
            if isinstance(element, dict) and element.get("label") == label:
                matches.append(element.get("target"))
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    try:
        visit(payload["interface"]["tree"])
    except (KeyError, TypeError) as error:
        raise SmokeFailure("get_interface response did not contain an interface tree") from error
    if len(matches) != 1 or matches[0] is None:
        raise SmokeFailure(f"{label} did not have one canonical target")
    return matches[0]


class SmokeCLI:
    def __init__(self, binary: Path, app: DemoApp):
        self.binary = binary
        self.app = app
        self.connect_timeout = os.environ.get("BUTTONHEIST_CONNECT_TIMEOUT", "10")
        try:
            self.root_view_attempts = int(os.environ.get("BUTTONHEIST_ROOT_VIEW_RETRY_ATTEMPTS", "4"))
        except ValueError as error:
            raise SmokeFailure("BUTTONHEIST_ROOT_VIEW_RETRY_ATTEMPTS must be an integer") from error
        if self.root_view_attempts < 1:
            raise SmokeFailure("BUTTONHEIST_ROOT_VIEW_RETRY_ATTEMPTS must be at least 1")

    @property
    def environment(self) -> dict[str, str]:
        return {
            **os.environ,
            "BUTTONHEIST_DEVICE": self.app.device,
            "BUTTONHEIST_TOKEN": self.app.token,
            "BUTTONHEIST_DRIVER_ID": self.app.token,
        }

    def command(self, context: str, *arguments: str) -> dict[str, Any]:
        command = [
            str(self.binary),
            *arguments,
            "--connect-timeout",
            self.connect_timeout,
            "--format",
            "json",
            "--quiet",
        ]
        for attempt in range(1, self.root_view_attempts + 1):
            result = run(command, env=self.environment, timeout=60, check=False)
            output = f"{result.stdout}\n{result.stderr}"
            retryable = '"message":"Action failed: Could not access root view"' in output
            if result.returncode == 0 or attempt == self.root_view_attempts or not retryable:
                return decode_response(result, context)
            time.sleep(1)
        raise AssertionError("unreachable")

    def json_lines(self, context: str, request: dict[str, Any]) -> dict[str, Any]:
        command = [
            str(self.binary),
            "json_lines",
            "--device",
            self.app.device,
            "--token",
            self.app.token,
            "--timeout",
            self.connect_timeout,
            "--idle-timeout",
            "0",
            "--format",
            "json",
        ]
        result = run(
            command,
            env=self.environment,
            input=json.dumps(request) + "\n",
            timeout=60,
            check=False,
        )
        return decode_response(result, context)


def create_simulator(name: str, device_type: str, runtime: str | None) -> str:
    delete_simulators_named(name)
    runtime_id = resolve_ios_runtime(runtime)
    return run(["xcrun", "simctl", "create", name, device_type, runtime_id]).stdout.strip()


def build_demo(repo_root: Path, sim: str, derived_data: Path) -> Path:
    shutil.rmtree(derived_data, ignore_errors=True)
    result = run(
        [
            "xcodebuild",
            "-workspace",
            "ButtonHeist.xcworkspace",
            "-scheme",
            "BH Demo",
            "-destination",
            f"platform=iOS Simulator,id={sim}",
            "-derivedDataPath",
            str(derived_data),
            "build",
        ],
        cwd=repo_root,
        timeout=600,
        check=False,
    )
    if result.returncode != 0:
        raise SmokeFailure(
            "BH Demo build failed\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return derived_data / "Build/Products/Debug-iphonesimulator/BHDemo.app"


def exercise(cli: SmokeCLI, heist: Path, *, skip_heist_playback: bool) -> None:
    session = cli.command("get_session_state", "get_session_state")
    expect_ok(session, "get_session_state")
    if session.get("connected") is not True:
        raise SmokeFailure("session state failed: expected connected=true")

    ready = cli.command(
        "wait for demo root",
        "wait",
        "--exists",
        "--label",
        "Controls Demo",
        "--traits",
        "button",
        "--timeout",
        "15",
    )
    expect_ok(ready, "wait for demo root")

    root = cli.json_lines("root get_interface", {"command": "get_interface"})
    expect_ok(root, "root get_interface")
    expect_screen_title(root, "ButtonHeist Demo")

    controls = cli.json_lines(
        "activate Controls Demo",
        {"command": "activate", "target": canonical_target(root, "Controls Demo")},
    )
    expect_ok(controls, "activate Controls Demo")
    controls_interface = cli.json_lines("Controls Demo get_interface", {"command": "get_interface"})
    expect_ok(controls_interface, "Controls Demo get_interface")
    expect_screen_title(controls_interface, "Controls Demo")

    if skip_heist_playback:
        return

    back = cli.command(
        "activate back to ButtonHeist Demo",
        "activate",
        "--label",
        "ButtonHeist Demo",
        "--traits",
        "backButton",
        "--timeout",
        "15",
    )
    expect_ok(back, "activate back to ButtonHeist Demo")
    playback_root = cli.command("playback root get_interface", "get_interface")
    expect_ok(playback_root, "playback root get_interface")
    expect_screen_title(playback_root, "ButtonHeist Demo")

    playback = cli.command("run_heist", "run_heist", "--path", str(heist))
    expect_ok(playback, "run_heist")
    final = cli.command("playback final get_interface", "get_interface")
    expect_ok(final, "playback final get_interface")
    expect_screen_title(final, "Display")


def execute(args: argparse.Namespace) -> None:
    repo_root = SCRIPT_DIR.parent
    worktree_id = sanitize_identifier(repo_root.name) or "workspace"
    sim_name = args.sim_name or f"buttonheist-e2e-{worktree_id}"
    token = args.token or sim_name
    port = args.port if args.port is not None else stable_port(str(repo_root))
    if not 1024 <= port <= 65535:
        raise SmokeFailure("port must be between 1024 and 65535")

    heist = args.heist or repo_root / "tests/fixtures/bh-demo-smoke.heist"
    if not args.skip_heist_playback and not heist.exists():
        raise SmokeFailure(f"heist fixture not found at {heist}")

    cli_binary = repo_root / "ButtonHeistCLI/.build" / args.cli_configuration / "buttonheist"
    if args.skip_cli_build:
        require_executable(cli_binary)
    if args.app is not None and not args.app.is_dir():
        raise SmokeFailure(f"built app not found at {args.app}")
    if port_is_open(port):
        raise SmokeFailure(f"port {port} is already in use; pass --port to choose a deterministic alternate")

    require_tool("xcrun")
    if not args.skip_generate or args.app is None:
        require_tool("xcodebuild")
    if not args.skip_cli_build:
        require_tool("swift")

    if args.results_dir is not None:
        os.environ["BUTTONHEIST_RESULTS_DIR"] = str(args.results_dir)
    if args.results_mode is not None:
        os.environ["BUTTONHEIST_RESULTS_MODE"] = args.results_mode

    print("Demo smoke configuration:")
    print(f"    worktree: {repo_root}")
    print(f"    simulator: {sim_name}")
    print(f"    endpoint: 127.0.0.1:{port}")
    print(f"    token/id: {token}")
    print(f"    cli config: {args.cli_configuration}")
    if args.results_dir is not None:
        print(f"    results: {args.results_dir} ({args.results_mode or 'failures'})")
    if not args.skip_heist_playback:
        print(f"    heist: {heist}")

    derived_data = Path(tempfile.gettempdir()) / f"buttonheist-e2e-{worktree_id}-derived-data"
    sim = args.sim_udid
    owns_simulator = False
    launched_app: DemoApp | None = None
    try:
        if not args.skip_generate:
            run([str(repo_root / "scripts/generate-project.sh")], cwd=repo_root, timeout=600)
        if not args.skip_cli_build:
            run(
                ["swift", "build", "-c", args.cli_configuration, "--quiet"],
                cwd=repo_root / "ButtonHeistCLI",
                timeout=600,
            )

        if sim is None:
            sim = create_simulator(sim_name, args.device_type, args.runtime)
            owns_simulator = True
        boot_simulator(sim)

        app_path = args.app or build_demo(repo_root, sim, derived_data)
        if not app_path.is_dir():
            raise SmokeFailure(f"built app not found at {app_path}")
        install_app(sim, app_path)

        launched_app = DemoApp(sim, port=port, token=token, app_id=token)
        launched_app.launch(wait_timeout=30)
        exercise(SmokeCLI(cli_binary, launched_app), heist, skip_heist_playback=args.skip_heist_playback)
        print("Demo smoke test passed.")
    finally:
        if launched_app is not None:
            launched_app.terminate()
        if sim is not None and owns_simulator:
            if args.keep_simulator:
                print(f"Kept simulator {sim_name} ({sim}).")
            else:
                delete_simulator(sim)
        shutil.rmtree(derived_data, ignore_errors=True)


def main() -> int:
    try:
        execute(parser().parse_args())
        return 0
    except (SmokeFailure, RuntimeError, TimeoutError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
