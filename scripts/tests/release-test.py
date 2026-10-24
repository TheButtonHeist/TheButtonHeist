#!/usr/bin/env python3
"""Check release admission and failure recovery without publishing anything."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SHA = "0123456789abcdef0123456789abcdef01234567"


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("release.sh", "release-contract.sh", "bump-version.sh"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        version = self.root / "ButtonHeist/Sources/TheScore/Wire/Messages.swift"
        version.parent.mkdir(parents=True)
        version.write_text('public let buttonHeistVersion: ButtonHeistVersion = "1.2.3"\n')
        self.executable(scripts / "require-release-commit.sh", '''
echo "admit $*" >> "$TEST_LOG"
[[ "${ADMISSION_OK:-true}" == true ]]
''')
        self.executable(scripts / "validate-release-contract.sh", 'echo contract >> "$TEST_LOG"')
        self.executable(self.tools / "git", r'''
echo "git $*" >> "$TEST_LOG"
case "$1 $2" in
    'branch --show-current') echo "${TEST_BRANCH:-main}" ;;
    'status --porcelain') [[ "${TEST_DIRTY:-false}" == false ]] || echo ' M dirty.swift' ;;
    'fetch origin')
        if [[ -f "$TEST_FETCHED" && "${TEST_MAIN_MOVES:-false}" == true ]]; then
            touch "$TEST_MOVED"
        fi
        touch "$TEST_FETCHED"
        ;;
    'rev-parse HEAD') echo "${TEST_LOCAL_SHA:-0123456789abcdef0123456789abcdef01234567}" ;;
    'rev-parse origin/main')
        if [[ -f "$TEST_MOVED" ]]; then echo moved-main; else echo 0123456789abcdef0123456789abcdef01234567; fi
        ;;
    'ls-remote --tags')
        if [[ "${TEST_TAG_EXISTS:-false}" == true && "$4" == refs/tags/v1.2.3 ]]; then
            echo 'old-sha refs/tags/v1.2.3'
        elif [[ "${TEST_TARGET_TAG_EXISTS:-false}" == true && "$4" != refs/tags/v1.2.3 ]]; then
            echo "old-sha $4"
        fi
        ;;
    'show-ref --verify') [[ "${TEST_LOCAL_TAG_EXISTS:-false}" == true ]] || exit 1 ;;
    'tag v1.2.3'|'push origin') ;;
    *) echo "Unexpected git command: $*" >&2; exit 64 ;;
esac
exit 0
''')
        self.executable(self.tools / "gh", r'''
echo "gh $*" >> "$TEST_LOG"
case "$1 $2" in
    'run list')
        [[ "${TEST_RUN_LOOKUP_OK:-true}" == true ]] || exit 1
        [[ "${TEST_MISSING_RUN:-false}" == true ]] || echo 42
        ;;
    'run watch') [[ "${TEST_WORKFLOW_OK:-true}" == true ]] ;;
    'release view')
        [[ "${TEST_RELEASE_EXISTS:-true}" == true ]] || exit 1
        echo "${TEST_RELEASE_DRAFT:-false}"
        ;;
    *) echo "Unexpected gh command: $*" >&2; exit 64 ;;
esac
''')
        self.executable(self.tools / "brew", 'echo "brew $*" >> "$TEST_LOG"; exit 1')
        self.executable(self.tools / "sleep", "exit 0")

    def executable(self, path, body):
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)

    def run_release(self, *arguments, **environment):
        log = self.root / "calls"
        log.write_text("")
        for marker in ("fetched", "moved"):
            (self.root / marker).unlink(missing_ok=True)
        result = subprocess.run(
            ["bash", str(self.root / "scripts/release.sh"), *arguments],
            env={**os.environ, "PATH": f"{self.tools}:{os.environ['PATH']}",
                 "TEST_LOG": str(log), "TEST_FETCHED": str(self.root / "fetched"),
                 "TEST_MOVED": str(self.root / "moved"), **environment},
            capture_output=True, text=True,
        )
        return result, log.read_text().splitlines() if log.exists() else []

    def assert_preserved(self, calls):
        self.assertFalse(any("--delete" in call or "tag -d" in call or "release delete" in call
                             for call in calls))
        self.assertFalse(any("git commit" in call or "HEAD:main" in call or "bump-version" in call
                             or "workflow run CI" in call for call in calls))

    def test_success_tags_exact_admitted_main_commit_without_another_source_commit(self):
        result, calls = self.run_release()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"git tag v1.2.3 {SHA}", calls)
        self.assertIn("git push origin refs/tags/v1.2.3", calls)
        admission = next(call for call in calls if call.startswith("admit "))
        self.assertIn(SHA, admission)
        self.assertLess(calls.index(admission), calls.index(f"git tag v1.2.3 {SHA}"))
        self.assertTrue(any(f"--commit {SHA}" in call for call in calls if call.startswith("gh run list")))
        self.assert_preserved(calls)

    def test_dry_run_checks_admission_without_tagging(self):
        result, calls = self.run_release("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any(call.startswith("admit ") for call in calls))
        self.assertFalse(any(call.startswith(("git tag ", "git push ", "gh ")) for call in calls))

    def test_rejects_unsigned_or_non_green_commit_before_tagging(self):
        result, calls = self.run_release(ADMISSION_OK="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call.startswith(("git tag ", "git push ", "gh ")) for call in calls))
        self.assert_preserved(calls)

    def test_rejects_dirty_checkout_wrong_branch_or_stale_head(self):
        for environment in ({"TEST_DIRTY": "true"}, {"TEST_BRANCH": "feature"},
                            {"TEST_LOCAL_SHA": "stale-head"}):
            with self.subTest(environment=environment):
                result, calls = self.run_release(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call.startswith(("admit ", "git tag ", "git push ", "gh "))
                                     for call in calls))

    def test_main_movement_during_admission_fails_before_tagging(self):
        result, calls = self.run_release(TEST_MAIN_MOVES="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("main moved", result.stdout + result.stderr)
        self.assertFalse(any(call.startswith(("git tag ", "git push ", "gh ")) for call in calls))

    def test_existing_tag_is_preserved_with_a_retry_command(self):
        result, calls = self.run_release("--tag-current", TEST_TAG_EXISTS="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gh workflow run release.yml", result.stdout)
        self.assertFalse(any(call.startswith(("git tag ", "git push ", "gh ")) for call in calls))
        self.assert_preserved(calls)

    def test_local_only_tag_is_preserved_and_cannot_prepare_another_version(self):
        result, calls = self.run_release(TEST_LOCAL_TAG_EXISTS="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git push origin refs/tags/v1.2.3", result.stdout)
        self.assertIn('"1.2.3"', (self.root / "ButtonHeist/Sources/TheScore/Wire/Messages.swift").read_text())
        self.assertFalse(any(call.startswith(("git tag ", "git push ", "gh ")) for call in calls))
        self.assert_preserved(calls)

    def test_bump_cannot_reuse_an_existing_target_tag(self):
        result, calls = self.run_release("--minor", TEST_TARGET_TAG_EXISTS="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("v1.3.0 already exists", result.stderr)
        self.assertIn('"1.2.3"', (self.root / "ButtonHeist/Sources/TheScore/Wire/Messages.swift").read_text())
        self.assert_preserved(calls)

    def test_workflow_failure_or_missing_run_preserves_release_and_tag(self):
        for environment in ({"TEST_WORKFLOW_OK": "false"}, {"TEST_MISSING_RUN": "true"},
                            {"TEST_RUN_LOOKUP_OK": "false"}):
            with self.subTest(environment=environment):
                result, calls = self.run_release(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("gh workflow run release.yml", result.stdout)
                self.assertIn("--ref v1.2.3 -f tag=v1.2.3", result.stdout)
                self.assertFalse(any(call.startswith("brew ") for call in calls))
                self.assert_preserved(calls)

    def test_runs_version_bump_when_needed_and_stops_before_tag_or_publication(self):
        for arguments, environment, expected in (
            ((), {"TEST_TAG_EXISTS": "true"}, "1.2.4"),
            (("1.2.4",), {}, "1.2.4"), (("--minor",), {}, "1.3.0"), (("--major",), {}, "2.0.0"),
        ):
            with self.subTest(arguments=arguments):
                version = self.root / "ButtonHeist/Sources/TheScore/Wire/Messages.swift"
                version.write_text('public let buttonHeistVersion: ButtonHeistVersion = "1.2.3"\n')
                result, calls = self.run_release(*arguments, **environment)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f'"{expected}"', version.read_text())
                self.assertIn("No release was published", result.stdout)
                self.assertFalse(any(call.startswith(("git tag ", "git push ", "gh run ")) for call in calls))
                self.assert_preserved(calls)

    def test_dry_run_does_not_apply_needed_version_bump(self):
        result, calls = self.run_release("--dry-run", TEST_TAG_EXISTS="true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Would run scripts/bump-version.sh 1.2.4", result.stdout)
        version = self.root / "ButtonHeist/Sources/TheScore/Wire/Messages.swift"
        self.assertIn('"1.2.3"', version.read_text())
        self.assertFalse(any(call.startswith(("git tag ", "git push ", "gh run ")) for call in calls))

    def test_incomplete_or_unreadable_publication_does_not_prepare_another_bump(self):
        for environment in ({"TEST_RELEASE_DRAFT": "true"}, {"TEST_RELEASE_EXISTS": "false"}):
            with self.subTest(environment=environment):
                result, calls = self.run_release(TEST_TAG_EXISTS="true", **environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("gh workflow run release.yml", result.stdout)
                self.assertIn('"1.2.3"', (self.root / "ButtonHeist/Sources/TheScore/Wire/Messages.swift").read_text())
                self.assert_preserved(calls)

    def test_rejects_invalid_or_conflicting_arguments_and_older_versions(self):
        for arguments in (("bad",), ("--major", "--minor"), ("--tag-current", "1.2.4"), ("1.2.2",)):
            with self.subTest(arguments=arguments):
                result, calls = self.run_release(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call.startswith("git tag ") for call in calls))


if __name__ == "__main__":
    unittest.main()
