"""Release checks use local Git remotes and fake tools, with no network access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def git(directory, *args):
    return subprocess.run(["git", "-C", str(directory), *args], check=True,
                          text=True, capture_output=True).stdout.strip()


class ReleaseContracts(unittest.TestCase):
    def fixture(self, directory, *, target="server", fail="", dry_run=False, dispatch_status="204"):
        base = Path(directory)
        repos = {}
        initial = {}
        for name, files in {
            "backend": {
                "Cargo.toml": '[package]\nname = "one-ip-backend"\nversion = "1.0.0"\n',
                "Cargo.lock": '[[package]]\nname = "one-ip-backend"\nversion = "1.0.0"\n',
            },
            "web": {"package.json": '{"name":"fixture","version":"1.0.0"}\n'},
            "action": {"README.md": "Action fixture\n"},
        }.items():
            repo = base / name
            repo.mkdir()
            remote = base / (name + ".git")
            remote.mkdir()
            git(remote, "init", "--bare")
            git(repo, "init", "-b", "main")
            git(repo, "config", "user.name", "Fixture")
            git(repo, "config", "user.email", "fixture@example.invalid")
            git(repo, "config", "core.hooksPath", "/dev/null")
            git(repo, "config", "commit.gpgsign", "false")
            for filename, content in files.items():
                (repo / filename).write_text(content)
            git(repo, "add", ".")
            git(repo, "commit", "-m", "fixture")
            git(repo, "remote", "add", "origin", str(remote))
            git(repo, "push", "-u", "origin", "main")
            repos[name] = repo
            initial[name] = git(repo, "rev-parse", "HEAD")

        binaries = base / "bin"
        binaries.mkdir()
        gate = '''#!/usr/bin/env python3
import os, pathlib, sys
base=pathlib.Path(os.environ["FIXTURE_BASE"])
tool=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
if tool == "curl":
    assert "Authorization: Bearer " in sys.stdin.read()
    payload=pathlib.Path(args[args.index("--data-binary")+1][1:]).read_text()
    (base/"dispatch.json").write_text(payload)
    pathlib.Path(args[args.index("--output")+1]).write_text('{"message":"dispatch fixture"}')
    print(os.environ["DISPATCH_STATUS"], end="")
    sys.exit(0)
gate=args[-1] if tool == "pnpm" else args[0]
with (base/"gates.log").open("a") as out: out.write(tool+":"+gate+"\\n")
if os.environ["FAIL_GATE"] == tool: sys.exit(23)
'''
        for name in ("pnpm", "cargo", "curl"):
            (binaries / name).write_text(gate)
            (binaries / name).chmod(0o755)
        env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                   FIXTURE_BASE=str(base), TARGET=target, FAIL_GATE=fail,
                   GH_TOKEN="fixture_token_not_a_credential", RELEASE_VERSION="1.2.3",
                   BACKEND_DIR=str(repos["backend"]),
                   WEB_DIR=str(repos["web"]), ACTION_DIR=str(repos["action"]),
                   DRY_RUN=str(dry_run).lower(), DISPATCH_STATUS=dispatch_status)
        result = subprocess.run(["bash", str(ROOT / "scripts/release.sh")],
                                cwd=repos["backend"], env=env, capture_output=True, text=True)
        return repos, initial, result

    def test_server_checks_publish_only_backend_sha_then_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            repos, initial, result = self.fixture(directory)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            payload = json.loads((Path(directory) / "dispatch.json").read_text())
            self.assertEqual(payload["ref"], "main")
            self.assertEqual(payload["inputs"], dict(
                target="server", version="1.2.3", expected_action_sha=initial["action"],
                backend_ref=git(repos["backend"], "rev-parse", "HEAD"),
                web_ref=""))
            for name in ("backend", "web"):
                self.assertEqual(git(repos[name], "status", "--porcelain"), "")
                self.assertEqual(git(repos[name], "rev-parse", "HEAD"), git(repos[name], "rev-parse", "origin/main"))
            self.assertIn('version = "1.2.3"', (repos["backend"] / "Cargo.lock").read_text())
            self.assertEqual(git(repos["backend"], "rev-parse", "deploy-server-1.2.3"), payload["inputs"]["backend_ref"])
            self.assertEqual(git(repos["web"], "rev-parse", "HEAD"), initial["web"])
            self.assertEqual(git(repos["web"], "tag"), "")
            self.assertNotIn("pnpm:", (Path(directory) / "gates.log").read_text())

    def test_each_failed_check_blocks_versions_tags_and_dispatch(self):
        for target, tool in (("web", "pnpm"), ("server", "cargo")):
            with self.subTest(target=target, tool=tool), tempfile.TemporaryDirectory() as directory:
                repos, initial, result = self.fixture(directory, target=target, fail=tool)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((Path(directory) / "dispatch.json").exists())
                for name in ("backend", "web"):
                    self.assertEqual(git(repos[name], "rev-parse", "HEAD"), initial[name])
                    self.assertEqual(git(repos[name], "status", "--porcelain"), "")
                    self.assertEqual(git(repos[name], "tag"), "")

    def test_web_release_preserves_backend_version_and_skips_cargo(self):
        with tempfile.TemporaryDirectory() as directory:
            repos, initial, result = self.fixture(directory, target="web", dispatch_status="200")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(git(repos["backend"], "rev-parse", "HEAD"), initial["backend"])
            self.assertNotIn("cargo:", (Path(directory) / "gates.log").read_text())
            inputs = json.loads((Path(directory) / "dispatch.json").read_text())["inputs"]
            self.assertEqual(inputs["target"], "web")
            self.assertEqual(inputs["backend_ref"], "")
            self.assertEqual(inputs["web_ref"], git(repos["web"], "rev-parse", "v1.2.3"))
            self.assertEqual(git(repos["backend"], "tag"), "")

    def test_dry_run_has_no_checks_commits_or_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            repos, initial, result = self.fixture(directory, dry_run=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((Path(directory) / "gates.log").exists())
            self.assertFalse((Path(directory) / "dispatch.json").exists())
            for name in repos:
                self.assertEqual(git(repos[name], "rev-parse", "HEAD"), initial[name])

    def test_dispatch_failure_reports_published_sources_and_original_error(self):
        with tempfile.TemporaryDirectory() as directory:
            repos, initial, result = self.fixture(directory, target="web", dispatch_status="403")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Sources published, but Action dispatch failed (HTTP 403)", result.stderr)
            self.assertIn('"message":"dispatch fixture"', result.stderr)
            self.assertNotEqual(git(repos["web"], "rev-parse", "HEAD"), initial["web"])


if __name__ == "__main__":
    unittest.main()
