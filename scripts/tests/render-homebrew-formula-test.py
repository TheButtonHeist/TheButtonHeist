#!/usr/bin/env python3
"""Check release formula rendering and checksum ownership without Homebrew."""

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


if __name__ == "__main__":
    unittest.main()
