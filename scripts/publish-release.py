#!/usr/bin/env python3
"""Publish verified release assets, then commit both Homebrew formulas together."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[1]


def gh(*arguments: str, payload: dict | None = None, token: str | None = None) -> str:
    command = ["gh", *arguments]
    if payload is not None:
        command.extend(["--input", "-"])
    return subprocess.run(
        command, input=json.dumps(payload) if payload is not None else None,
        env={**os.environ, **({"GH_TOKEN": token} if token else {})},
        check=True, stdout=subprocess.PIPE, text=True,
    ).stdout


def verified_checksums(directory: Path, archives: list[str]) -> dict[str, str]:
    checksums = {}
    for line in (directory / "checksums.txt").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (\S+)", line)
        if not match or match[2] not in archives or match[2] in checksums:
            raise ValueError("Release checksums must name each expected archive exactly once")
        checksums[match[2]] = match[1]
    if set(checksums) != set(archives):
        raise ValueError("Release checksums are missing an expected archive")
    for name, expected in checksums.items():
        digest = hashlib.sha256()
        with (directory / name).open("rb") as archive:
            for chunk in iter(lambda: archive.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise ValueError(f"Release checksum mismatch: {name}")
    return checksums


def publish(version: str, directory: Path, notes: Path) -> None:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError(f"Invalid release version: {version}")
    contract = subprocess.check_output([
        "bash", "-euo", "pipefail", "-c", '''
source "$1"
printf '%s\\n' "$BUTTONHEIST_GITHUB_REPO" "$BUTTONHEIST_TAP_REPO" \
    "$(buttonheist_cli_archive_name "$2")" "$(buttonheist_mcp_archive_name "$2")" \
    "$(buttonheist_demo_archive_name "$2")" "$(buttonheist_insidejob_archive_name "$2")"
''', "bash", str(ROOT / "scripts/release-contract.sh"), version,
    ], text=True).splitlines()
    repo, tap, *archives = contract
    cli, mcp, _, insidejob = archives
    tag = f"v{version}"
    # A successful listing distinguishes absence from an API or authentication failure.
    pages = json.loads(gh("api", f"repos/{repo}/releases", "--method", "GET",
                          "--paginate", "--slurp"))
    for item in (item for page in pages for item in page):
        published_version = re.fullmatch(r"v([0-9]+\.[0-9]+\.[0-9]+)", item["tag_name"])
        if (not item["draft"] and published_version
                and tuple(map(int, published_version[1].split("."))) > tuple(map(int, version.split(".")))):
            raise ValueError(f"A newer release {item['tag_name']} is already published; refusing a downgrade")
    release = next((item for page in pages for item in page if item["tag_name"] == tag), None)
    if release is None or release["draft"]:
        verified_checksums(directory, archives)
        if release is None:
            gh("release", "create", tag, "--repo", repo, "--draft", "--verify-tag",
               "--title", f"Button Heist {version}", "--generate-notes", "--notes-file", str(notes))
        gh("release", "upload", tag, "--repo", repo, "--clobber",
           *(str(directory / name) for name in [*archives, "checksums.txt"]))

    with tempfile.TemporaryDirectory(prefix="buttonheist-publication-") as temporary:
        downloaded = Path(temporary)
        gh("release", "download", tag, "--repo", repo, "--dir", str(downloaded),
           *(argument for name in [*archives, "checksums.txt"] for argument in ("--pattern", name)))
        checksums = verified_checksums(downloaded, archives)
        if release is None or release["draft"]:
            gh("release", "edit", tag, "--repo", repo, "--draft=false")

        token = os.environ.get("HOMEBREW_TAP_TOKEN")
        if not token:
            print(f"Published {tag}; HOMEBREW_TAP_TOKEN is unset, so the tap was not updated.")
            return
        formulas = downloaded / "formulas"
        subprocess.run([
            "bash", str(ROOT / "scripts/render-homebrew-formula.sh"), version,
            checksums[cli], checksums[mcp], checksums[insidejob], str(formulas),
        ], check=True)

        def api(method: str, path: str, payload: dict | None = None) -> dict:
            return json.loads(gh("api", f"repos/{tap}{path}", "--method", method,
                                 payload=payload, token=token))

        branch = quote(api("GET", "")["default_branch"], safe="")
        head = api("GET", f"/git/ref/heads/{branch}")["object"]["sha"]
        base = api("GET", f"/git/commits/{head}")["tree"]["sha"]
        tree = api("POST", "/git/trees", {
            "base_tree": base,
            "tree": [{"path": f"Formula/{name}.rb", "mode": "100644", "type": "blob",
                      "content": (formulas / f"{name}.rb").read_text()}
                     for name in ("buttonheist", "theinsidejob")],
        })["sha"]
        if tree == base:
            print(f"Both Homebrew formulas already match {tag}.")
            return
        commit = api("POST", "/git/commits", {
            "message": f"Update Button Heist formulas to {version}", "tree": tree, "parents": [head],
        })["sha"]
        api("PATCH", f"/git/refs/heads/{branch}", {"sha": commit, "force": False})
        print(f"Published {tag} and updated both Homebrew formulas in one commit.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("directory", type=Path)
    parser.add_argument("notes", type=Path)
    arguments = parser.parse_args()
    try:
        publish(arguments.version, arguments.directory, arguments.notes)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Publication failed; tags and published assets are preserved: {error}")
