#!/usr/bin/env python3
"""Check release formula rendering and checksum ownership without Homebrew."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class HomebrewFormulaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for relative in (
            "scripts/render-homebrew-formula.sh",
            "scripts/release-contract.sh",
            "Formula/buttonheist.rb",
            "Formula/theinsidejob.rb",
        ):
            source = ROOT / relative
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        self.output = self.root / "rendered"

    def render(self, version: str = "1.2.3", cli: str = "1" * 64,
               mcp: str = "2" * 64, insidejob: str = "3" * 64) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(self.root / "scripts/render-homebrew-formula.sh"),
             version, cli, mcp, insidejob, str(self.output)],
            capture_output=True, text=True,
        )

    def test_each_artifact_keeps_its_checksum(self) -> None:
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        cli = (self.output / "buttonheist.rb").read_text()
        runtime = (self.output / "theinsidejob.rb").read_text()
        for body, artifacts in (
            (cli, (("buttonheist-1.2.3-macos.tar.gz", "1" * 64),
                   ("buttonheist-mcp-1.2.3-macos.tar.gz", "2" * 64))),
            (runtime, (("theinsidejob-1.2.3.zip", "3" * 64),)),
        ):
            self.assertIn('version "1.2.3"', body)
            self.assertNotIn("PLACEHOLDER", body)
            for artifact, checksum in artifacts:
                self.assertIn(f'{artifact}"\n', body)
                self.assertRegex(body, rf'{artifact}"\s+sha256 "{checksum}"')
        self.assertNotIn("theinsidejob-", cli)
        self.assertNotIn('depends_on "TheButtonHeist/tap/buttonheist"', runtime)

    def test_rejects_invalid_version_and_each_invalid_checksum(self) -> None:
        for arguments in (
            {"version": "v1.2.3"}, {"version": "1.2.3\n"},
            {"version": "01.2.3"}, {"version": "1.02.3"}, {"version": "1.2.03"},
            {"cli": "bad"}, {"mcp": "A" * 64}, {"insidejob": "3" * 63},
        ):
            with self.subTest(arguments=arguments):
                result = self.render(**arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(list(self.output.glob("*.rb")))

    def test_rejects_unknown_runtime_url_without_replacing_existing_output(self) -> None:
        self.output.mkdir()
        for name in ("buttonheist", "theinsidejob"):
            (self.output / f"{name}.rb").write_text("previous release\n")
        template = self.root / "Formula/theinsidejob.rb"
        template.write_text(template.read_text().replace("/releases/download/", "/unverified/"))
        self.assertNotEqual(self.render().returncode, 0)
        for name in ("buttonheist", "theinsidejob"):
            self.assertEqual((self.output / f"{name}.rb").read_text(), "previous release\n")

    def test_rejects_duplicate_or_missing_runtime_checksum(self) -> None:
        template = self.root / "Formula/theinsidejob.rb"
        original = template.read_text()
        for replacement in ('sha256 "PLACEHOLDER"\n  sha256 "PLACEHOLDER"', ""):
            with self.subTest(replacement=replacement):
                template.write_text(original.replace('sha256 "PLACEHOLDER"', replacement))
                self.assertNotEqual(self.render().returncode, 0)
                self.assertFalse(list(self.output.glob("*.rb")))

    def upgrade(self, fixture: Path, installed: str, cli: str = "1.2.3",
                runtime: str = "1.2.3") -> tuple[subprocess.CompletedProcess[str], list[str]]:
        tools = fixture / "tools"
        tools.mkdir()
        brew = tools / "brew"
        brew.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$BREW_TEST_LOG"
case "$1" in
    list)
        case " $BREW_TEST_INSTALLED " in
            *" ${3##*/} "*) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    --prefix) printf '%s/%s\n' "$BREW_TEST_PREFIX" "${2##*/}" ;;
    upgrade|update) exit 0 ;;
    *) exit 64 ;;
esac
''')
        brew.chmod(0o755)
        prefix = fixture / "installed"
        binary = prefix / "buttonheist/bin/buttonheist"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/bash\nprintf '%s\\n' \"$BREW_TEST_CLI_VERSION\"\n")
        binary.chmod(0o755)
        version = prefix / "theinsidejob/libexec/TheInsideJob.xcframework/VERSION"
        version.parent.mkdir(parents=True)
        version.write_text(runtime + "\n")
        log = fixture / "brew.log"
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c",
             'source "$1"; buttonheist_upgrade_installed_formulas "$2"',
             "bash", str(self.root / "scripts/release-contract.sh"), "1.2.3"],
            env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                 "BREW_TEST_LOG": str(log), "BREW_TEST_PREFIX": str(prefix),
                 "BREW_TEST_INSTALLED": installed, "BREW_TEST_CLI_VERSION": cli},
            capture_output=True, text=True,
        )
        return result, log.read_text().splitlines()

    def test_release_upgrades_only_installed_formulas_from_the_organization_tap(self) -> None:
        for installed in ("", "buttonheist", "theinsidejob", "buttonheist theinsidejob"):
            with self.subTest(installed=installed), tempfile.TemporaryDirectory() as temporary:
                result, calls = self.upgrade(Path(temporary), installed)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    [call for call in calls if call.startswith("upgrade ")],
                    [f"upgrade TheButtonHeist/tap/{formula}" for formula in installed.split()],
                )
                self.assertEqual(calls.count("update --quiet"), int(bool(installed)))
                self.assertFalse(any(call.startswith("install ") for call in calls))

    def test_release_rejects_an_outdated_cli_or_runtime_after_upgrade(self) -> None:
        for versions in ({"cli": "1.2.2"}, {"runtime": "1.2.2"}):
            with self.subTest(versions=versions), tempfile.TemporaryDirectory() as temporary:
                result, _ = self.upgrade(Path(temporary), "buttonheist theinsidejob", **versions)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("reports '1.2.2', expected '1.2.3'", result.stdout)


if __name__ == "__main__":
    unittest.main()
