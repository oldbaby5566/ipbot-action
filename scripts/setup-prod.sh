#!/usr/bin/env bash
# Run locally: edit this section, then bash scripts/setup-prod.sh.
# Cloudflare token permissions: Account/Cloudflare Pages/Edit; Zone/Zone/Read,
# Zone/DNS/Edit, Zone/SSL and Certificates/Edit, Zone/Config Rules/Edit.
set +x
set -Eeuo pipefail
umask 077

# ======================== EDIT HERE ========================
ZONE_NAME="ipbot.net"
FRONTEND_DOMAIN="ipbot.net"
API_DOMAIN="api.ipbot.net"
PAGES_PROJECT="ipbot"
PAGES_BRANCH="main"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" # Empty: ask once, without echo.
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}" # Optional: derive from the zone when empty.
SSH_HOST="ipbot"                              # Existing local SSH alias.
REMOTE_SUDO="false"                          # true for a non-root SSH user.
REMOTE_APP_DIR="/opt/one-ip"
API_PORT="27528"
NGINX_CONF="/etc/nginx/conf.d/ipbot-api.conf"
REALIP_CONF="/etc/nginx/cloudflare-realip.conf"
CERT_DIR="/etc/nginx/cert"
ORIGIN_IPV4=""                               # Empty: reuse api.ipbot.net's existing A record.
GITHUB_REPOSITORY="oldbaby5566/ipbot-action"
GITHUB_ENVIRONMENT="one-ip-pages-prod"
# Switch only after Web has a successful production deployment AND the new API is deployed.
SWITCH_FRONTEND_DNS="false"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WEB_ENV_FILE="$SCRIPT_DIR/../../web/.env.production"
# ===========================================================

for command in python3 ssh gh; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
  read -r -s -p 'Cloudflare API Token: ' CLOUDFLARE_API_TOKEN
  printf '\n'
fi
export ZONE_NAME FRONTEND_DOMAIN API_DOMAIN PAGES_PROJECT PAGES_BRANCH CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
export SSH_HOST REMOTE_SUDO REMOTE_APP_DIR API_PORT NGINX_CONF REALIP_CONF CERT_DIR ORIGIN_IPV4
export GITHUB_REPOSITORY GITHUB_ENVIRONMENT SWITCH_FRONTEND_DNS WEB_ENV_FILE

python3 - <<'PY'
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

cfg = {name: os.environ[name] for name in (
    'ZONE_NAME', 'FRONTEND_DOMAIN', 'API_DOMAIN', 'PAGES_PROJECT', 'PAGES_BRANCH',
    'CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID', 'SSH_HOST', 'REMOTE_SUDO', 'REMOTE_APP_DIR', 'API_PORT',
    'NGINX_CONF', 'REALIP_CONF', 'CERT_DIR', 'ORIGIN_IPV4', 'GITHUB_REPOSITORY',
    'GITHUB_ENVIRONMENT', 'SWITCH_FRONTEND_DNS', 'WEB_ENV_FILE')}
token = cfg['CLOUDFLARE_API_TOKEN']
frontend = 'https://' + cfg['FRONTEND_DOMAIN']
api_origin = 'https://' + cfg['API_DOMAIN']


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def cf(method, path, body=None, missing=False):
    request = urllib.request.Request(
        'https://api.cloudflare.com/client/v4' + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
        method=method)
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        if missing and error.code == 404:
            return None
        try:
            details = json.loads(error.read()).get('errors', [])
        except (ValueError, AttributeError):
            details = []
        raise RuntimeError(f'Cloudflare {method} {path}: HTTP {error.code}; {details}') from None
    require(result.get('success') is True, f'Cloudflare {method} {path}: {result.get("errors")}')
    return result['result']


def run(args, body=None):
    process = subprocess.run(args, input=body, text=True, capture_output=True)
    require(process.returncode == 0, process.stderr.strip() or f'Command failed: {args[0]}')
    return process.stdout


def set_env(path, values):
    text = path.read_text()
    for name, value in values.items():
        pattern = re.compile(r'^' + re.escape(name) + r'=.*$', re.M)
        line = name + '=' + value
        text = pattern.sub(lambda _: line, text) if pattern.search(text) else text.rstrip() + '\n' + line + '\n'
    path.write_text(text)


