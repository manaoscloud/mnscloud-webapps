#!/usr/bin/env python3
"""Agent-owned non-secret WebApps reconciliation: which apps this runtime serves.

Resource `webapps.apps` manages WEBAPPS_ENABLED_APPS in /etc/mnscloud/webapps/webapps.env.

  inspect  enabled apps, apps this release can enable, installed releases, last baseline
  plan     three-way compare (baseline, current file, desired) and record a digest-bound plan;
           conflicts block the plan unless the job resolution is `adopt-desired`
  apply    write the env, add missing apps.d/<app>.env from this release's examples, install
           newly enabled apps and deactivate removed ones through the installed runtime scripts,
           verify every app over HTTP and roll everything back when verification fails

The installed runtime (/opt/mnscloud/mnscloud-webapps) must be at the same release tag as this
adapter, so the scripts it runs are the reviewed release. Paths and commands are fixed here; the
Agent job only selects the stage, the desired list and the plan digest.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, '/opt/mnscloud/runtime-kit/lib')
from env_reconcile import EnvJournal, ReconcileError, Rule, atomic_write, read_file, secure_directory

ENV = '/etc/mnscloud/webapps/webapps.env'
APPS_DIR = '/etc/mnscloud/webapps/apps.d'
NGINX_DIR = '/etc/mnscloud/webapps/nginx'
WEBAPPS_ROOT = '/opt/mnscloud/webapps'
RUNTIME = '/opt/mnscloud/mnscloud-webapps'
STATE = '/var/lib/mnscloud/runtime-reconcile/mnscloud-webapps'
RESOURCE = 'webapps.apps'
FIELD = 'WEBAPPS_ENABLED_APPS'
RULES = (Rule(FIELD, 'managed'),)
APP = re.compile(r'[a-z0-9][a-z0-9_-]{0,62}\Z')
MAX_APPS = 30
RELEASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def parse_list(value):
    apps = [item.strip() for item in value.split(',') if item.strip()] if value else []
    if len(apps) > MAX_APPS or any(not APP.fullmatch(app) for app in apps):
        raise ReconcileError('INVALID_APP_LIST')
    return list(dict.fromkeys(apps))


def env_values(source):
    """Literal KEY=value pairs of the runtime env (the library validates the managed field)."""
    values = {}
    for line in source.decode().splitlines():
        match = re.fullmatch(r'\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*', line)
        if match:
            value = match[2]
            if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
                value = value[1:-1]
            values[match[1]] = value
    return values


def read_env():
    with secure_directory(os.path.dirname(ENV)) as directory:
        source, _ = read_file(directory, os.path.basename(ENV))
    return source


def current_apps(source=None):
    return parse_list(env_values(source or read_env()).get(FIELD, ''))


def command(args, timeout=60, error='WEBAPPS_COMMAND_FAILED'):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        raise ReconcileError(error) from None
    if result.returncode:
        raise ReconcileError(error)
    return result.stdout.strip()


def release_tag(path):
    try:
        return command(['git', '-C', path, 'describe', '--tags', '--exact-match', 'HEAD'], error='RELEASE_TAG_UNKNOWN')
    except ReconcileError:
        return None


def require_matching_runtime():
    adapter, installed = release_tag(RELEASE), release_tag(RUNTIME)
    if not adapter or adapter != installed:
        # Run the runtime.update of mnscloud-webapps to this release first.
        raise ReconcileError('RUNTIME_RELEASE_MISMATCH')
    for script in ('update-webapps.sh', 'deactivate-webapp.sh', 'status-webapps.sh'):
        if not os.access(os.path.join(RUNTIME, 'scripts', script), os.X_OK):
            raise ReconcileError('RUNTIME_SCRIPT_MISSING')
    return adapter


def available_apps():
    """Apps with an env file on the host or an example in this release."""
    names = set()
    examples = os.path.join(RELEASE, 'config', 'apps.d')
    for directory, suffix in ((examples, '.env.example'), (APPS_DIR, '.env')):
        if os.path.isdir(directory):
            names.update(name[:-len(suffix)] for name in os.listdir(directory) if name.endswith(suffix))
    return sorted(name for name in names if APP.fullmatch(name))


def status():
    try:
        output = command([os.path.join(RUNTIME, 'scripts', 'status-webapps.sh'), '--json', '--env', ENV], timeout=60)
        rows = json.loads(output)
    except (ReconcileError, ValueError):
        return []
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def app_settings(app):
    path = os.path.join(APPS_DIR, app + '.env')
    try:
        with open(path, 'rb') as stream:
            return env_values(stream.read())
    except OSError:
        return {}


def listen_url():
    values = env_values(read_env())
    host = values.get('WEBAPPS_LISTEN_HOST') or '127.0.0.1'
    port = values.get('WEBAPPS_LISTEN_PORT') or '8080'
    if not re.fullmatch(r'[0-9a-zA-Z.:-]{1,64}', host) or not re.fullmatch(r'\d{1,5}', port):
        raise ReconcileError('INVALID_LISTEN_ADDRESS')
    return 'http://%s:%s' % (host, port)


def http_status(url, host=None):
    request = urllib.request.Request(url, headers={'Host': host} if host else {})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except (urllib.error.URLError, OSError):
        return None


def served(app):
    """The app has nginx configuration, an active release and answers over HTTP."""
    settings = app_settings(app)
    base = settings.get('APP_BASE_PATH') or '/%s/' % app
    server_name = (settings.get('APP_SERVER_NAME') or '').split()
    conf = os.path.join(NGINX_DIR, 'servers' if server_name else 'apps', app + '.conf')
    if not os.path.isfile(conf) or not os.path.islink(os.path.join(WEBAPPS_ROOT, 'current', app)):
        return False
    path = '/' if server_name else base
    return http_status(listen_url() + path, server_name[0] if server_name else None) == 200


def deactivated(app):
    return not any(os.path.exists(path) for path in (
        os.path.join(NGINX_DIR, 'apps', app + '.conf'),
        os.path.join(NGINX_DIR, 'servers', app + '.conf'),
    )) and not os.path.lexists(os.path.join(WEBAPPS_ROOT, 'current', app))


def prepare_state():
    parent = '/var/lib/mnscloud'
    for part in ('runtime-reconcile', 'mnscloud-webapps'):
        with secure_directory(parent) as directory:
            try:
                os.mkdir(part, 0o700, dir_fd=directory)
                os.fsync(directory)
            except FileExistsError:
                pass
        parent += '/' + part
        with secure_directory(parent, private=True):
            pass


@contextlib.contextmanager
def operation_lock():
    with secure_directory(STATE, private=True) as directory:
        fd = os.open('activation.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or info.st_mode & 0o077:
                raise ReconcileError('UNSAFE_LOCK')
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)


def load_private(name):
    with secure_directory(STATE, private=True) as directory:
        try:
            raw, _ = read_file(directory, name)
        except FileNotFoundError:
            return None
    return json.loads(raw)


def save_private(name, record):
    with secure_directory(STATE, private=True) as directory:
        atomic_write(directory, name, canonical(record), 0o600, os.geteuid(), os.getegid())


def seed_env(app):
    """Adds apps.d/<app>.env from this release's example; returns True when it created the file."""
    target = os.path.join(APPS_DIR, app + '.env')
    if os.path.lexists(target):
        return False
    example = os.path.join(RELEASE, 'config', 'apps.d', app + '.env.example')
    with open(example, 'rb') as stream:
        data = stream.read()
    os.makedirs(APPS_DIR, mode=0o755, exist_ok=True)
    with secure_directory(APPS_DIR) as directory:
        atomic_write(directory, app + '.env', data, 0o640, os.geteuid(), os.getegid())
    return True


