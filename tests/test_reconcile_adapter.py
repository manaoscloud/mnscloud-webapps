"""Contract tests of scripts/reconcile-runtime-config.py (resource webapps.apps).

Runs against the runtime-kit library named by MNSCLOUD_RUNTIME_KIT_LIB (CI checks out the
stable runtime kit). Host commands (install/deactivate/HTTP checks) are replaced by recorders.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, os.environ.get('MNSCLOUD_RUNTIME_KIT_LIB', '/opt/mnscloud/runtime-kit/lib'))
import env_reconcile  # noqa: E402  (must load before the adapter's own sys.path entry)

SPEC = importlib.util.spec_from_file_location('webapps_reconcile', ROOT / 'scripts/reconcile-runtime-config.py')
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)


class AdapterTests(unittest.TestCase):
    def setUp(self):
        # secure_directory rejects /tmp and other world-writable ancestors.
        self.root = Path(tempfile.mkdtemp(prefix='.webapps-reconcile-', dir=Path.home()))
        os.chmod(self.root, 0o755)
        self.addCleanup(shutil.rmtree, self.root)
        etc = self.root / 'etc'
        (etc / 'apps.d').mkdir(parents=True)
        (self.root / 'state').mkdir(mode=0o700)
        self.env = etc / 'webapps.env'
        self.env.write_text('# runtime\nWEBAPPS_LISTEN_PORT=8080\nWEBAPPS_ENABLED_APPS=phoneweb,pulse\n')
        os.chmod(self.env, 0o640)
        for app in ('phoneweb', 'pulse'):
            (etc / 'apps.d' / f'{app}.env').write_text(f'APP_NAME={app}\n')
        patches = {
            'ENV': str(self.env), 'APPS_DIR': str(etc / 'apps.d'), 'STATE': str(self.root / 'state'),
            'require_matching_runtime': lambda: 'v9.9.9', 'status': lambda: [],
            'enable': self.calls('enable'), 'disable': self.calls('disable'),
            'served': lambda app: app not in self.broken, 'deactivated': lambda app: True,
        }
        self.log, self.broken = [], set()
        for name, value in patches.items():
            original = getattr(adapter, name)
            setattr(adapter, name, value)
            self.addCleanup(setattr, adapter, name, original)

    def calls(self, kind):
        return lambda app: self.log.append((kind, app))

    def plan(self, value, resolution=None):
        return adapter.plan({'WEBAPPS_ENABLED_APPS': value}, resolution)

    def test_inspect_lists_current_and_release_apps(self):
        result = adapter.inspect()
        self.assertEqual(result['current'], {'WEBAPPS_ENABLED_APPS': 'phoneweb,pulse'})
        self.assertIn('customer-portal', result['availableApps'])
        self.assertIsNone(result['baseline'])

    def test_first_change_without_baseline_is_blocked_unless_adopted(self):
        blocked = self.plan('phoneweb,pulse,customer-portal')
        self.assertEqual(blocked['status'], 'blocked')
        self.assertEqual(blocked['conflicts'][0]['reason'], 'no-baseline')
        self.assertIn('WEBAPPS_ENABLED_APPS=phoneweb,pulse\n', self.env.read_text())

    def test_enable_seeds_env_installs_verifies_and_records_baseline(self):
        planned = self.plan('phoneweb,pulse,customer-portal', 'adopt-desired')
        self.assertEqual(planned['status'], 'ready')
        self.assertIn({'op': 'seed_app_env', 'app': 'customer-portal'}, planned['operations'])
        result = adapter.apply(planned['planDigest'])
        self.assertEqual(result['enabled'], ['customer-portal'])
        self.assertIn('WEBAPPS_ENABLED_APPS=phoneweb,pulse,customer-portal\n', self.env.read_text())
        self.assertTrue(self.env.read_text().startswith('# runtime\nWEBAPPS_LISTEN_PORT=8080\n'))
        seeded = Path(adapter.APPS_DIR) / 'customer-portal.env'
        self.assertIn('APP_BASE_PATH=/customer-portal/', seeded.read_text())
        self.assertEqual(self.log, [('enable', 'customer-portal')])
        # Re-applying the same digest is a no-op; the next change needs no adopt-desired.
        self.assertEqual(adapter.apply(planned['planDigest'])['outcome'], 'unchanged')
        disable = self.plan('phoneweb,pulse')
        self.assertEqual(disable['status'], 'ready')
        adapter.apply(disable['planDigest'])
        self.assertEqual(self.log[-1], ('disable', 'customer-portal'))
        self.assertTrue(seeded.exists(), 'disabling keeps the app env file')

    def test_failed_verification_rolls_back_everything(self):
        self.broken.add('customer-portal')
        planned = self.plan('phoneweb,customer-portal', 'adopt-desired')
        with self.assertRaisesRegex(env_reconcile.ReconcileError, '^WEBAPPS_ACTIVATION_ROLLED_BACK$') as raised:
            adapter.apply(planned['planDigest'])
        self.assertEqual(raised.exception.cause, 'WEBAPPS_ENABLE_VERIFY_FAILED')
        self.assertIn('WEBAPPS_ENABLED_APPS=phoneweb,pulse\n', self.env.read_text())
        self.assertFalse((Path(adapter.APPS_DIR) / 'customer-portal.env').exists())
        self.assertEqual(self.log, [('disable', 'pulse'), ('enable', 'customer-portal'),
                                    ('disable', 'customer-portal'), ('enable', 'pulse')])
        with self.assertRaisesRegex(env_reconcile.ReconcileError, '^REPLAN_REQUIRED_AFTER_ROLLBACK$'):
            adapter.apply(planned['planDigest'])

    def test_stale_plan_and_invalid_requests_are_rejected(self):
        planned = self.plan('phoneweb', 'adopt-desired')
        self.env.write_text('WEBAPPS_ENABLED_APPS=phoneweb,pulse,website\n')
        os.chmod(self.env, 0o640)
        with self.assertRaises(env_reconcile.ReconcileError):
            adapter.apply(planned['planDigest'])
        for value, code in (('', 'EMPTY_APP_LIST'), ('Bad App', 'INVALID_APP_LIST'), ('unknown-app', 'UNKNOWN_APP')):
            with self.subTest(value=value), self.assertRaisesRegex(env_reconcile.ReconcileError, f'^{code}$'):
                self.plan(value, 'adopt-desired')
        with self.assertRaisesRegex(env_reconcile.ReconcileError, '^UNKNOWN_MANAGED_FIELD$'):
            adapter.plan({'WEBAPPS_LISTEN_PORT': '9090'}, 'adopt-desired')


class ServedRetryTests(unittest.TestCase):
    def test_http_check_waits_for_the_reload(self):
        root = Path(tempfile.mkdtemp(prefix='.webapps-served-', dir=Path.home()))
        self.addCleanup(shutil.rmtree, root)
        (root / 'apps').mkdir()
        (root / 'apps' / 'demo.conf').write_text('')
        (root / 'current').mkdir()
        (root / 'current' / 'demo').symlink_to(root)
        answers = iter([404, 404, 200])
        patches = {'NGINX_DIR': str(root), 'WEBAPPS_ROOT': str(root), 'app_settings': lambda app: {},
                   'listen_url': lambda: 'http://127.0.0.1:8080', 'http_status': lambda url, host=None: next(answers)}
        for name, value in patches.items():
            original = getattr(adapter, name)
            setattr(adapter, name, value)
            self.addCleanup(setattr, adapter, name, original)
        self.assertTrue(adapter.served('demo', attempts=5, delay=0))
        answers = iter([404] * 3)
        self.assertFalse(adapter.served('demo', attempts=3, delay=0))


if __name__ == '__main__':
    unittest.main()
