#!/usr/bin/env python3
"""Exercise version admission against real, isolated Git snapshots."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-contract-version.py"
VERSION_FILE = "ButtonHeist/Sources/TheScore/Wire/Messages.swift"
WIRE_FILE = "ButtonHeist/Sources/TheScore/Wire/ElementModels.swift"


class ContractVersionTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.environment = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Contract tests",
            "GIT_AUTHOR_EMAIL": "contract-tests@example.com",
            "GIT_COMMITTER_NAME": "Contract tests",
            "GIT_COMMITTER_EMAIL": "contract-tests@example.com",
        }
        self.git("init", "--quiet", "--initial-branch=main")
        self.version("0.7.0")
        self.write(WIRE_FILE, "original wire model\n")
        self.base = self.commit()

    def git(self, *arguments: str, cwd: Path | None = None) -> str:
        return subprocess.check_output(
            ["git", *arguments], cwd=cwd or self.root, env=self.environment,
            text=True, stderr=subprocess.PIPE,
        ).strip()

    def write(self, path: str, content: str) -> None:
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)

    def version(self, value: str) -> None:
        self.write(VERSION_FILE, f'public let buttonHeistVersion: ButtonHeistVersion = "{value}"\n')

    def commit(self) -> str:
        self.git("add", "--all")
        self.git("commit", "--quiet", "--message", "fixture")
        return self.git("rev-parse", "HEAD")

    def check(self, base: str | None = None, head: str = "HEAD", cwd: Path | None = None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--", base or self.base, head],
            cwd=cwd or self.root, env=self.environment, text=True, capture_output=True,
        )

    def test_unrelated_changes_do_not_require_a_bump(self) -> None:
        self.write("docs/API.md", "documentation\n")
        self.write("ButtonHeist/Tests/TheScoreTests/ExampleTests.swift", "tests\n")
        self.write("ButtonHeist/Sources/TheInsideJob/TheTripwire/Example.swift", "implementation\n")
        self.commit()
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_contract_owner_requires_a_bump(self) -> None:
        paths = (
            WIRE_FILE,
            "ButtonHeist/Sources/TheScore/Core/AccessibilityPolicy.swift",
            "ButtonHeist/Sources/ThePlans/Model/ActionCommandPayloads.swift",
            "ButtonHeist/Sources/ThePlans/Parsing/HeistPlanSourceParser.swift",
            "ButtonHeist/Sources/TheButtonHeist/TheFence/TheFence+CommandCatalog.swift",
            "ButtonHeist/Sources/TheInsideJob/TheVault/IdAssignment.swift",
            "ButtonHeistCLI/Sources/Commands/ActionCommand.swift",
            "ButtonHeistMCP/Sources/ToolDefinitions.swift",
            "tests/fixtures/public-cli-mcp-command-contract.json",
        )
        for path in paths:
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD")
                self.write(path, "changed contract\n")
                self.commit()
                result = self.check(base)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(path, result.stderr)
                self.assertIn("scripts/bump-version.sh", result.stderr)

    def test_numeric_version_increases_pass(self) -> None:
        for version in ("0.7.1", "0.8.0", "0.10.0", "1.0.0"):
            with self.subTest(version=version):
                self.write(WIRE_FILE, "changed contract\n")
                self.version(version)
                self.commit()
                result = self.check()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"0.7.0 -> {version}", result.stdout)

    def test_version_decreases_fail(self) -> None:
        self.version("0.6.99")
        self.commit()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("greater than", result.stderr)

    def test_existing_base_bump_cannot_be_reused(self) -> None:
        self.version("0.7.1")
        current_base = self.commit()
        self.git("checkout", "--quiet", "--detach", self.base)
        self.version("0.7.1")
        self.write(WIRE_FILE, "different contract\n")
        self.commit()
        result = self.check(current_base)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scripts/bump-version.sh", result.stderr)

    def test_invalid_head_versions_fail(self) -> None:
        for version in ("0.7", "0.07.1", "0.7.1-dev.1", "invalid"):
            with self.subTest(version=version):
                self.version(version)
                self.commit()
                result = self.check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("MAJOR.MINOR.PATCH", result.stderr)

    def test_missing_or_duplicate_version_declarations_fail(self) -> None:
        for source in ("// no version\n", ('public let buttonHeistVersion: ButtonHeistVersion = "0.7.1"\n' * 2)):
            with self.subTest(source=source):
                self.write(VERSION_FILE, source)
                self.commit()
                result = self.check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("exactly one", result.stderr)

    def test_invalid_base_version_fails(self) -> None:
        self.version("invalid")
        base = self.commit()
        self.version("0.7.1")
        self.commit()
        result = self.check(base)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MAJOR.MINOR.PATCH", result.stderr)

    def test_worktree_version_cannot_mask_an_unbumped_commit(self) -> None:
        self.write(WIRE_FILE, "changed contract\n")
        self.commit()
        self.version("0.7.1")
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scripts/bump-version.sh", result.stderr)

    def test_deleting_a_contract_requires_a_bump(self) -> None:
        (self.root / WIRE_FILE).unlink()
        self.commit()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(WIRE_FILE, result.stderr)

    def test_renaming_out_of_a_contract_owner_requires_a_bump(self) -> None:
        self.git("mv", WIRE_FILE, "Moved.swift")
        self.commit()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(WIRE_FILE, result.stderr)

    def test_invalid_revisions_fail_closed(self) -> None:
        for revision in ("missing", "--help", "0" * 40):
            with self.subTest(revision=revision):
                result = self.check(base=revision)
                self.assertNotEqual(result.returncode, 0)

    def test_shallow_ci_checkout_compares_exact_snapshots(self) -> None:
        self.write(WIRE_FILE, "changed contract\n")
        self.commit()
        checkout = self.root / "checkout"
        self.git("clone", "--quiet", "--depth=1", self.root.as_uri(), str(checkout))
        self.git("fetch", "--quiet", "--depth=1", "origin", self.base, cwd=checkout)
        result = self.check(cwd=checkout)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scripts/bump-version.sh", result.stderr)


if __name__ == "__main__":
    unittest.main()