def enable(app):
    command([os.path.join(RUNTIME, 'scripts', 'update-webapps.sh'), '--env', ENV, '--app', app],
            timeout=900, error='WEBAPPS_ENABLE_FAILED')


def disable(app):
    command([os.path.join(RUNTIME, 'scripts', 'deactivate-webapp.sh'), '--env', ENV, '--app', app],
            timeout=300, error='WEBAPPS_DISABLE_FAILED')


def inspect():
    source = read_env()
    apps = current_apps(source)
    baseline = load_private('baseline.json')
    return {
        'status': 'success',
        'current': {FIELD: ','.join(apps)},
        'baseline': baseline.get('fields') if isinstance(baseline, dict) else None,
        'availableApps': available_apps(),
        'release': release_tag(RELEASE),
        'installedRelease': release_tag(RUNTIME),
        'apps': [{key: row.get(key) for key in ('app', 'basePath', 'installedVersion', 'lastSyncStatus')}
                 for row in status()],
    }


def plan(desired, resolution):
    if not isinstance(desired, dict) or set(desired) != {FIELD}:
        raise ReconcileError('UNKNOWN_MANAGED_FIELD')
    wanted = parse_list(desired[FIELD])
    if not wanted:
        raise ReconcileError('EMPTY_APP_LIST')
    unknown = [app for app in wanted if app not in available_apps()]
    if unknown:
        raise ReconcileError('UNKNOWN_APP')
    release = require_matching_runtime()
    current = current_apps()
    baseline = load_private('baseline.json')
    base = (baseline or {}).get('fields', {}).get(FIELD) if isinstance(baseline, dict) else None
    current_value, wanted_value = ','.join(current), ','.join(wanted)
    conflicts = []
    if current_value != wanted_value and (base is None or base != current_value) and resolution != 'adopt-desired':
        conflicts.append({'field': FIELD, 'current': current_value, 'baseline': base, 'desired': wanted_value,
                          'reason': 'no-baseline' if base is None else 'local-drift'})
    enabled = [app for app in wanted if app not in current]
    disabled = [app for app in current if app not in wanted]
    seed = [app for app in enabled if not os.path.lexists(os.path.join(APPS_DIR, app + '.env'))]
    operations = ([{'op': 'enable_app', 'app': app} for app in enabled] +
                  [{'op': 'disable_app', 'app': app} for app in disabled] +
                  [{'op': 'seed_app_env', 'app': app} for app in seed])
    identity = {'version': 1, 'resource': RESOURCE, 'release': release, 'before': current_value,
                'after': wanted_value, 'enable': enabled, 'disable': disabled, 'seed': seed}
    if conflicts:
        identity['operationUUID'] = None
        status_value = 'blocked'
    elif current_value == wanted_value:
        identity['operationUUID'] = None
        status_value = 'unchanged'
    else:
        operation = str(uuid.uuid4())
        EnvJournal(ENV, STATE, RULES).stage(operation, {FIELD: wanted_value}, {FIELD: current_value})
        identity['operationUUID'] = operation
        status_value = 'ready'
    digest = hashlib.sha256(canonical(identity)).hexdigest()
    save_private(digest + '.plan.json', {'identity': identity, 'activation': 'pending'})
    return {'status': status_value, 'planDigest': digest, 'changed': status_value == 'ready',
            'operations': operations, 'conflicts': conflicts,
            'current': {FIELD: current_value}, 'desired': {FIELD: wanted_value}}