# Only this API vhost/certificate and two .env fields are changed on the server.
REMOTE = r"""
import datetime, json, os, re, shutil, subprocess, sys, tempfile, uuid
from pathlib import Path
p = json.load(sys.stdin)
app = Path(p['app']); target = Path(p['nginx']); realip = Path(p['realip'])
cert = Path(p['cert_dir']) / (p['api'] + '.pem'); key = cert.with_suffix('.key')
env = app / '.env'
def cmd(args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode: raise RuntimeError(result.stderr.strip() or 'Command failed: ' + args[0])
    return result.stdout
def write(path, content, mode, owner=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream: stream.write(content)
        os.chmod(name, mode)
        if owner: os.chown(name, *owner)
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)
try:
    if p['action'] == 'prepare':
        if not env.is_file(): raise RuntimeError('Existing application .env not found: ' + str(env))
        if not realip.is_file(): raise RuntimeError('Existing Cloudflare real-IP include not found: ' + str(realip))
        config = cmd(['nginx', '-T']); source = ''
        for line in config.splitlines():
            if line.startswith('# configuration file '): source = line[21:].rstrip(':')
            if line.strip().startswith('server_name ') and p['api'] in line.rstrip(';').split()[1:]:
                if source != str(target): raise RuntimeError('API vhost already exists in ' + source + '; do not overwrite a shared vhost')
        work = Path(tempfile.mkdtemp(prefix='ipbot-setup-'))
        reusable = cert.is_file() and key.is_file()
        if reusable:
            result = subprocess.run(['openssl', 'x509', '-in', str(cert), '-noout', '-checkend', '2592000', '-checkhost', p['api']], capture_output=True)
            reusable = result.returncode == 0
        csr = None
        if not reusable:
            cmd(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=' + p['api'], '-keyout', str(work / 'origin.key'), '-out', str(work / 'origin.csr')])
            os.chmod(work / 'origin.key', 0o600)
            csr = (work / 'origin.csr').read_text()
        print(json.dumps({'work': str(work), 'csr': csr}))
    else:
        work = Path(p['work'])
        if work.parent != Path(tempfile.gettempdir()) or not work.name.startswith('ipbot-setup-') or work.is_symlink():
            raise RuntimeError('Invalid setup work directory')
        if p['action'] == 'cleanup':
            shutil.rmtree(work, ignore_errors=True)
            print(json.dumps({'cleaned': True}))
        else:
            backup = app / '.setup-backups' / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
            backup.mkdir(parents=True, mode=0o700)
            originals = {}
            for index, path in enumerate((env, target, cert, key)):
                if path.is_symlink(): raise RuntimeError('Refusing to replace symlink: ' + str(path))
                saved = backup / str(index)
                originals[path] = saved if path.exists() else None
                if path.exists(): shutil.copy2(path, saved)
            (backup / 'files.json').write_text(json.dumps({str(k): str(v) if v else None for k,v in originals.items()}))
            try:
                if p.get('certificate'):
                    write(cert, p['certificate'], 0o644)
                    write(key, (work / 'origin.key').read_text(), 0o600)
                config = f'''server {{
    listen 80;
    listen [::]:80;
    server_name {p['api']};
    return 308 https://{p['api']}$request_uri;
}}
server {{
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {p['api']};
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    include {realip};
    location / {{
        proxy_pass http://127.0.0.1:{p['port']};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header CF-Connecting-IP "";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_send_timeout 60s;
        proxy_read_timeout 180s;
        proxy_buffering off;
    }}
}}
'''
                write(target, config, 0o644)
                text = env.read_text()
                for name, value in {'ENV': 'prod', 'APP_PUBLIC_URL': p['frontend']}.items():
                    pattern = re.compile(r'^' + name + r'=.*$', re.M)
                    text = pattern.sub(lambda _: name + '=' + value, text) if pattern.search(text) else text.rstrip() + '\n' + name + '=' + value + '\n'
                old = env.stat()
                write(env, text, old.st_mode & 0o777, (old.st_uid, old.st_gid))
                cmd(['nginx', '-t'])
                cmd(['systemctl', 'reload', 'nginx'])
            except Exception:
                for path, saved in originals.items():
                    if saved: shutil.copy2(saved, path)
                    elif path.exists(): path.unlink()
                subprocess.run(['systemctl', 'reload', 'nginx'], capture_output=True)
                raise
            finally:
                shutil.rmtree(work, ignore_errors=True)
            print(json.dumps({'backup': str(backup)}))
except Exception as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
"""


