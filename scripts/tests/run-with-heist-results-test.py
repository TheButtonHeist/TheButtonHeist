#!/usr/bin/env python3

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


WRAPPER = Path(__file__).resolve().parents[1] / "run-with-heist-results.sh"


class ResultWrapperTests(unittest.TestCase):
    def test_invalid_modes_fail_before_creating_artifacts_or_launching_command(self) -> None:
        for mode in ("failed", "ALL", "always", " "):
            for source in ("flag", "environment"):
                with self.subTest(mode=mode, source=source), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    environment = {**os.environ, "BUTTONHEIST_RESULTS_MODE": mode if source == "environment" else "failures"}
                    command = [str(WRAPPER), "--dir", str(root / "results")]
                    if source == "flag":
                        command += ["--mode", mode]
                    command += ["--", "touch", str(root / "launched")]
                    result = subprocess.run(command, env=environment, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("failures, all, or off", result.stderr)
                    self.assertFalse((root / "results").exists())
                    self.assertFalse((root / "launched").exists())

    def test_valid_modes_reach_command_and_preserve_exit_status(self) -> None:
        for mode in ("failures", "all", "off"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([
                    str(WRAPPER), "--dir", directory, "--mode", mode, "--",
                    sys.executable, "-c",
                    'import os, sys; print(os.environ["BUTTONHEIST_RESULTS_MODE"]); sys.exit(7)',
                ], capture_output=True, text=True)
                self.assertEqual(result.returncode, 7)
                self.assertEqual(result.stdout.strip(), mode)


if __name__ == "__main__":
    unittest.main()
