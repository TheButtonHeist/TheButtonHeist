#!/usr/bin/env python3
"""Verify source and prebuilt app integration in Debug and Release."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent


def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, text=True, **kwargs)


def verify_consumer(integration: str, archive: Path, cli: Path, simulator: str, token: str) -> None:
    target = f"{integration.title()}Consumer"
    app_id = f"com.buttonheist.{integration}-consumer"
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]

    with tempfile.TemporaryDirectory(prefix=f"insidejob-{integration}-") as temporary:
        consumer = Path(temporary) / "Consumer"
        shutil.copytree(ROOT / f"tests/fixtures/insidejob-{integration}-consumer", consumer)
        (consumer / "Tuist").mkdir()
        bundle = consumer / "TheInsideJob"
        frameworks = []
        if integration == "binary":
            run(["ditto", "-x", "-k", str(archive), str(consumer)])
            version = (bundle / "VERSION").read_text().strip()
            cli_version = subprocess.check_output([str(cli), "--version"], text=True).strip()
            if version != cli_version:
                raise RuntimeError(f"CLI version {cli_version} does not match bundle {version}")
            frameworks = sorted((bundle / "XCFrameworks").glob("*.xcframework"))
            if not any(path.stem == "TheInsideJob" for path in frameworks):
                raise RuntimeError("Bundle is missing TheInsideJob.xcframework")
            for framework in frameworks:
                with (framework / "Info.plist").open("rb") as metadata:
                    libraries = plistlib.load(metadata)["AvailableLibraries"]
                for library in libraries:
                    executable = framework / library["LibraryIdentifier"] / library["LibraryPath"] / framework.stem
                    headers = subprocess.check_output(["otool", "-hv", str(executable)], text=True)
                    if "DYLIB" not in headers.split():
                        raise RuntimeError(f"Prebuilt framework must be dynamic: {executable}")

        run(["tuist", "generate", "--path", str(consumer), "--no-open", "--no-binary-cache"],
            env={**os.environ, "TUIST_BUTTONHEIST_SOURCE_PACKAGE_PATH": str(ROOT)})
        run(["python3", str(ROOT / "scripts/clean-pbxproj.py"),
             str(consumer / f"{target}.xcodeproj/project.pbxproj")])

        try:
            for platform, configuration in (
                ("iphoneos", "Debug"), ("iphoneos", "Release"),
                ("iphonesimulator", "Debug"), ("iphonesimulator", "Release"),
            ):
                destination = ("generic/platform=iOS" if platform == "iphoneos"
                               else f"platform=iOS Simulator,id={simulator}")
                run(["xcodebuild", "-project", str(consumer / f"{target}.xcodeproj"),
                     "-scheme", target, "-configuration", configuration,
                     "-destination", destination,
                     "-derivedDataPath", str(consumer / "Build"), "CODE_SIGNING_ALLOWED=NO", "build"])
                app = consumer / f"Build/Build/Products/{configuration}-{platform}/{target}.app"
                executables = [app / target, *app.glob("*.dylib")]
                framework_names = {framework.stem for framework in frameworks}
                for executable in executables:
                    load_command = ""
                    for line in subprocess.check_output(["otool", "-l", str(executable)], text=True).splitlines():
                        fields = line.split()
                        if fields[:1] == ["cmd"]:
                            load_command = fields[1]
                        elif fields[:1] == ["name"] and load_command == "LC_LOAD_DYLIB":
                            if Path(fields[1]).parent.stem in framework_names:
                                raise RuntimeError(f"Runtime must be weak-linked: {fields[1]}")
                for framework in frameworks:
                    embedded = app / "Frameworks" / f"{framework.stem}.framework"
                    if embedded.exists() != (configuration == "Debug"):
                        raise RuntimeError(f"Incorrect {configuration} embedding: {embedded}")
                for resource in (bundle / "Resources" / platform).glob("*.bundle"):
                    if (app / resource.name).exists() != (configuration == "Debug"):
                        raise RuntimeError(f"Incorrect {configuration} resource embedding: {resource.name}")
                if integration == "source" and configuration == "Release":
                    for executable in executables:
                        symbols = subprocess.check_output(["nm", "-g", str(executable)], text=True)
                        if "TheInsideJob_autoStartFromLoad" in symbols or "ThePlantAutoStart" in symbols:
                            raise RuntimeError(f"Release source app contains the Debug loader: {executable}")
                if platform == "iphoneos":
                    continue
                run(["xcrun", "simctl", "install", simulator, str(app)])
                environment = {**os.environ, "SIMCTL_CHILD_INSIDEJOB_PORT": str(port),
                               "SIMCTL_CHILD_INSIDEJOB_TOKEN": token, "SIMCTL_CHILD_INSIDEJOB_ID": token}
                run(["xcrun", "simctl", "launch", simulator, app_id], env=environment)
                if configuration == "Debug":
                    deadline = time.monotonic() + 60
                    while True:
                        response = subprocess.run(
                            [str(cli), "get_interface", "--format", "json", "--quiet", "--connect-timeout", "3"],
                            env={**os.environ, "BUTTONHEIST_DEVICE": f"127.0.0.1:{port}",
                                 "BUTTONHEIST_TOKEN": token, "BUTTONHEIST_DRIVER_ID": token},
                            capture_output=True, text=True, timeout=15,
                        )
                        if response.returncode == 0 and "InsideJob integration consumer" in response.stdout:
                            payload = json.loads(response.stdout)
                            if payload.get("status") == "ok":
                                break
                        if time.monotonic() >= deadline:
                            raise RuntimeError(f"Debug runtime capture failed: {response.stdout}\n{response.stderr}")
                else:
                    try:
                        connection = socket.create_connection(("127.0.0.1", port), timeout=1)
                    except OSError:
                        pass
                    else:
                        connection.close()
                        raise RuntimeError("Release app has a running Debug listener")
                run(["xcrun", "simctl", "terminate", simulator, app_id])
        finally:
            subprocess.run(["xcrun", "simctl", "terminate", simulator, app_id], capture_output=True)
            subprocess.run(["xcrun", "simctl", "uninstall", simulator, app_id], capture_output=True)
    print(f"PASS: {integration} Debug auto-starts and captures; Release excludes the runtime", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("cli", type=Path)
    parser.add_argument("simulator")
    args = parser.parse_args()
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
    token = next(device["name"] for group in devices["devices"].values()
                 for device in group if device["udid"] == args.simulator)
    for integration in ("binary", "source"):
        verify_consumer(integration, args.archive.resolve(), args.cli.resolve(), args.simulator, token)


if __name__ == "__main__":
    main()
