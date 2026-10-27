#!/usr/bin/env python3
"""Exercise release inputs, tap permissions, parser pins and license packaging offline."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SHA = "0123456789abcdef0123456789abcdef01234567"


class ReleaseBoundaryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        (self.root / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/release-contract.sh", self.root / "scripts/release-contract.sh")
        self.log = self.root / "calls"
        self.output = self.root / "outputs"
        self.environment = {**os.environ, "PATH": f"{self.tools}:{os.environ['PATH']}",
                            "TEST_LOG": str(self.log), "GITHUB_OUTPUT": str(self.output)}

    def executable(self, path, body):
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)

    def run_script(self, name, *arguments, **environment):
        shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        return subprocess.run(["bash", str(self.root / "scripts" / name), *arguments],
                              cwd=self.root, env={**self.environment, **environment},
                              capture_output=True, text=True)

    def admission(self, tag, **environment):
        self.executable(self.tools / "git", f'''
echo "git $*" >> "$TEST_LOG"
case "$1" in
    fetch) ;;
    rev-parse) echo {SHA} ;;
    show) printf 'public let buttonHeistVersion: ButtonHeistVersion = "%s"\\n' "${{TEST_VERSION:-1.2.3}}" ;;
    *) exit 64 ;;
esac
''')
        self.executable(self.root / "scripts/require-release-commit.sh", '''
echo "trusted admission $*" >> "$TEST_LOG"
[[ "${TEST_ADMITTED:-true}" == true ]]
''')
        return self.run_script("admit-release.sh", tag, **environment)

    def test_admits_only_an_official_tag_and_emits_its_verified_sha(self):
        result = self.admission("v1.2.3")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.output.read_text(), f"sha={SHA}\nversion=1.2.3\n")
        self.assertIn(f"trusted admission --repo TheButtonHeist/TheButtonHeist {SHA}", self.log.read_text())

    def test_untrusted_tag_syntax_is_rejected_before_git_or_shell_execution(self):
        for tag in ('v1.2.3";touch${IFS}injected;#', "v01.2.3", "v1.02.3", "v1.2.03",
                    "v1.2.3-abcdef012345", "main", "v1.2.3\n"):
            with self.subTest(tag=tag):
                result = self.admission(tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.log.exists())
                self.assertFalse(self.output.exists())
                self.assertFalse((self.root / "injected").exists())

    def test_failed_admission_or_mismatched_source_version_emits_no_outputs(self):
        for environment in ({"TEST_ADMITTED": "false"}, {"TEST_VERSION": "1.2.4"}):
            with self.subTest(environment=environment):
                result = self.admission("v1.2.3", **environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())

    def tap_access(self, **environment):
        self.executable(self.tools / "gh", '''
echo "gh $*" >> "$TEST_LOG"
[[ "$GH_TOKEN" == tap-token ]]
case "$2" in
    repos/TheButtonHeist/homebrew-tap) echo main ;;
    */git/trees/main) echo '{"sha":"tree-sha","truncated":false,"tree":[{"path":"Formula","mode":"040000","type":"tree","sha":"formula-sha"}]}' ;;
    */git/trees)
        cat > "$TEST_LOG.payload"
        [[ "${TEST_WRITE_ALLOWED:-true}" == true ]] || exit 1
        echo tree-sha
        ;;
    *) exit 64 ;;
esac
''')
        return self.run_script("verify-homebrew-tap-access.sh", HOMEBREW_TAP_TOKEN="tap-token", **environment)

    def test_tap_preflight_checks_actual_write_permission_without_changing_a_ref(self):
        result = self.tap_access()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = json.loads(Path(str(self.log) + ".payload").read_text())
        self.assertEqual(payload, {"tree": [{"path": "Formula", "mode": "040000", "type": "tree", "sha": "formula-sha"}]})
        calls = self.log.read_text()
        self.assertIn("--method POST", calls)
        self.assertNotIn("/refs", calls)
        self.assertNotIn("/commits", calls)

    def test_tap_preflight_rejects_a_token_without_contents_write(self):
        result = self.tap_access(TEST_WRITE_ALLOWED="false")
        self.assertNotEqual(result.returncode, 0)

    def test_tap_preflight_requires_a_token_before_network_access(self):
        result = self.run_script("verify-homebrew-tap-access.sh", HOMEBREW_TAP_TOKEN="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HOMEBREW_TAP_TOKEN", result.stderr)
        self.assertFalse(self.log.exists())

    def test_parser_pin_survives_upstream_main_advancing_but_rejects_wrong_revisions(self):
        manifest = self.root / "Package.swift"
        manifest.write_text('.package(url: "https://github.com/TheButtonHeist/AccessibilitySnapshotBH", exact: "0.25.1")\n')
        lock = self.root / "Package.resolved"
        document = {"pins": [{"identity": "accessibilitysnapshotbh", "state": {"version": "0.25.1", "revision": SHA}}]}
        lock.write_text(json.dumps(document))
        self.executable(self.tools / "git", f'''
echo "git $*" >> "$TEST_LOG"
case "$1" in
    ls-files)
        case "$3" in '*Package.swift') echo Package.swift ;; '*Package.resolved') echo Package.resolved ;; *) exit 64 ;; esac ;;
    ls-remote)
        case "$3" in
            refs/tags/0.25.1*) printf '{SHA}\\t%s\\n' "$3" ;;
            refs/heads/main) printf '%040d\\t%s\\n' 9 "$3" ;;
            *) exit 64 ;;
        esac ;;
    *) exit 64 ;;
esac
''')
        result = self.run_script("check-parser-contract.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("refs/heads/main", self.log.read_text())
        document["pins"][0]["state"]["revision"] = "wrong-sha"
        lock.write_text(json.dumps(document))
        result = self.run_script("check-parser-contract.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("revision wrong-sha", result.stdout)

    def test_license_bundle_preserves_different_license_names_and_notices(self):
        for name, filename in (("first", "LICENSE.txt"), ("second", "LICENSE.md")):
            checkout = self.root / name
            checkout.mkdir()
            (checkout / filename).write_text(name + " license\n")
            (checkout / "NOTICE.txt").write_text(name + " notice\n")
        output = self.root / "Licenses"
        result = subprocess.run(["python3", str(ROOT / "scripts/package-licenses.py"), str(output),
                                 str(self.root / "first"), str(self.root / "second")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((output / "ButtonHeist/LICENSE").read_bytes(), (ROOT / "LICENSE").read_bytes())
        self.assertEqual((output / "first/LICENSE.txt").read_text(), "first license\n")
        self.assertEqual((output / "second/NOTICE.txt").read_text(), "second notice\n")
        (self.root / "second/LICENSE.md").unlink()
        result = subprocess.run(["python3", str(ROOT / "scripts/package-licenses.py"), str(output),
                                 str(self.root / "second")], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
