#!/usr/bin/env python3
"""Check or update the development contract hash in the canonical version."""

import argparse
import hashlib
from os import chdir
from pathlib import Path
import re
import subprocess
import sys


VERSION_FILE = "ButtonHeist/Sources/TheScore/Wire/Messages.swift"
CONTRACT_PREFIXES = (
    "ButtonHeist/Sources/TheScore/",
    "ButtonHeist/Sources/ThePlans/",
)
VERSION_DECLARATION = re.compile(
    r'^[ \t]*public let buttonHeistVersion: ButtonHeistVersion = "([^"]+)"', re.MULTILINE,
)
RELEASE_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
VERSION_PATTERN = re.compile(rf"{RELEASE_PATTERN}(?:-[0-9a-f]{{12}})?")


def git(*arguments: str) -> str:
    return subprocess.check_output(["git", *arguments], text=True, stderr=subprocess.STDOUT)


def parse_version(source: str, label: str) -> str:
    declarations = VERSION_DECLARATION.findall(source)
    if len(declarations) != 1:
        raise ValueError(f"{label} must declare exactly one buttonHeistVersion")
    version = declarations[0]
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"{label}: expected MAJOR.MINOR.PATCH with an optional 12-character lowercase hash, found {version!r}")
    return version


def version_at(commit: str) -> str:
    return parse_version(git("show", f"{commit}:{VERSION_FILE}"), f"{commit}:{VERSION_FILE}")


def release_parts(version: str) -> tuple[int, ...]:
    return tuple(map(int, version.split("-", 1)[0].split(".")))


def fingerprint(commit: str | None = None) -> str:
    if commit is None:
        paths = sorted(str(path) for prefix in CONTRACT_PREFIXES for path in Path(prefix).rglob("*.swift"))
    else:
        paths = sorted(path for path in git("ls-tree", "-r", "--name-only", "-z", commit, "--", *CONTRACT_PREFIXES).split("\0")
                       if path.endswith(".swift"))
    digest = hashlib.sha256()
    for path in paths:
        content = Path(path).read_bytes() if commit is None else subprocess.check_output(["git", "show", f"{commit}:{path}"])
        if path == VERSION_FILE:
            content = VERSION_DECLARATION.sub('public let buttonHeistVersion: ButtonHeistVersion = ""', content.decode()).encode()
        digest.update(path.encode() + b"\0" + str(len(content)).encode() + b"\0" + content)
    return digest.hexdigest()[:12]


def update() -> None:
    source = Path(VERSION_FILE).read_text()
    current = parse_version(source, VERSION_FILE)
    release = current.split("-", 1)[0]
    tag = f"refs/tags/v{release}"
    published = subprocess.run(["git", "show-ref", "--verify", "--quiet", tag]).returncode == 0
    baseline = tag if published else "HEAD"
    contract_hash = fingerprint()
    unchanged = contract_hash == fingerprint(baseline) and (published or "-" not in current)
    version = release if unchanged else f"{release}-{contract_hash}"
    Path(VERSION_FILE).write_text(VERSION_DECLARATION.sub(
        f'public let buttonHeistVersion: ButtonHeistVersion = "{version}"', source,
    ))
    print(f"Version: {current} -> {version}")


def check(base: str, head: str) -> None:
    base = git("rev-parse", "--verify", "--end-of-options", f"{base}^{{commit}}").strip()
    head = git("rev-parse", "--verify", "--end-of-options", f"{head}^{{commit}}").strip()
    base_version, head_version = version_at(base), version_at(head)
    base_parts, head_parts = release_parts(base_version), release_parts(head_version)
    releases = [tag[1:] for tag in git("tag", "--list", "v*").splitlines()
                if re.fullmatch(rf"v{RELEASE_PATTERN}", tag)]
    if not releases:
        raise ValueError("No release tags available; run git fetch origin --tags before checking")
    latest = max(releases, key=release_parts)
    if head_parts < release_parts(latest):
        raise ValueError(f"buttonHeistVersion must be greater than or equal to released {latest}")

    contract_hash = head_version.partition("-")[2]
    if head_parts != base_parts:
        tagged_head = git("rev-parse", "--verify", f"refs/tags/v{latest}^{{commit}}").strip() == head
        if head_parts <= release_parts(latest) and not tagged_head:
            raise ValueError(f"Prepared release must be greater than released {latest}")
        if contract_hash:
            raise ValueError("A release version change must reset the development hash; run scripts/bump-version.sh <version>")
    elif contract_hash:
        expected = fingerprint(head)
        if contract_hash != expected:
            raise ValueError(f"Contract hash is stale: expected {expected}; run python3 scripts/check-contract-version.py --update")
    elif "-" in base_version or fingerprint(base) != fingerprint(head):
        released_contract = head_version in releases and fingerprint(head) == fingerprint(f"refs/tags/v{head_version}")
        if not released_contract:
            raise ValueError(
                "Contract sources changed without a checked-in development hash. "
                "Run python3 scripts/check-contract-version.py --update, "
                "or prepare a release with scripts/bump-version.sh <version>."
            )
    print(f"Contract version check passed: {base_version} -> {head_version}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="Update the worktree's development contract hash")
    parser.add_argument("base", nargs="?", help="Base commit to compare")
    parser.add_argument("head", nargs="?", help="Head commit to compare")
    arguments = parser.parse_args()
    if arguments.update and (arguments.base or arguments.head):
        parser.error("--update does not accept snapshots")
    if not arguments.update and not (arguments.base and arguments.head):
        parser.error("checking requires base and head snapshots")
    try:
        chdir(git("rev-parse", "--show-toplevel").strip())
        if arguments.update:
            update()
        else:
            check(arguments.base, arguments.head)
    except (ValueError, subprocess.CalledProcessError) as error:
        detail = error.output.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        sys.exit(f"Contract version check failed: {detail}")
