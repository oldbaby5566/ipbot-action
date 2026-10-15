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
                  DEPLOY_IMAGE="registry.example/ipbot:v1", DEPLOY_PLATFORM="linux/amd64",
                  DEPLOY_TRANSFER="registry", CLOUDFLARE_ACCOUNT_ID="a" * 32,
                  CLOUDFLARE_PAGES_PROJECT="ipbot", CLOUDFLARE_PAGES_BRANCH="main")
    values.update(overrides)
    return subprocess.run(["make", "--no-print-directory", target, *[f"{key}={value}" for key, value in values.items()]],
                          cwd=ROOT, text=True, capture_output=True)


def remote_script():
    result = make("publish-server")
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.split("[remote]\n", 1)[1]


class DeploymentContracts(unittest.TestCase):
    def config(self, mode="server", **overrides):
        return overrides

    def test_invalid_configuration_fails_before_commands(self):
        for key, value in (("DEPLOY_HOST", "-oProxyCommand=bad"), ("DEPLOY_IMAGE", "ipbot:latest"),
                           ("DEPLOY_IMAGE", "ipbot"), ("DEPLOY_VERSION", "../v1"), ("DEPLOY_DIR", "/"),
                           ("DEPLOY_DIR", "/./"), ("DEPLOY_DIR", "//"), ("DRY_RUN", "yes"),
                           ("DEPLOY_TRANSFER", "ftp"), ("DEPLOY_PORT", "70000")):
            with self.subTest(key=key, value=value):
                result = make("publish-server", **{key: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("[plan]", result.stdout)

    def test_stage_requires_its_own_settings(self):
        result = make("deploy-stage")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DEPLOY_STAGE_VERSION", result.stderr)
        result = make("deploy-stage", DEPLOY_STAGE_HOST="stage", DEPLOY_STAGE_DIR="/opt/one-ip-stage",
                      DEPLOY_STAGE_IMAGE="ipbot:stage-v1", DEPLOY_STAGE_VERSION="stage-v1", DEPLOY_STAGE_PORT="27530")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("environment=stage", result.stdout)
        self.assertIn("host=stage", result.stdout)
        self.assertNotIn("host=release-host", result.stdout)
        stage = dict(DEPLOY_STAGE_VERSION="stage-v1", CLOUDFLARE_STAGE_ACCOUNT_ID="b" * 32,
                     CLOUDFLARE_STAGE_PAGES_PROJECT="ipbot-stage", CLOUDFLARE_STAGE_PAGES_BRANCH="stage",
                     VITE_API_BASE_URL="https://api.ipbot.net/api")
        result = make("deploy-stage-web", **stage)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DEPLOY_STAGE_API_BASE_URL", result.stderr)
        result = make("deploy-stage-web", DEPLOY_STAGE_API_BASE_URL="https://stage-api.example/api", **stage)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build:stage", result.stdout)
        self.assertIn("--project-name ipbot-stage --branch stage", result.stdout)
        self.assertIn("api=https://stage-api.example/api", result.stdout)
        self.assertNotIn("api=https://api.ipbot.net/api", result.stdout)

    def test_stage_image_requires_its_own_platform(self):
        result = make("image-build-stage", DEPLOY_STAGE_IMAGE="ipbot:stage-v1", DEPLOY_STAGE_VERSION="stage-v1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DEPLOY_STAGE_PLATFORM", result.stderr)

    def test_dry_runs_and_remote_syntax(self):
        for target in ("image-build", "publish-server", "publish-web"):
            result = make(target)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("[plan]", result.stdout)
            self.assertNotIn("one-action", result.stdout)
        subprocess.run(["bash", "-n"], input=remote_script(), text=True, check=True)
        plan = make("publish-web").stdout
        self.assertIn("wrangler pages deploy dist", plan)
        self.assertNotIn("[remote]", plan)
        self.assertNotIn("docker", plan)

    def test_ssh_transfer_builds_and_pins_local_image(self):
        result = make("publish-server", DEPLOY_TRANSFER="ssh", DEPLOY_IMAGE="", DEPLOY_VERSION="", DEPLOY_SUDO="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("docker build", result.stdout)
        self.assertIn("docker save one-ip:", result.stdout)
        self.assertIn("sudo -n docker load", result.stdout)
        self.assertIn("{{.Id}}", result.stdout)
        self.assertNotIn("pnpm", result.stdout)
        self.assertNotIn("web-dist", result.stdout)

    def test_release_transfer_requires_matching_tag_and_trusted_checksum(self):
        for overrides in ({}, {"DEPLOY_RELEASE": "deploy-server-other"},
                          {"DEPLOY_RELEASE": "deploy-server-v1", "DEPLOY_CHECKSUM": "bad"}):
            result = make("publish-server", DEPLOY_TRANSFER="release", **overrides)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("[plan]", result.stdout)
        result = make("publish-server", DEPLOY_TRANSFER="release",
                      DEPLOY_RELEASE="deploy-server-v1", DEPLOY_CHECKSUM="a" * 64)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = result.stdout.split("[remote]", 1)[0]
        self.assertIn("server downloads and verifies GitHub Release", plan)
        self.assertNotIn("docker save", plan)
        self.assertNotIn("pnpm", plan)
        self.assertNotIn("web.tar", result.stdout)

    def test_native_image_context_excludes_private_files(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            backend, binaries = base / 'backend', base / 'bin'
            for path in (backend / 'src', backend / 'sql', backend / 'deploy/docker', backend / 'data', binaries):
                path.mkdir(parents=True, exist_ok=True)
            for name in ('Cargo.toml', 'Cargo.lock', 'rust-toolchain.toml', '.env', 'deploy/docker/Dockerfile'):
                (backend / name).write_text('fixture')
            (backend / 'Makefile').write_text(f'BACKEND_DIR := .\nWEB_DIR := ../absent-web\nPNPM := pnpm\ninclude {ROOT}/make/deploy.mk\n')
            commands = {
                'pnpm': '#!/bin/sh\necho "Unexpected Web build" >&2\nexit 99\n',
                'curl': '#!/usr/bin/env python3\nimport pathlib,sys\nargs=sys.argv; pathlib.Path(args[args.index("--output")+1]).write_text("font fixture")\n',
                'shasum': '#!/bin/sh\ncase "$3" in *Regular*) echo faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9 ;; *) echo c6cb5a93abaa9edc8ee7463b7ebb7f42d618d40e6ed2f7a5371c97b0b64767c0 ;; esac\n',
                'docker': '''#!/usr/bin/env python3
import json,os,pathlib,sys
context=pathlib.Path(sys.argv[-1])
assert not (context/'.env').exists()
assert not (context/'data').exists()
assert not (context/'web-dist').exists()
assert (context/'fonts/NotoSansSC-Regular.otf').is_file()
assert (context/'fonts/NotoSansSC-Bold.otf').is_file()
pathlib.Path(os.environ['BUILD_LOG']).write_text(json.dumps(dict(args=sys.argv[1:],context=str(context))))
''',
            }
            for name, content in commands.items():
                path = binaries / name
                path.write_text(content)
                path.chmod(0o755)
            log = base / 'build.json'
            result = subprocess.run(['make', '--no-print-directory', 'image-build', 'DRY_RUN=false',
                                     'DEPLOY_IMAGE=ipbot:v1', 'DEPLOY_VERSION=v1', 'DEPLOY_PLATFORM=linux/amd64'],
                                    cwd=backend, env=dict(os.environ, PATH=str(binaries)+os.pathsep+os.environ['PATH'],
                                                         BUILD_LOG=str(log)), text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            built = json.loads(log.read_text())
            self.assertIn('linux/amd64', built['args'])
            self.assertFalse(Path(built['context']).exists())

    def pages_fixture(self, directory, *, fail=False):
        base = Path(directory)
        service, web, binaries = base / "service ' $(touch unexpected-file)", base / 'web', base / 'bin'
        for path in (service / 'web/releases/old', service / 'deployments/old', web / 'dist', binaries):
            path.mkdir(parents=True, exist_ok=True)
        (service / 'web/current').symlink_to('releases/old')
        (service / 'deployments/current').symlink_to('old')
        (service / '.env').write_text('private fixture')
        for name in ('index.html', 'app-version.json'):
            (web / 'dist' / name).write_text('fixture')
        commands = {
            'git': '#!/bin/sh\n[ "$1" = rev-parse ] && [ "$2" = HEAD ] || exit 99\nprintf "%040d\\n" 1\n',
            'ssh': '#!/bin/sh\necho "Unexpected SSH call" >&2\nexit 99\n',
            'docker': '#!/bin/sh\necho "Unexpected Docker call" >&2\nexit 99\n',
            'pnpm': '''#!/usr/bin/env python3
import json,os,pathlib,sys
args=sys.argv[1:]
with open(os.environ['PAGES_LOG'],'a') as log:
    log.write(json.dumps({'args':args,'account':os.environ.get('CLOUDFLARE_ACCOUNT_ID'),'token_present':bool(os.environ.get('CLOUDFLARE_API_TOKEN'))})+'\\n')
if args==['build']: sys.exit(0)
assert args[:5]==['dlx','wrangler@4','pages','deploy','dist']
assert os.environ['CLOUDFLARE_ACCOUNT_ID']=='a'*32
assert os.environ['CLOUDFLARE_API_TOKEN']=='fixture-pages-not-a-credential'
assert pathlib.Path('dist/one-web-revision.txt').read_text()=='v1\\n'
sys.exit(24 if os.environ['FAIL_PAGES']=='true' else 0)
''',
        }
        for name, content in commands.items():
            path = binaries / name
            path.write_text(content)
            path.chmod(0o755)
        log = base / 'pages.jsonl'
        result = subprocess.run(['make', '--no-print-directory', 'publish-web', 'DRY_RUN=false',
                                 'DEPLOY_HOST=release-host', 'DEPLOY_DIR=' + str(service).replace('$', '$$'),
                                 'DEPLOY_IMAGE=', 'DEPLOY_VERSION=v1', f'WEB_DIR={web}',
                                 'CLOUDFLARE_ACCOUNT_ID=' + 'a' * 32, 'CLOUDFLARE_PAGES_PROJECT=ipbot',
                                 'CLOUDFLARE_PAGES_BRANCH=main'], cwd=ROOT,
                                env=dict(os.environ, PATH=str(binaries)+os.pathsep+os.environ['PATH'],
                                         PAGES_LOG=str(log), FAIL_PAGES=str(fail).lower(),
                                         CLOUDFLARE_API_TOKEN='fixture-pages-not-a-credential'),
                                text=True, capture_output=True)
        self.assertEqual((service / '.env').read_text(), 'private fixture')
        self.assertEqual(os.readlink(service / 'web/current'), 'releases/old')
        self.assertEqual(os.readlink(service / 'deployments/current'), 'old')
        self.assertFalse((service / '.deployment-lock').exists())
        self.assertFalse(list(service.glob('.deploy-*')))
        self.assertFalse((ROOT / 'unexpected-file').exists())
        self.assertNotIn('fixture-pages-not-a-credential', result.stdout + result.stderr)
        return service, result, log

    def test_native_pages_upload_preserves_server_and_credentials(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as directory:
                service, result, log = self.pages_fixture(directory, fail=fail)
                self.assertEqual(result.returncode == 0, not fail, result.stdout + result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(calls[0]['args'], ['build'])
                self.assertTrue(calls[-1]['token_present'])
                self.assertNotIn('fixture-pages-not-a-credential', log.read_text())

    def fixture(self, directory, mode="server", *, fail=False, initial=False, managed=False,
                transfer="registry", corrupt=False, bad_manifest=False, download_failure=False):
        root = Path(directory) / "service"
        incoming = root / ".incoming"
        binaries = Path(directory) / "bin"
        old = root / "web/releases/old"
        for path in (old, incoming, binaries, root / "data"):
            path.mkdir(parents=True, exist_ok=True)
        (root / ".deployment-lock").mkdir()
        (root / ".deployment-lock/owner").write_text(str(incoming) + "\n")
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
        (incoming / "docker-compose.yml").write_text("fixture compose")
        assets = Path(directory) / "release-assets"
        assets.mkdir()
        checksum = ""
        if transfer == "release":
            (assets / "server-image.tar.gz").write_bytes(b"image fixture")
            (assets / "docker-compose.yml").write_text("release compose")
            names = ["server-image.tar.gz", "docker-compose.yml"]
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
if args[:2]==["image","inspect"]: print(("sha256:" if "{{.Id}}" in args else "registry.example/ipbot@sha256:")+"a"*64)
elif args[0] in ('create','cp'): sys.exit('Server must not extract Web from images')
elif args[0]=="inspect": print("sha256:"+"b"*64)
elif args[0]=="compose" and args[-3:]==["ps","-q","ip"] and os.environ["INITIAL"]!="true": print("old-container")
''')
        for path in binaries.iterdir():
            path.chmod(0o755)
        environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"], FAKE_ROOT=str(root), FAIL_HEALTH=str(fail).lower(), INITIAL=str(initial).lower(), DOCKER_LOG=str(Path(directory) / "docker.log"), RELEASE_ASSETS=str(assets), DOWNLOAD_FAILURE=str(download_failure).lower())
        environment.pop("DOCKER_IMAGE", None)
        config = self.config(mode, directory=str(root), dry=False)
        result = subprocess.run(["bash", "-se", "--", str(root), "v1", "27528", "one-ip", "prod", "registry.example/ipbot:v1", str(incoming), transfer, "deploy-server-v1", checksum], input=remote_script(), text=True, env=environment, capture_output=True)
        self.assertEqual((root / ".env").read_text(), "DB_URL=fixture-only\nAPP_PUBLIC_URL=https://fixture.example\n")
        self.assertFalse(incoming.exists())
        self.assertFalse((root / ".deployment-lock").exists())
        return root, result, Path(directory) / "docker.log"

    def test_pages_success_uploads_dist_without_server_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            root, result, log = self.pages_fixture(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line)['args'] for line in log.read_text().splitlines()]
            self.assertEqual(calls[-1][:5], ['dlx', 'wrangler@4', 'pages', 'deploy', 'dist'])
            self.assertIn('--project-name', calls[-1])
            self.assertIn('ipbot', calls[-1])

    def test_release_download_success_and_health_rollback(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as directory:
                root, result, log = self.fixture(directory, transfer="release", fail=fail, managed=True)
                self.assertEqual(result.returncode == 0, not fail, result.stdout + result.stderr)
                self.assertEqual(os.readlink(root / "web/current"), "releases/old")
                calls = [json.loads(line)["args"] for line in log.read_text().splitlines()]
                self.assertTrue(any(call[:2] == ["load", "--input"] for call in calls))
                self.assertFalse(any(call[0] in ("pull", "create", "cp") for call in calls))
                self.assertEqual(os.readlink(root / "deployments/current"), "old" if fail else "v1")

    def test_release_download_and_checksum_failures_do_not_change_running_version(self):
        for failure in ("corrupt", "bad_manifest", "download_failure"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root, result, log = self.fixture(directory, transfer="release", **{failure: True})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(os.readlink(root / "web/current"), "releases/old")
                self.assertFalse(log.exists())

    def test_pages_upload_failure_preserves_server_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root, result, log = self.pages_fixture(directory, fail=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(os.readlink(root / "deployments/current"), "old")
            self.assertEqual(os.readlink(root / "web/current"), "releases/old")

    def test_server_success_pins_image_and_managed_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root, result, log = self.fixture(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(os.readlink(root / "web/current"), "releases/old")
            self.assertFalse((root / 'web/releases/v1').exists())
            self.assertEqual(os.readlink(root / "deployments/current"), "v1")
            values=(root / "deployments/v1/release.env").read_text()
            self.assertIn("@sha256:" + "a"*64, values)
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


if __name__ == "__main__":
    unittest.main()
