"""Check Make callers and Action-only deployment without running a release."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MakeEntryContracts(unittest.TestCase):
    def test_source_repo_entrypoints_forward_target_paths_and_release_options(self):
        with tempfile.TemporaryDirectory() as directory:
            action = Path(directory) / "action fixture"
            action.mkdir()
            targets = "deploy deploy-server deploy-web deploy-test"
            (action / "Makefile").write_text(
                f".PHONY: {targets}\n{targets}:\n"
                "\t@printf '%s\\n' '$@' '$(BACKEND_DIR)' '$(WEB_DIR)' '$(VERSION)' '$(DRY_RUN)' '$(PNPM)'\n")
            for source in ("backend", "web"):
                for target in ("deploy", "deploy-server", "deploy-web", "deploy-test"):
                    with self.subTest(source=source, target=target):
                        result = subprocess.run([
                            "make", "--no-print-directory", target, f"ACTION_DIR={action}",
                            "VERSION=1.2.3", "DRY_RUN=true", "PNPM=fixture-pnpm",
                        ], cwd=ROOT.parent / source, text=True, capture_output=True)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertEqual(result.stdout.splitlines(), [
                            target, str(ROOT.parent / "backend"), str(ROOT.parent / "web"),
                            "1.2.3", "true", "fixture-pnpm",
                        ])

    def test_release_executor_works_with_only_the_action_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            action = Path(directory) / "action"
            action.mkdir()
            shutil.copyfile(ROOT / "Makefile", action / "Makefile")
            shutil.copytree(ROOT / "make", action / "make")
            result = subprocess.run([
                "make", "--no-print-directory", "publish-server", "DRY_RUN=true",
                "DEPLOY_VERSION=v1", "DEPLOY_CHECKSUM=" + "a" * 64,
            ], cwd=action, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("server downloads and verifies GitHub Release deploy-server-v1", result.stdout)
            self.assertFalse((action.parent / "backend").exists())
            self.assertFalse((action.parent / "web").exists())


if __name__ == "__main__":
    unittest.main()
