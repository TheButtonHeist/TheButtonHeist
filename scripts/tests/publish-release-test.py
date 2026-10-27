#!/usr/bin/env python3
"""Exercise publication failures and retries without a release or live tap."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("publish_release", ROOT / "scripts/publish-release.py")
PUBLICATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUBLICATION)


class PublicationTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.archives = (
            "buttonheist-1.2.3-macos.tar.gz", "buttonheist-mcp-1.2.3-macos.tar.gz",
            "bh-demo-1.2.3-iphonesimulator.zip", "theinsidejob-1.2.3.zip",
        )
        for name in self.archives:
            (self.dist / name).write_bytes(name.encode())
        (self.dist / "checksums.txt").write_text("".join(
            f"{hashlib.sha256((self.dist / name).read_bytes()).hexdigest()}  {name}\n"
            for name in self.archives
        ))
        self.notes = self.root / "notes.txt"
        self.notes.write_text("Release notes\n")
        self.release = None
        self.other_releases = []
        self.assets = {}
        self.calls = []
        self.failure = ""
        self.concurrent = False
        self.head = "original-commit"
        self.tree = {"README.md": "Keep unrelated tap content\n",
                     "Formula/buttonheist.rb": "old CLI\n",
                     "Formula/theinsidejob.rb": "old runtime\n"}
        self.pending_tree = None
        self.parent = None
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {"HOMEBREW_TAP_TOKEN": "tap-token"}).start()
        patch.object(PUBLICATION, "gh", self.gh).start()

    def gh(self, *arguments, payload=None, token=None):
        args = list(arguments)
        self.calls.append((args, payload, token))
        if args[:2] == ["release", "create"]:
            self.assertIn("--draft", args)
            self.release = {"tag_name": "v1.2.3", "draft": True}
        elif args[:2] == ["release", "upload"]:
            self.assertTrue(self.release["draft"], "Published assets must never be replaced")
            self.assertIn("--clobber", args)
            for argument in args:
                if Path(argument).is_file():
                    self.assets[Path(argument).name] = Path(argument).read_bytes()
                    if self.failure == "upload":
                        raise subprocess.CalledProcessError(1, args)
        elif args[:2] == ["release", "download"]:
            if self.failure == "download":
                raise subprocess.CalledProcessError(1, args)
            output = Path(args[args.index("--dir") + 1])
            for name, content in self.assets.items():
                (output / name).write_bytes(content)
        elif args[:2] == ["release", "edit"]:
            self.assertIn("--draft=false", args)
            if self.failure == "publish":
                raise subprocess.CalledProcessError(1, args)
            self.release["draft"] = False
        elif args[0] == "api":
            endpoint = args[1]
            method = args[args.index("--method") + 1]
            if (self.failure in ("trees", "commits") and endpoint.endswith(f"/git/{self.failure}")) or (
                self.failure == "ref" and "/git/refs/" in endpoint
            ):
                raise subprocess.CalledProcessError(1, args)
            if endpoint.endswith("/releases"):
                if self.failure == "lookup":
                    raise subprocess.CalledProcessError(1, args)
                return json.dumps([self.other_releases, [self.release] if self.release else []])
            self.assertEqual(token, "tap-token")
            if endpoint == "repos/TheButtonHeist/homebrew-tap":
                return json.dumps({"default_branch": "main"})
            if endpoint.endswith("/git/ref/heads/main"):
                return json.dumps({"object": {"sha": self.head}})
            if "/git/commits/" in endpoint:
                return json.dumps({"tree": {"sha": "base-tree"}})
            if endpoint.endswith("/git/trees"):
                self.assertEqual(payload["base_tree"], "base-tree")
                self.assertEqual({entry["path"] for entry in payload["tree"]},
                                 {"Formula/buttonheist.rb", "Formula/theinsidejob.rb"})
                self.pending_tree = {**self.tree, **{
                    entry["path"]: entry["content"] for entry in payload["tree"]}}
                return json.dumps({"sha": "base-tree" if self.pending_tree == self.tree else "new-tree"})
            if endpoint.endswith("/git/commits"):
                self.parent = payload["parents"]
                return json.dumps({"sha": "new-commit"})
            if endpoint.endswith("/git/refs/heads/main"):
                self.assertEqual(method, "PATCH")
                self.assertIs(payload["force"], False)
                if self.concurrent:
                    self.head = "concurrent-commit"
                    self.tree["README.md"] = "Concurrent tap edit\n"
                if self.parent != [self.head]:
                    raise subprocess.CalledProcessError(1, args)
                self.tree = self.pending_tree
                self.head = payload["sha"]
                if self.failure == "lost-response":
                    raise subprocess.CalledProcessError(1, args)
                return json.dumps({"object": {"sha": self.head}})
            else:
                raise AssertionError(f"Unexpected API request: {args}")
        else:
            raise AssertionError(f"Unexpected command: {args}")
        return ""

    def publish(self):
        PUBLICATION.publish("1.2.3", self.dist, self.notes)

    def published(self):
        self.release = {"tag_name": "v1.2.3", "draft": False}
        self.assets = {file.name: file.read_bytes() for file in self.dist.iterdir()}

    def test_new_release_is_verified_before_publication_and_atomic_tap_update(self):
        self.publish()
        self.assertFalse(self.release["draft"])
        self.assertEqual(set(self.assets), {*self.archives, "checksums.txt"})
        self.assertEqual(self.tree["README.md"], "Keep unrelated tap content\n")
        for name in ("buttonheist", "theinsidejob"):
            self.assertIn('version "1.2.3"', self.tree[f"Formula/{name}.rb"])
        commands = [args[:2] for args, _, _ in self.calls]
        self.assertLess(commands.index(["release", "download"]), commands.index(["release", "edit"]))
        self.assertEqual(sum("/git/refs/" in args[1] for args, _, _ in self.calls), 1)

    def test_partial_upload_stays_draft_and_can_be_retried(self):
        self.failure = "upload"
        original = self.tree.copy()
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertTrue(self.release["draft"])
        self.assertEqual(self.tree, original)
        self.assertEqual(len(self.assets), 1)
        self.failure = ""
        self.publish()
        self.assertFalse(self.release["draft"])
        self.assertEqual(set(self.assets), {*self.archives, "checksums.txt"})

    def test_published_retry_uses_published_bytes_and_is_noop_for_current_tap(self):
        self.published()
        for file in self.dist.iterdir():
            file.write_text("Different rebuilt bytes\n")
        self.publish()
        for artifact, formula in ((self.archives[0], "buttonheist"),
                                  (self.archives[3], "theinsidejob")):
            self.assertIn(hashlib.sha256(self.assets[artifact]).hexdigest(),
                          self.tree[f"Formula/{formula}.rb"])
        self.calls.clear()
        self.publish()
        self.assertFalse(any(args[1] in ("create", "upload", "edit")
                             for args, _, _ in self.calls))
        self.assertFalse(any(args[1].endswith(("/git/commits", "/git/refs/heads/main"))
                             for args, _, _ in self.calls))

    def test_published_retry_needs_no_local_archives_or_release_notes(self):
        self.published()
        shutil.rmtree(self.dist)
        self.notes.unlink()
        self.publish()
        self.assertFalse(any(args[0] == "release" and args[1] in ("create", "upload", "edit")
                             for args, _, _ in self.calls))

    def test_tap_failures_leave_both_previous_formulas_and_release_intact(self):
        self.published()
        original = self.tree.copy()
        for failure in ("trees", "commits", "ref"):
            with self.subTest(failure=failure):
                self.failure = failure
                with self.assertRaises(subprocess.CalledProcessError):
                    self.publish()
                self.assertEqual(self.tree, original)
                self.assertFalse(self.release["draft"])
        self.failure = ""
        self.publish()
        self.assertNotEqual(self.tree, original)

    def test_retry_after_lost_ref_response_does_not_add_a_second_commit(self):
        self.published()
        self.failure = "lost-response"
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        committed = self.tree.copy()
        self.failure = ""
        self.calls.clear()
        self.publish()
        self.assertEqual(self.tree, committed)
        self.assertFalse(any(args[1].endswith("/git/commits") for args, _, _ in self.calls))

    def test_concurrent_tap_edit_is_not_overwritten(self):
        self.published()
        self.concurrent = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertEqual(self.tree["Formula/buttonheist.rb"], "old CLI\n")
        self.assertEqual(self.tree["Formula/theinsidejob.rb"], "old runtime\n")
        self.assertEqual(self.tree["README.md"], "Concurrent tap edit\n")
        self.concurrent = False
        self.publish()
        self.assertEqual(self.tree["README.md"], "Concurrent tap edit\n")

    def test_lookup_download_or_publish_failure_does_not_update_tap(self):
        original = self.tree.copy()
        for failure in ("lookup", "download", "publish"):
            with self.subTest(failure=failure):
                self.failure = failure
                with self.assertRaises(subprocess.CalledProcessError):
                    self.publish()
                self.assertEqual(self.tree, original)
                if self.release:
                    self.assertTrue(self.release["draft"])

    def test_rejects_corrupt_missing_duplicate_or_unsafe_published_checksums(self):
        self.published()
        original = self.tree.copy()
        manifest = self.assets["checksums.txt"]
        for invalid in (manifest.replace(b"buttonheist-", b"../buttonheist-", 1),
                        manifest.splitlines(keepends=True)[0], manifest + manifest,
                        manifest.replace(manifest[:64], b"0" * 64, 1)):
            with self.subTest(manifest=invalid):
                self.assets["checksums.txt"] = invalid
                with self.assertRaises(ValueError):
                    self.publish()
                self.assertEqual(self.tree, original)
                self.assertFalse(self.release["draft"])

    def test_missing_tap_token_fails_before_any_publication(self):
        with patch.dict(os.environ, {"HOMEBREW_TAP_TOKEN": ""}):
            with self.assertRaisesRegex(ValueError, "HOMEBREW_TAP_TOKEN"):
                self.publish()
        self.assertIsNone(self.release)
        self.assertEqual(self.calls, [])

    def test_invalid_versions_fail_before_any_publication(self):
        for version in ("01.2.3", "1.02.3", "1.2.03", "1.2.3-abcdef012345", "1.2.3\n"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                PUBLICATION.publish(version, self.dist, self.notes)
        self.assertEqual(self.calls, [])

    def test_invalid_staged_archive_never_creates_a_release(self):
        (self.dist / self.archives[0]).write_text("corrupt build")
        with self.assertRaises(ValueError):
            self.publish()
        self.assertIsNone(self.release)
        self.assertFalse(any(args[0] == "release" for args, _, _ in self.calls))

    def test_retry_of_older_release_cannot_downgrade_tap(self):
        self.published()
        self.other_releases = [{"tag_name": "v1.2.4", "draft": False}]
        original = self.tree.copy()
        with self.assertRaisesRegex(ValueError, "refusing a downgrade"):
            self.publish()
        self.assertEqual(self.tree, original)
        self.assertEqual(len(self.calls), 1)


class GitHubBoundaryTests(unittest.TestCase):
    def test_json_input_keeps_booleans_and_scopes_the_tap_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "gh"
            executable.write_text('''#!/usr/bin/env python3
import json, os, sys
print(json.dumps({"arguments": sys.argv[1:], "input": json.load(sys.stdin),
                  "token": os.environ["GH_TOKEN"]}))
''')
            executable.chmod(0o755)
            with patch.dict(os.environ, {"PATH": f"{temporary}:{os.environ['PATH']}", "GH_TOKEN": "source-token"}):
                output = json.loads(PUBLICATION.gh("api", "tap-ref", "--method", "PATCH",
                                                  payload={"sha": "commit", "force": False}, token="tap-token"))
                self.assertEqual(output["arguments"], ["api", "tap-ref", "--method", "PATCH", "--input", "-"])
                self.assertEqual(output["input"], {"sha": "commit", "force": False})
                self.assertEqual(output["token"], "tap-token")
                self.assertEqual(os.environ["GH_TOKEN"], "source-token")


if __name__ == "__main__":
    unittest.main()
