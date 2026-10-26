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
        self.git("tag", "v0.7.0")

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

    def update(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--update"],
            cwd=self.root, env=self.environment, text=True, capture_output=True,
        )

    def test_checked_in_hash_admits_contract_changes_without_a_release_bump(self) -> None:
        self.write(WIRE_FILE, "changed contract\n")
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        source = (self.root / VERSION_FILE).read_text()
        self.assertRegex(source, r'"0\.7\.0-[0-9a-f]{12}"')
        self.commit()
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_hash_changes_when_transitive_plan_types_change(self) -> None:
        self.write("ButtonHeist/Sources/ThePlans/Model/Action.swift", "first contract\n")
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        first = (self.root / VERSION_FILE).read_text()
        self.write("ButtonHeist/Sources/ThePlans/Model/Action.swift", "second contract\n")
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual((self.root / VERSION_FILE).read_text(), first)

    def test_stale_hash_fails_even_if_it_was_changed_in_the_pr(self) -> None:
        self.write(WIRE_FILE, "first contract\n")
        self.assertEqual(self.update().returncode, 0)
        self.write(WIRE_FILE, "second contract\n")
        self.commit()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stale", result.stderr)

    def test_updating_is_idempotent_and_reverting_to_release_clears_hash(self) -> None:
        self.write(WIRE_FILE, "changed contract\n")
        self.assertEqual(self.update().returncode, 0)
        first = (self.root / VERSION_FILE).read_text()
        self.assertEqual(self.update().returncode, 0)
        self.assertEqual((self.root / VERSION_FILE).read_text(), first)
        self.write(WIRE_FILE, "original wire model\n")
        self.assertEqual(self.update().returncode, 0)
        self.assertIn('"0.7.0"', (self.root / VERSION_FILE).read_text())

    def test_hash_cannot_be_cleared_without_a_release_bump(self) -> None:
        self.write(WIRE_FILE, "changed contract\n")
        self.assertEqual(self.update().returncode, 0)
        base = self.commit()
        self.version("0.7.0")
        self.commit()
        result = self.check(base)
        self.assertNotEqual(result.returncode, 0)

    def test_unpublished_versions_can_be_reconciled_above_the_last_release(self) -> None:
        self.version("0.7.4")
        base = self.commit()
        self.version("0.7.1")
        self.commit()
        result = self.check(base)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reverting_a_committed_deviation_restores_the_release_identity(self) -> None:
        self.write(WIRE_FILE, "changed contract\n")
        self.assertEqual(self.update().returncode, 0)
        base = self.commit()
        self.write(WIRE_FILE, "original wire model\n")
        self.assertEqual(self.update().returncode, 0)
        self.commit()
        result = self.check(base)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_update_preserves_an_unpublished_development_identity(self) -> None:
        self.version("0.7.1")
        self.commit()
        self.write(WIRE_FILE, "changed contract\n")
        self.assertEqual(self.update().returncode, 0)
        self.commit()
        first = (self.root / VERSION_FILE).read_text()
        self.assertEqual(self.update().returncode, 0)
        self.assertEqual((self.root / VERSION_FILE).read_text(), first)

    def test_release_preparation_requires_an_empty_hash(self) -> None:
        self.version("0.7.1-a81d93c047e2")
        self.commit()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reset", result.stderr)

    def test_release_preparation_can_be_rechecked_after_tagging_the_same_commit(self) -> None:
        self.version("0.7.1")
        self.commit()
        self.git("tag", "v0.7.1")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_released_number_cannot_prepare_a_different_commit(self) -> None:
        self.version("0.7.1")
        self.commit()
        self.git("tag", "v0.7.1")
        self.write(WIRE_FILE, "changed contract\n")
        self.commit()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("greater than released", result.stderr)

    def test_missing_release_tags_fail_closed(self) -> None:
        self.git("tag", "--delete", "v0.7.0")
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git fetch origin --tags", result.stderr)

    def test_subdirectory_checks_use_repository_relative_contract_paths(self) -> None:
        self.write(WIRE_FILE, "changed contract\n")
        self.commit()
        directory = self.root / "docs"
        directory.mkdir()
        result = self.check(cwd=directory)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("development hash", result.stderr)

    def test_unrelated_changes_do_not_require_a_bump(self) -> None:
        self.write("docs/API.md", "documentation\n")
        self.write("ButtonHeist/Tests/TheScoreTests/ExampleTests.swift", "tests\n")
        self.write("ButtonHeist/Sources/TheInsideJob/TheTripwire/Example.swift", "implementation\n")
        self.write("ButtonHeistMCP/Sources/main.swift", "adapter implementation\n")
        self.commit()
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_shared_contract_owner_requires_a_hash(self) -> None:
        paths = (
            WIRE_FILE,
            "ButtonHeist/Sources/TheScore/Core/AccessibilityPolicy.swift",
            "ButtonHeist/Sources/ThePlans/Model/ActionCommandPayloads.swift",
            "ButtonHeist/Sources/ThePlans/Parsing/HeistPlanSourceParser.swift",
        )
        for path in paths:
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD")
                self.write(path, "changed contract\n")
                self.commit()
                result = self.check(base)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("development hash", result.stderr)
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

    def test_deleting_a_contract_requires_a_hash(self) -> None:
        (self.root / WIRE_FILE).unlink()
        self.commit()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("development hash", result.stderr)

    def test_renaming_out_of_a_contract_owner_requires_a_hash(self) -> None:
        self.git("mv", WIRE_FILE, "Moved.swift")
        self.commit()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("development hash", result.stderr)

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
        self.git("fetch", "--quiet", "--tags", "--depth=1", "origin", cwd=checkout)
        result = self.check(cwd=checkout)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scripts/bump-version.sh", result.stderr)


if __name__ == "__main__":
    unittest.main()