def verify(enabled, disabled):
    for app in enabled:
        if not served(app):
            raise ReconcileError('WEBAPPS_ENABLE_VERIFY_FAILED')
    for app in disabled:
        if not deactivated(app):
            raise ReconcileError('WEBAPPS_DISABLE_VERIFY_FAILED')


def rollback(adapter, identity, seeded):
    with adapter.locked() as (target, journal):
        raw, _ = read_file(journal, adapter.name(identity['operationUUID']))
        staged = json.loads(raw)
        source, info = read_file(target, os.path.basename(ENV))
        if source not in (staged['before'].encode(), staged['after'].encode()):
            raise ReconcileError('ROLLBACK_CONCURRENT_EDIT')
        atomic_write(target, os.path.basename(ENV), staged['before'].encode(), stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
    for app in identity['enable']:
        with contextlib.suppress(ReconcileError):
            disable(app)
    for app in seeded:
        with contextlib.suppress(OSError):
            os.unlink(os.path.join(APPS_DIR, app + '.env'))
    for app in identity['disable']:
        enable(app)
    verify(identity['disable'], identity['enable'])


def apply(digest):
    if not re.fullmatch(r'[a-f0-9]{64}', digest or ''):
        raise ReconcileError('INVALID_APPLY_DIGEST')
    record = load_private(digest + '.plan.json')
    if not record:
        raise ReconcileError('PLAN_NOT_FOUND')
    identity = record['identity']
    if hashlib.sha256(canonical(identity)).hexdigest() != digest or identity['resource'] != RESOURCE:
        raise ReconcileError('PLAN_MISMATCH')
    if record['activation'] == 'rolled_back':
        raise ReconcileError('REPLAN_REQUIRED_AFTER_ROLLBACK')
    if record['activation'] == 'verified':
        return {'status': 'success', 'outcome': 'unchanged', 'planDigest': digest, 'activation': 'verified'}
    if identity['operationUUID'] is None:
        if ','.join(current_apps()) != identity['after']:
            raise ReconcileError('STALE_PLAN')
        return {'status': 'success', 'outcome': 'unchanged', 'planDigest': digest, 'activation': 'not-required'}
    if require_matching_runtime() != identity['release']:
        raise ReconcileError('RUNTIME_RELEASE_MISMATCH')
    adapter = EnvJournal(ENV, STATE, RULES)
    seeded = []
    try:
        for app in identity['seed']:
            if seed_env(app):
                seeded.append(app)
        result = adapter.apply(identity['operationUUID'])
        for app in identity['disable']:
            disable(app)
        for app in identity['enable']:
            enable(app)
        verify(identity['enable'], identity['disable'])
    except Exception:
        record['activation'] = 'rolled_back'
        save_private(digest + '.plan.json', record)
        rollback(adapter, identity, seeded)
        raise ReconcileError('WEBAPPS_ACTIVATION_ROLLED_BACK') from None
    record['activation'] = 'verified'
    save_private(digest + '.plan.json', record)
    save_private('baseline.json', {'fields': {FIELD: identity['after']}})
    return {'status': 'success', 'outcome': 'applied', 'planDigest': digest, 'changed': result['changed'],
            'activation': 'verified', 'enabled': identity['enable'], 'disabled': identity['disable'],
            'apps': [{key: row.get(key) for key in ('app', 'basePath', 'installedVersion', 'lastSyncStatus')}
                     for row in status()]}


def execute(stage, desired=None, digest=None, resolution=None):
    with operation_lock():
        if stage == 'inspect':
            return inspect()
        if stage == 'plan':
            return plan(desired, resolution)
        return apply(digest)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stage', choices=['inspect', 'plan', 'apply'], required=True)
    parser.add_argument('--resource', required=True)
    parser.add_argument('--env', required=True)
    parser.add_argument('--result-json', required=True)
    parser.add_argument('--desired-json')
    parser.add_argument('--plan-digest')
    parser.add_argument('--resolution', choices=['adopt-desired'])
    args = parser.parse_args()
    try:
        if os.geteuid() != 0 or args.env != ENV or args.resource != RESOURCE:
            raise ReconcileError('UNSUPPORTED_LOCAL_TARGET')
        prepare_state()
        desired = None
        if args.stage == 'plan':
            with open(args.desired_json, encoding='utf8') as stream:
                desired = json.load(stream)
        result = {'ok': True, 'stage': args.stage, 'resource': RESOURCE,
                  **execute(args.stage, desired, args.plan_digest, args.resolution)}
        code = 0
    except ReconcileError as error:
        result, code = {'ok': False, 'errorCode': str(error), 'message': str(error)}, 1
    except Exception:
        result, code = {'ok': False, 'errorCode': 'WEBAPPS_RECONCILE_FAILED', 'message': 'WebApps reconciliation failed.'}, 1
    # This file is selected by the Agent executor, never by an API job payload.
    fd = os.open(args.result_json, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(result, stream)
    print(json.dumps(result))
    return code


if __name__ == '__main__':
    sys.exit(main())
