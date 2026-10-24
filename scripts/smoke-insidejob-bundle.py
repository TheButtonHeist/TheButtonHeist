#!/usr/bin/env python3
"""Build an external Tuist consumer from the zip and check Debug/Release behavior."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
APP_ID = "com.buttonheist.binary-consumer"


def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, text=True, **kwargs)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("cli", type=Path)
    parser.add_argument("simulator")
    args = parser.parse_args()
    cli = args.cli.resolve()
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
    token = next(device["name"] for group in devices["devices"].values()
                 for device in group if device["udid"] == args.simulator)
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]

    with tempfile.TemporaryDirectory(prefix="insidejob-consumer-") as temporary:
        consumer = Path(temporary) / "Consumer"
        shutil.copytree(ROOT / "tests/fixtures/insidejob-binary-consumer", consumer)
        (consumer / "Tuist").mkdir()
        run(["ditto", "-x", "-k", str(args.archive.resolve()), str(consumer)])
        bundle = consumer / "TheInsideJob"
        version = (bundle / "VERSION").read_text().strip()
        cli_version = subprocess.check_output([str(cli), "--version"], text=True)
        if version not in cli_version.split():
            raise RuntimeError(f"CLI version {cli_version.strip()} does not match bundle {version}")
        frameworks = sorted((bundle / "XCFrameworks").glob("*.xcframework"))
        if not any(path.stem == "TheInsideJob" for path in frameworks):
            raise RuntimeError("Bundle is missing TheInsideJob.xcframework")
        for framework in frameworks:
            run(["plutil", "-lint", str(framework / "Info.plist")])

        run(["tuist", "generate", "--path", str(consumer), "--no-open", "--no-binary-cache"])
        run(["python3", str(ROOT / "scripts/clean-pbxproj.py"),
             str(consumer / "BinaryConsumer.xcodeproj/project.pbxproj")])

        try:
            for platform, configuration in (
                ("iphoneos", "Debug"), ("iphoneos", "Release"),
                ("iphonesimulator", "Debug"), ("iphonesimulator", "Release"),
            ):
                destination = ("generic/platform=iOS" if platform == "iphoneos"
                               else f"platform=iOS Simulator,id={args.simulator}")
                run(["xcodebuild", "-project", str(consumer / "BinaryConsumer.xcodeproj"),
                     "-scheme", "BinaryConsumer", "-configuration", configuration,
                     "-destination", destination,
                     "-derivedDataPath", str(consumer / "Build"), "CODE_SIGNING_ALLOWED=NO", "build"])
                app = consumer / f"Build/Build/Products/{configuration}-{platform}/BinaryConsumer.app"
                load_command = ""
                framework_names = {framework.stem for framework in frameworks}
                for line in subprocess.check_output(["otool", "-l", str(app / "BinaryConsumer")], text=True).splitlines():
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
                if platform == "iphoneos":
                    continue
                run(["xcrun", "simctl", "install", args.simulator, str(app)])
                environment = {**os.environ, "SIMCTL_CHILD_INSIDEJOB_PORT": str(port),
                               "SIMCTL_CHILD_INSIDEJOB_TOKEN": token, "SIMCTL_CHILD_INSIDEJOB_ID": token}
                run(["xcrun", "simctl", "launch", args.simulator, APP_ID], env=environment)
                if configuration == "Debug":
                    deadline = time.monotonic() + 60
                    while True:
                        response = subprocess.run(
                            [str(cli), "get_interface", "--format", "json", "--quiet", "--connect-timeout", "3"],
                            env={**os.environ, "BUTTONHEIST_DEVICE": f"127.0.0.1:{port}",
                                 "BUTTONHEIST_TOKEN": token, "BUTTONHEIST_DRIVER_ID": token},
                            capture_output=True, text=True, timeout=15,
                        )
                        if response.returncode == 0 and "Prebuilt runtime consumer" in response.stdout:
                            payload = json.loads(response.stdout)
                            if payload.get("status") == "ok":
                                break
                        if time.monotonic() >= deadline:
                            raise RuntimeError(f"Debug runtime capture failed: {response.stdout}\n{response.stderr}")
                else:
                    # Launch succeeded without any of the weak-linked Debug frameworks.
                    try:
                        connection = socket.create_connection(("127.0.0.1", port), timeout=1)
                    except OSError:
                        pass
                    else:
                        connection.close()
                        raise RuntimeError("Release app has a running Debug listener")
                run(["xcrun", "simctl", "terminate", args.simulator, APP_ID])
        finally:
            subprocess.run(["xcrun", "simctl", "terminate", args.simulator, APP_ID], capture_output=True)
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, APP_ID], capture_output=True)
    print("PASS: prebuilt Debug runtime captures; Release excludes it and launches")


if __name__ == "__main__":
    main()
