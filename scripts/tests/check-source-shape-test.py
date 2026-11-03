#!/usr/bin/env python3
"""Exercise phase reporting and failure propagation without a Swift toolchain."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

WRAPPER = Path(__file__).resolve().parents[1] / "check-source-shape.sh"
FAKE_TOOL = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if Path(sys.argv[0]).name == 'bumper':
    step = args[0]
elif '--show-bin-path' in args:
    step = 'path'
elif '--build-tests' in args:
    step = 'test-build'
elif 'BumperRulesRunner' in args:
    step = 'release-build'
else:
    step = 'cli-build'
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(json.dumps(step) + '\\n')
if step == os.environ.get('FAIL_STEP'):
    sys.exit(17)
if step == 'path':
    print(os.environ.get('BIN_OUTPUT', str(Path(sys.argv[0]).parent)))
'''


class SourceShapeWrapperTests(unittest.TestCase):
    def run_wrapper(self, command="lint", **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for tool in ["swift", "bumper"]:
                path = root / tool
                path.write_text(FAKE_TOOL)
                path.chmod(0o755)
            log = root / "calls"
            environment = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                               BUTTONHEIST_SOURCE_ROOT=directory, CALL_LOG=str(log),
                               BUMPER_RUNNER_BUILD_CONFIGURATION="debug")
            environment.update(overrides)
            result = subprocess.run(["bash", str(WRAPPER), command], env=environment,
                                    text=True, capture_output=True, check=False)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_normal_modes_report_each_phase(self):
        for command in ["lint", "test"]:
            with self.subTest(command=command):
                result, calls = self.run_wrapper(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = ["cli-build", "test-build", "path", "test"]
                if command == "lint":
                    expected.append("lint")
                self.assertEqual(calls, expected)
                for phase in ["build", "tests"] + (["lint"] if command == "lint" else []):
                    self.assertRegex(result.stderr, rf"Bumper {phase}: \d+s \(exit 0\)")

    def test_release_runner_build_follows_debug_tests(self):
        result, calls = self.run_wrapper(BUMPER_RUNNER_BUILD_CONFIGURATION="release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["cli-build", "test-build", "path", "test", "release-build", "lint"])
        result, calls = self.run_wrapper("test", BUMPER_RUNNER_BUILD_CONFIGURATION="release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("release-build", calls)

    def test_failures_stop_at_the_failing_phase(self):
        steps = ["cli-build", "test-build", "path", "test", "release-build", "lint"]
        for index, step in enumerate(steps):
            with self.subTest(step=step):
                result, calls = self.run_wrapper(FAIL_STEP=step, BUMPER_RUNNER_BUILD_CONFIGURATION="release")
                self.assertEqual(result.returncode, 17, result.stderr)
                self.assertEqual(calls, steps[:index + 1])
                phase = {"test": "tests", "lint": "lint", "release-build": "runner-build"}.get(step, "build")
                self.assertRegex(result.stderr, rf"Bumper {phase}: \d+s \(exit 17\)")

    def test_invalid_binary_lookup_stops_before_tests(self):
        for value in ["", "relative/path", "/one\n/two", "/path\r", "/missing"]:
            with self.subTest(value=value):
                result, calls = self.run_wrapper(BIN_OUTPUT=value)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(calls, ["cli-build", "test-build", "path"])
                self.assertIn("SwiftPM did not return an executable Bumper directory", result.stderr)

    def test_invalid_command_does_not_build(self):
        result, calls = self.run_wrapper("invalid")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