def remote(action, **values):
    payload = dict(action=action, app=cfg['REMOTE_APP_DIR'], nginx=cfg['NGINX_CONF'],
                   realip=cfg['REALIP_CONF'], cert_dir=cfg['CERT_DIR'], api=cfg['API_DOMAIN'],
                   port=int(cfg['API_PORT']), frontend=frontend, **values)
    command = ('sudo -n ' if cfg['REMOTE_SUDO'] == 'true' else '') + 'python3 -c ' + shlex.quote(REMOTE)
    return json.loads(run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', cfg['SSH_HOST'], command], json.dumps(payload)))


def dns(zone_id, name, kind, content):
    path = f'/zones/{zone_id}/dns_records'
    rows = cf('GET', path + '?' + urllib.parse.urlencode({'name': name, 'per_page': 100}))
    addresses = [r for r in rows if r['type'] in ('A', 'AAAA', 'CNAME')]
    require(len(addresses) <= 1, f'{name} has multiple A/AAAA/CNAME records; resolve the ambiguity first')
    data = dict(type=kind, name=name, content=content, ttl=1, proxied=True)
    if addresses:
        record = addresses[0]
        if record['type'] != kind:
            cf('DELETE', path + '/' + record['id'])
            cf('POST', path, data)
        else:
            cf('PATCH', path + '/' + record['id'], data)
    else:
        cf('POST', path, data)


work = None
try:
    for name in ('ZONE_NAME', 'FRONTEND_DOMAIN', 'API_DOMAIN', 'PAGES_PROJECT'):
        require(re.fullmatch(r'[a-z0-9][a-z0-9.-]*', cfg[name]) is not None, f'Invalid {name}')
    require(cfg['FRONTEND_DOMAIN'] != cfg['API_DOMAIN'], 'Frontend and API domains must be distinct')
    require(cfg['REMOTE_SUDO'] in ('true', 'false') and cfg['SWITCH_FRONTEND_DNS'] in ('true', 'false'), 'Boolean settings must be true or false')
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9@._-]*', cfg['SSH_HOST']) is not None, 'Invalid SSH_HOST')
    require(1 <= int(cfg['API_PORT']) <= 65535, 'Invalid API_PORT')
    require(token, 'Cloudflare API Token is required')
    require(Path(cfg['WEB_ENV_FILE']).is_file(), 'Set WEB_ENV_FILE to the existing Web .env.production')
    # Verify access before changing any resources; secrets never appear in argv/output.
    run(['gh', 'api', f'repos/{cfg["GITHUB_REPOSITORY"]}'])
    zones = cf('GET', '/zones?' + urllib.parse.urlencode({'name': cfg['ZONE_NAME']}))
    require(len(zones) == 1 and zones[0].get('status') == 'active', 'The exact Cloudflare zone must be active and accessible')
    zone = zones[0]; zone_id = zone['id']; account_id = zone['account']['id']
    require(not cfg['CLOUDFLARE_ACCOUNT_ID'] or cfg['CLOUDFLARE_ACCOUNT_ID'] == account_id, 'CLOUDFLARE_ACCOUNT_ID must own this zone')
    api_records = cf('GET', f'/zones/{zone_id}/dns_records?' + urllib.parse.urlencode({'name': cfg['API_DOMAIN'], 'type': 'A'}))
    address = cfg['ORIGIN_IPV4'] or (api_records[0]['content'] if len(api_records) == 1 else '')
    require(address and ipaddress.ip_address(address).version == 4, 'Set ORIGIN_IPV4 or retain exactly one existing API A record')
    project_path = f'/accounts/{account_id}/pages/projects/{cfg["PAGES_PROJECT"]}'
    project = cf('GET', project_path, missing=True)
    if project is None:
        project = cf('POST', f'/accounts/{account_id}/pages/projects', {'name': cfg['PAGES_PROJECT'], 'production_branch': cfg['PAGES_BRANCH']})
    require(not project.get('source'), 'Use a Direct Upload Pages project; this project is connected to Git')
    require(project.get('production_branch') == cfg['PAGES_BRANCH'], 'Existing Pages production branch differs from PAGES_BRANCH')
    if cfg['SWITCH_FRONTEND_DNS'] == 'true':
        deployment = project.get('canonical_deployment') or {}
        stage = deployment.get('latest_stage') or {}
        require(deployment.get('id') and deployment.get('environment') == 'production' and not deployment.get('is_skipped') and stage.get('name') == 'deploy' and stage.get('status') == 'success', 'Publish a successful production Pages deployment before enabling SWITCH_FRONTEND_DNS')
    print('1/5 Pages project ready: ' + cfg['PAGES_PROJECT'], flush=True)

    prepared = remote('prepare'); work = prepared['work']
    certificate = None
    if prepared['csr']:
        certificate = cf('POST', '/certificates', {'csr': prepared['csr'], 'hostnames': [cfg['API_DOMAIN']], 'request_type': 'origin-rsa', 'requested_validity': 5475})['certificate']
    applied = remote('apply', work=work, certificate=certificate); work = None
    print('2/5 API Nginx/.env/certificate configured; server backup: ' + applied['backup'], flush=True)

    # Scope TLS mode to this hostname; preserve all unrelated zone settings/rules.
    entry = f'/zones/{zone_id}/rulesets/phases/http_config_settings/entrypoint'
    ruleset = cf('GET', entry, missing=True)
    rule = {'ref': 'ipbot_api_origin_tls', 'description': 'ipbot API origin TLS', 'expression': f'(http.host eq "{cfg["API_DOMAIN"]}")', 'action': 'set_config', 'action_parameters': {'ssl': 'strict'}, 'enabled': True}
    if ruleset is None:
        cf('POST', f'/zones/{zone_id}/rulesets', {'name': 'ipbot API settings', 'kind': 'zone', 'phase': 'http_config_settings', 'rules': [rule]})
    else:
        rules_path = f'/zones/{zone_id}/rulesets/{ruleset["id"]}/rules'
        existing = [r for r in ruleset.get('rules', []) if r.get('ref') == rule['ref']]
        cf('PATCH', rules_path + '/' + existing[0]['id'], rule) if existing else cf('POST', rules_path, rule)
    dns(zone_id, cfg['API_DOMAIN'], 'A', address)
    print('3/5 API DNS proxy and hostname-specific Full (strict) configured', flush=True)

    env_path = f'repos/{cfg["GITHUB_REPOSITORY"]}/environments/{urllib.parse.quote(cfg["GITHUB_ENVIRONMENT"], safe="")}'
    environment = subprocess.run(['gh', 'api', env_path], text=True, capture_output=True)
    if environment.returncode:
        require('HTTP 404' in environment.stderr, environment.stderr.strip() or 'Cannot read GitHub environment')
        run(['gh', 'api', '--method', 'PUT', env_path])
    common = ['--repo', cfg['GITHUB_REPOSITORY'], '--env', cfg['GITHUB_ENVIRONMENT']]
    for name, value in {'CLOUDFLARE_ACCOUNT_ID': account_id, 'CLOUDFLARE_API_TOKEN': token}.items():
        run(['gh', 'secret', 'set', name, *common], value)
    for name, value in {'CLOUDFLARE_PAGES_PROJECT': cfg['PAGES_PROJECT'], 'CLOUDFLARE_PAGES_BRANCH': cfg['PAGES_BRANCH']}.items():
        run(['gh', 'variable', 'set', name, '--body', value, *common])
    set_env(Path(cfg['WEB_ENV_FILE']), {'VITE_APP_ENV': 'prod', 'VITE_API_BASE_URL': api_origin + '/api'})
    print('4/5 GitHub Pages environment and local production API address configured', flush=True)

    domain_path = project_path + '/domains'
    if cf('GET', domain_path + '/' + cfg['FRONTEND_DOMAIN'], missing=True) is None:
        cf('POST', domain_path, {'name': cfg['FRONTEND_DOMAIN']})
    if cfg['SWITCH_FRONTEND_DNS'] == 'true':
        # Refuse a cutover until the deployed API accepts the production frontend.
        request = urllib.request.Request(api_origin + '/api/sealed', method='OPTIONS', headers={'Origin': frontend, 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'content-type,x-sealed-key'})
        with urllib.request.urlopen(request, timeout=15) as response:
            require(response.headers.get('Access-Control-Allow-Origin') == frontend and response.headers.get('Access-Control-Allow-Credentials') == 'true', 'Deploy the new API with credentialed CORS before switching the main domain')
        dns(zone_id, cfg['FRONTEND_DOMAIN'], 'CNAME', project['subdomain'])
        print('5/5 Frontend DNS switched to Pages; certificate/domain activation may take time', flush=True)
    else:
        print('5/5 Pages domain registered; main-domain DNS retained. After deploying Web/API, set SWITCH_FRONTEND_DNS=true and rerun.', flush=True)
    print('Configuration completed. Application code/images were not deployed and Docker was not restarted.', flush=True)
except Exception as error:
    if work:
        try: remote('cleanup', work=work)
        except Exception: pass
    print('ERROR: ' + str(error).replace(token, '[redacted]') if token else 'ERROR: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY
