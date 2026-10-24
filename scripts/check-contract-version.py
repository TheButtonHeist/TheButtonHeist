#!/usr/bin/env python3
"""Require a product version bump when command or wire-contract sources change."""

import argparse
import re
import subprocess
import sys


VERSION_FILE = "ButtonHeist/Sources/TheScore/Wire/Messages.swift"
CONTRACT_PREFIXES = (
    "ButtonHeist/Sources/TheScore/",
    "ButtonHeist/Sources/ThePlans/",
    "ButtonHeist/Sources/TheButtonHeist/TheFence/",
    "ButtonHeistCLI/Sources/",
    "ButtonHeistMCP/Sources/",
)
CONTRACT_FILES = {
    "ButtonHeist/Sources/TheInsideJob/TheVault/IdAssignment.swift",
    "tests/fixtures/public-cli-mcp-command-contract.json",
}


def git(*arguments: str) -> str:
    return subprocess.check_output(["git", *arguments], text=True, stderr=subprocess.STDOUT)


def version_at(commit: str) -> str:
    source = git("show", f"{commit}:{VERSION_FILE}")
    declarations = re.findall(
        r'^[ \t]*public let buttonHeistVersion: ButtonHeistVersion = "([^"]+)"',
        source, re.MULTILINE,
    )
    if len(declarations) != 1:
        raise ValueError(f"{commit}:{VERSION_FILE} must declare exactly one buttonHeistVersion")
    version = declarations[0]
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError(f"{commit}: buttonHeistVersion must be MAJOR.MINOR.PATCH, found {version!r}")
    return version


def check(base: str, head: str) -> None:
    base = git("rev-parse", "--verify", "--end-of-options", f"{base}^{{commit}}").strip()
    head = git("rev-parse", "--verify", "--end-of-options", f"{head}^{{commit}}").strip()
    base_version, head_version = version_at(base), version_at(head)
    base_parts = tuple(map(int, base_version.split(".")))
    head_parts = tuple(map(int, head_version.split(".")))
    if head_parts < base_parts:
        raise ValueError(f"buttonHeistVersion {head_version} must be greater than {base_version}")

    paths = git("diff", "--name-only", "--no-renames", "--no-relative", "-z", base, head).split("\0")
    contracts = [path for path in paths if path.startswith(CONTRACT_PREFIXES) or path in CONTRACT_FILES]
    if contracts and head_parts == base_parts:
        raise ValueError(
            f"Contract sources changed without a newer buttonHeistVersion ({head_version}):\n"
            + "\n".join(f"  {path}" for path in contracts)
            + "\nRun scripts/bump-version.sh <new-version> in this change."
            + " A version bump does not publish a release."
        )
    print(f"Contract version check passed: {base_version} -> {head_version}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", help="Base commit to compare")
    parser.add_argument("head", help="Head commit to compare")
    arguments = parser.parse_args()
    try:
        check(arguments.base, arguments.head)
    except (ValueError, subprocess.CalledProcessError) as error:
        detail = error.output.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        sys.exit(f"Contract version check failed: {detail}")
