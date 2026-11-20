"""Make deployment contracts use temporary fixtures, never real SSH, Docker or Pages."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def make(target, **overrides):
    values = dict(DRY_RUN="true", DEPLOY_HOST="release-host", DEPLOY_VERSION="v1",
                  DEPLOY_CHECKSUM="a" * 64)
    values.update(overrides)
    return subprocess.run(["make", "--no-print-directory", target, *[f"{key}={value}" for key, value in values.items()]],
                          cwd=ROOT, text=True, capture_output=True)


def remote_script():
    result = make("publish-server")
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.split("[remote]\n", 1)[1]


class DeploymentContracts(unittest.TestCase):
    def test_invalid_configuration_fails_before_commands(self):
        for key, value in (("DEPLOY_HOST", "-oProxyCommand=bad"), ("DEPLOY_VERSION", "../v1"),
                           ("DEPLOY_DIR", "/"), ("DEPLOY_DIR", "/./"), ("DEPLOY_DIR", "//"),
                           ("DRY_RUN", "yes"), ("DEPLOY_PORT", "70000")):
            with self.subTest(key=key, value=value):
                result = make("publish-server", **{key: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("[plan]", result.stdout)

    def test_dry_runs_and_remote_syntax(self):
        result = make("publish-server")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[plan]", result.stdout)
        self.assertNotIn("one-action", result.stdout)
        subprocess.run(["bash", "-n"], input=remote_script(), text=True, check=True)

    def test_release_requires_version_and_trusted_checksum(self):
        for overrides in ({"DEPLOY_VERSION": ""}, {"DEPLOY_CHECKSUM": ""},
                          {"DEPLOY_CHECKSUM": "bad"}):
            result = make("publish-server", **overrides)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("[plan]", result.stdout)
        result = make("publish-server")
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = result.stdout.split("[remote]", 1)[0]
        self.assertIn("server downloads and verifies GitHub Release deploy-server-v1", plan)
        self.assertNotIn("docker save", plan)
        self.assertNotIn("pnpm", plan)
        self.assertNotIn("web.tar", result.stdout)
        result = make("publish-server", DEPLOY_RELEASE_TAG="deploy-all-v1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("GitHub Release deploy-all-v1", result.stdout)
        for tag in ("deploy-web-v1", "deploy-all-v2", "deploy-all-v1;id"):
            result = make("publish-server", DEPLOY_RELEASE_TAG=tag)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("[plan]", result.stdout)

    def fixture(self, directory, *, fail=False, initial=False, managed=False,
                corrupt=False, bad_manifest=False, download_failure=False,
                nginx="release nginx config", nginx_fail=False):
        root = Path(directory) / "service"
        binaries = Path(directory) / "bin"
        old = root / "web/releases/old"
        for path in (old, binaries, root / "data"):
            path.mkdir(parents=True, exist_ok=True)
        if managed:
            old_deployment = root / "deployments/old"
            old_deployment.mkdir(parents=True)
            (old_deployment / "docker-compose.yml").write_text("previous compose with original settings")
            (old_deployment / "release.env").write_text("DOCKER_IMAGE=registry.example/ipbot:old\nHOST_PORT=27528\n")
            (root / "deployments/current").symlink_to("old")
        (old / "index.html").write_text("old page")
        if not initial:
            (root / "web/current").symlink_to("releases/old")
        (root / ".env").write_text("DB_URL=fixture-only\nAPP_PUBLIC_URL=https://fixture.example\n")
        assets = Path(directory) / "release-assets"
        assets.mkdir()
        (assets / "server-image.tar.gz").write_bytes(b"image fixture")
        (assets / "docker-compose.yml").write_text("release compose")
        names = ["server-image.tar.gz", "docker-compose.yml"]
        if nginx is not None:
            (assets / "nginx.conf").write_text(nginx)
            names.append("nginx.conf")
        site = Path(directory) / "nginx/api.ipbot.net.conf"
        site.parent.mkdir()
        site.write_text("old nginx config")
        manifest = "".join(f"{hashlib.sha256((assets / name).read_bytes()).hexdigest()}  {name}\n" for name in names)
        (assets / "checksums.txt").write_text(manifest)
        checksum = hashlib.sha256(manifest.encode()).hexdigest()
        if corrupt:
            (assets / names[-1]).write_bytes(b"tampered artifact")
        if bad_manifest:
            checksum = "0" * 64
        (binaries / "sleep").write_text("#!/bin/sh\nexit 0\n")
        # macOS lacks GNU sha256sum's --strict; simulate its checksum contract.
        (binaries / "sha256sum").write_text('''#!/usr/bin/env python3
import hashlib, pathlib, sys
args=sys.argv[1:]
assert "--check" in args and "--strict" in args
files=[arg for arg in args if not arg.startswith("-")]
manifest=pathlib.Path(files[0]).read_text() if files else sys.stdin.read()
for line in manifest.splitlines():
    expected, filename=line.split("  ", 1)
    if hashlib.sha256(pathlib.Path(filename).read_bytes()).hexdigest() != expected:
        print("SHA256 mismatch: " + filename, file=sys.stderr)
        sys.exit(1)
''')
        # Docker hosts use GNU mv -T; macOS tests simulate its atomic rename.
        (binaries / "mv").write_text('''#!/usr/bin/env python3
import os, sys
paths=[arg for arg in sys.argv[1:] if not arg.startswith("-")]
os.rename(paths[0], paths[1])
''')
        (binaries / "curl").write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
args=sys.argv[1:]
for value in args:
    if value.startswith("https://github.com/"):
        assert value.startswith("https://github.com/oldbaby5566/ipbot-action/releases/download/deploy-server-")
        if os.environ["DOWNLOAD_FAILURE"] == "true" and value.endswith("server-image.tar.gz"): sys.exit(22)
        shutil.copyfile(pathlib.Path(os.environ["RELEASE_ASSETS"]) / value.rsplit("/", 1)[1], args[args.index("-o")+1])
        sys.exit(0)
assert any(value.endswith('/readyz') for value in args)
if os.environ["FAIL_HEALTH"] == "true": sys.exit(1)
''')
        (binaries / "docker").write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args=sys.argv[1:]
image=os.environ.get("DOCKER_IMAGE", "")
if not image and args[0]=="compose":
    positions=[i for i,arg in enumerate(args) if arg=="--env-file"]
    data=pathlib.Path(args[positions[-1]+1]).read_text()
    image=next(line.split("=",1)[1] for line in data.splitlines() if line.startswith("DOCKER_IMAGE="))
with open(os.environ["DOCKER_LOG"],"a") as log: log.write(json.dumps({"args":args,"image":image})+"\\n")
if args[:2]==["image","inspect"]: print("sha256:"+"a"*64)
elif args[0] in ('create','cp'): sys.exit('Server must not extract Web from images')
elif args[0]=="inspect": print("sha256:"+"b"*64)
elif args[0]=="compose" and args[-3:]==["ps","-q","ip"] and os.environ["INITIAL"]!="true": print("old-container")
''')
        (binaries / "sudo").write_text('#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n')
        (binaries / "nginx").write_text('''#!/usr/bin/env python3
import os, pathlib, sys
with open(os.environ["NGINX_LOG"], "a") as log: log.write("nginx " + " ".join(sys.argv[1:]) + "\\n")
if os.environ["NGINX_FAIL"] == "true" and pathlib.Path(os.environ["NGINX_SITE"]).read_text().startswith("release"): sys.exit(1)
''')
        (binaries / "systemctl").write_text('''#!/usr/bin/env python3
import os, sys
with open(os.environ["NGINX_LOG"], "a") as log: log.write("systemctl " + " ".join(sys.argv[1:]) + "\\n")
''')
        for path in binaries.iterdir():
            path.chmod(0o755)
        environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"], FAKE_ROOT=str(root), FAIL_HEALTH=str(fail).lower(), INITIAL=str(initial).lower(), DOCKER_LOG=str(Path(directory) / "docker.log"), RELEASE_ASSETS=str(assets), DOWNLOAD_FAILURE=str(download_failure).lower(), NGINX_SITE=str(site), NGINX_FAIL=str(nginx_fail).lower(), NGINX_LOG=str(Path(directory) / "nginx.log"))
        environment.pop("DOCKER_IMAGE", None)
        result = subprocess.run(["bash", "-se", "--", str(root), "v1", "27528", "one-ip", checksum], input=remote_script(), text=True, env=environment, capture_output=True)
        self.assertEqual((root / ".env").read_text(), "DB_URL=fixture-only\nAPP_PUBLIC_URL=https://fixture.example\n")
        self.assertFalse(list(root.glob(".deploy-*")))
        self.assertFalse((root / ".deployment-lock").exists())
        return root, result, Path(directory) / "docker.log"

    def test_release_download_success_and_health_rollback(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as directory:
                root, result, log = self.fixture(directory, fail=fail, managed=True)
                self.assertEqual(result.returncode == 0, not fail, result.stdout + result.stderr)
                self.assertEqual(os.readlink(root / "web/current"), "releases/old")
                calls = [json.loads(line)["args"] for line in log.read_text().splitlines()]
                self.assertTrue(any(call[:2] == ["load", "--input"] for call in calls))
                self.assertFalse(any(call[0] in ("pull", "create", "cp") for call in calls))
                self.assertEqual(os.readlink(root / "deployments/current"), "old" if fail else "v1")

    def test_release_download_and_checksum_failures_do_not_change_running_version(self):
        for failure in ("corrupt", "bad_manifest", "download_failure"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root, result, log = self.fixture(directory, **{failure: True})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(os.readlink(root / "web/current"), "releases/old")
                self.assertFalse(log.exists())

    def test_server_success_pins_image_and_managed_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root, result, log = self.fixture(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(os.readlink(root / "web/current"), "releases/old")
            self.assertFalse((root / 'web/releases/v1').exists())
            self.assertEqual(os.readlink(root / "deployments/current"), "v1")
            values=(root / "deployments/v1/release.env").read_text()
            self.assertIn("DOCKER_IMAGE=sha256:" + "a"*64, values)
            self.assertTrue(log.exists())

    def test_server_health_failure_restores_old_immutable_image(self):
        with tempfile.TemporaryDirectory() as directory:
            root, result, log = self.fixture(directory, fail=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(os.readlink(root / "web/current"), "releases/old")
            calls=[json.loads(line) for line in log.read_text().splitlines()]
            starts=[call for call in calls if "up" in call["args"]]
            self.assertEqual(len(starts), 2)
            self.assertEqual(starts[-1]["image"], "sha256:" + "b"*64)
            self.assertFalse((root / "deployments/current").exists())

    def test_failed_first_server_deployment_removes_new_container(self):
        with tempfile.TemporaryDirectory() as directory:
            root, result, log = self.fixture(directory, fail=True, initial=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "web/current").exists())
            calls=[json.loads(line) for line in log.read_text().splitlines()]
            self.assertTrue(any(call["args"][-4:]==["rm","--stop","--force","ip"] for call in calls))

    def test_server_rollback_reuses_previous_manifest_and_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root, result, log = self.fixture(directory, fail=True, managed=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(os.readlink(root / "deployments/current"), "old")
            calls=[json.loads(line) for line in log.read_text().splitlines()]
            starts=[call for call in calls if "up" in call["args"]]
            restored=starts[-1]
            self.assertIn(str((root / "deployments/old/docker-compose.yml").resolve()), restored["args"])
            self.assertIn(str((root / "deployments/old/release.env").resolve()), restored["args"])
            self.assertEqual((root / "deployments/old/docker-compose.yml").read_text(), "previous compose with original settings")


    def nginx_state(self, directory):
        site = (Path(directory) / "nginx/api.ipbot.net.conf").read_text()
        log = Path(directory) / "nginx.log"
        return site, log.read_text().splitlines() if log.exists() else []

    def test_release_installs_changed_nginx_config_after_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            root, result, _ = self.fixture(directory, managed=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            site, calls = self.nginx_state(directory)
            self.assertEqual(site, "release nginx config")
            self.assertEqual(calls, ["nginx -t", "systemctl reload nginx"])
            self.assertEqual((root / "deployments/v1/nginx.conf").read_text(), "release nginx config")
            self.assertEqual((root / "deployments/v1/nginx.previous.conf").read_text(), "old nginx config")

    def test_unchanged_nginx_config_is_not_reloaded(self):
        with tempfile.TemporaryDirectory() as directory:
            _, result, _ = self.fixture(directory, nginx="old nginx config")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.nginx_state(directory), ("old nginx config", []))

    def test_rejected_nginx_config_restores_nginx_and_server(self):
        with tempfile.TemporaryDirectory() as directory:
            root, result, log = self.fixture(directory, managed=True, nginx_fail=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("nginx rejected the release config", result.stderr)
            site, calls = self.nginx_state(directory)
            self.assertEqual(site, "old nginx config")
            self.assertEqual(calls, ["nginx -t", "nginx -t", "systemctl reload nginx"])
            self.assertEqual(os.readlink(root / "deployments/current"), "old")
            starts = [json.loads(line) for line in log.read_text().splitlines() if '"up"' in line]
            self.assertEqual(len(starts), 2)

    def test_failed_readiness_leaves_nginx_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            _, result, _ = self.fixture(directory, fail=True, managed=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.nginx_state(directory), ("old nginx config", []))

    def test_release_without_nginx_config_still_deploys(self):
        with tempfile.TemporaryDirectory() as directory:
            root, result, _ = self.fixture(directory, nginx=None)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.nginx_state(directory), ("old nginx config", []))
            self.assertFalse((root / "deployments/v1/nginx.conf").exists())


if __name__ == "__main__":
    unittest.main()
