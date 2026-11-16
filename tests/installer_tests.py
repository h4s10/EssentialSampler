#!/usr/bin/env python3
"""Exercise installer behavior without changing the user's plugins or AU service."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class InstallerTests(unittest.TestCase):
    def run_installer(self, *, scenario='stale', repair=False, bad_signature=False, bad_identity=False, quarantined=True):
        temp = tempfile.TemporaryDirectory(prefix='hasio-installer-')
        self.addCleanup(temp.cleanup)
        base = Path(temp.name)
        if not quarantined: (base / 'cleared').touch()
        source = base / 'release'
        destination = base / 'Components'
        source.mkdir(); destination.mkdir()
        bundle = (destination if repair else source) / 'Hasio Loop.component'
        (bundle / 'Contents/MacOS').mkdir(parents=True)
        (bundle / 'Contents/MacOS/HasioLoop').write_text('fixture')
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'other.plugin' if bad_identity else 'audio.hasio.loop.au'}))
        commands = base / 'bin'; commands.mkdir()
        log = base / 'commands.log'
        def mock(name, body):
            f = commands / name
            f.write_text('#!/bin/bash\nset -eu\nprintf "%s\\n" "'+name+' $*" >> "$TEST_LOG"\n'+body+'\n')
            f.chmod(0o755)
        mock('codesign', 'exit "${TEST_BAD_SIGNATURE:-0}"')
        mock('xattr', 'if [[ "$1" == -r ]]; then\n  [[ -e "$TEST_BASE/cleared" ]] || echo "com.apple.quarantine: downloaded"\nelse\n  touch "$TEST_BASE/cleared"\nfi')
        mock('killall', 'touch "$TEST_BASE/refreshed"')
        mock('arch', '[[ "$1" == -arm64 ]]; shift; exec "$@"')
        mock('sleep', ':')
        mock('auval', '''if [[ "$1" == -a ]]; then
  if [[ "$TEST_SCENARIO" == missing ]]; then exit 0; fi
  if [[ "$TEST_SCENARIO" == stale && ! -e "$TEST_BASE/refreshed" ]]; then exit 0; fi
  [[ -e "$TEST_BASE/cleared" ]] || exit 0
  echo 'aumu HsLp Hasi - hasio: Hasio Loop'
else
  [[ "$TEST_SCENARIO" != invalid ]] || { echo 'FATAL ERROR: Initialize failed'; exit 1; }
  echo 'AU VALIDATION SUCCEEDED.'
fi''')
        env = dict(os.environ, PATH=str(commands)+':'+os.environ['PATH'], TEST_BASE=str(base), TEST_LOG=str(log),
                   TEST_SCENARIO=scenario, TEST_BAD_SIGNATURE='1' if bad_signature else '0',
                   HASIO_RELEASE_DIR=str(source), HASIO_AU_DIR=str(destination))
        env.pop('HASIO_SKIP_AUVAL', None)
        args = ['bash', str(ROOT/'scripts/install-release.command')]
        if repair: args.append('--repair-au')
        result = subprocess.run(args, env=env, text=True, capture_output=True)
        return result, log.read_text() if log.exists() else '', destination

    def test_stale_registry_recovers_after_quarantine_removal(self):
        result, log, destination = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('xattr -dr com.apple.quarantine', log)
        self.assertIn('killall -u ', log)
        self.assertIn('arch -arm64 auval -v aumu HsLp Hasi', log)
        self.assertTrue((destination/'Hasio Loop.component').exists())
        self.assertLess(log.index('codesign '), log.index('xattr -dr'))

    def test_registered_plugin_does_not_restart_registrar(self):
        result, log, _ = self.run_installer(scenario='registered')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertNotIn('killall ', log)

    def test_missing_plugin_is_not_called_validation_failure(self):
        result, log, _ = self.run_installer(scenario='missing')
        self.assertEqual(result.returncode, 3, result.stdout+result.stderr)
        self.assertIn('not registered', result.stdout)
        self.assertNotIn('auval -v ', log)

    def test_dsp_validation_failure_does_not_trigger_registry_reset(self):
        result, log, _ = self.run_installer(scenario='invalid')
        self.assertEqual(result.returncode, 2, result.stdout+result.stderr)
        self.assertNotIn('killall ', log)
        self.assertIn('registered, but AU validation failed', result.stdout)

    def test_existing_install_can_be_repaired_without_reinstalling(self):
        result, log, _ = self.run_installer(repair=True)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('AU VALIDATION SUCCEEDED', result.stdout)
        self.assertNotIn('Installed:', result.stdout)

    def test_existing_unquarantined_bundle_needs_no_attribute_write(self):
        result, log, _ = self.run_installer(scenario='registered', quarantined=False)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertNotIn('xattr -dr ', log)
        self.assertNotIn('killall ', log)

    def test_unexpected_bundle_identity_is_not_unquarantined(self):
        result, log, _ = self.run_installer(bad_identity=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unexpected bundle identity', result.stdout)
        self.assertNotIn('xattr ', log)
        self.assertNotIn('killall ', log)

    def test_invalid_signature_is_not_unquarantined(self):
        result, log, _ = self.run_installer(bad_signature=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('xattr ', log)
        self.assertNotIn('killall ', log)

if __name__ == '__main__':
    unittest.main()
