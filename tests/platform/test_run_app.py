"""Exercise launcher sequencing, argument forwarding and process ownership."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='photo launcher ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / 'project'
        self.caller = self.root / 'caller'
        self.caller.mkdir()
        (self.project / 'tools').mkdir(parents=True)
        (self.project / 'app').mkdir()
        shutil.copy2(ROOT / 'tools/run_app', self.project / 'tools/run_app')
        self.sdk = self.root / 'sdk'
        (self.sdk / 'bin').mkdir(parents=True)
        self.trace = self.root / 'trace.jsonl'
        self.env = dict(os.environ, PHOTO_FLUTTER_ROOT=str(self.sdk),
                        PATH=str(self.sdk / 'bin') + os.pathsep + os.environ['PATH'],
                        LAUNCH_TRACE=str(self.trace), CARGO_TARGET_DIR=str(self.root / 'foreign-target'))
        self.env.pop('LIBRARY_PATH', None)
        self.record = """import json, os, sys
from pathlib import Path
def record(kind):
    with open(os.environ['LAUNCH_TRACE'], 'a') as log:
        log.write(json.dumps({'kind': kind, 'args': sys.argv[1:],
                             'library_path': os.environ.get('LIBRARY_PATH'),
                             'target': os.environ.get('CARGO_TARGET_DIR'),
                             'digest': os.environ.get('PHOTO_PROFILE_DIGEST')}) + '\\n')
"""
        self.executable(self.sdk / 'bin/flutter', self.record + "record('flutter')\n")
        self.executable(self.sdk / 'bin/cargo', self.record + """record('cargo')
target = Path(os.environ['CARGO_TARGET_DIR']) / 'debug/libphoto_bridge.so'
target.parent.mkdir(parents=True, exist_ok=True)
target.touch()
""")
        (self.project / 'tools/prepare_linux_media.py').write_text("""import os, sys
assert sys.argv[1] == 'exec'
env = dict(os.environ, LIBRARY_PATH='prepared-media-link')
os.execvpe(sys.argv[2], sys.argv[2:], env)
""")
        (self.project / 'tools/platform').write_text(self.record + """
root = Path(__file__).resolve().parents[1]
if sys.argv[1] == 'generate':
    target = root / '.build/linux-x86_64/dart-defines.json'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps({'PHOTO_PROFILE_DIGEST': 'test-digest'}))
else:
    record('build')
    sys.exit(int(os.environ.get('BUILD_EXIT', '0')))
""")
        self.bundle = self.project / 'app/build/linux/x64/release/bundle/photo_client'
        self.executable(self.bundle, self.record + "record('application')\n")
        self.android_sdk = self.root / 'android-sdk'
        (self.android_sdk / 'platform-tools').mkdir(parents=True)
        self.executable(self.android_sdk / 'platform-tools/adb', self.record + """
args = sys.argv[1:]
if args[0] == 'devices':
    print('List of devices attached')
    if not os.environ.get('ADB_NO_DEVICES'):
        print('emulator-5554\\tdevice')
elif 'getprop' in args:
    print('1')
record('adb')
""")
        self.android_apk = (self.project / 'app/build/app/outputs/flutter-apk/app-release.apk')
        self.android_apk.parent.mkdir(parents=True, exist_ok=True)
        self.android_apk.write_bytes(b'apk')
        (self.project / 'app/android').mkdir(parents=True, exist_ok=True)
        (self.project / 'app/android/local.properties').write_text(
            f'sdk.dir={self.android_sdk}\n')

    def executable(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!' + sys.executable + '\n' + body)
        path.chmod(0o755)

    def launch(self, *args):
        return subprocess.run(['bash', str(self.project / 'tools/run_app'), *args],
                              cwd=self.caller, env=self.env, capture_output=True,
                              text=True, timeout=15)

    def records(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()]

    def test_release_builds_before_launch_and_forwards_absolute_data_root(self):
        result = self.launch('release', '--build', '--x11', '--data-root', 'isolated photos')
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.records()
        self.assertEqual([e['kind'] for e in events], ['build', 'application'])
        self.assertEqual(events[-1]['args'], ['--data-root=' + str(self.caller / 'isolated photos')])

    def test_failed_build_never_launches_existing_bundle(self):
        self.env['BUILD_EXIT'] = '7'
        result = self.launch('release', '--build', '--x11')
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual([e['kind'] for e in self.records()], ['build'])

    def test_dev_prepares_cargo_and_uses_flutter_entrypoint_arguments(self):
        result = self.launch('dev', '--x11', '--data-root', 'isolated photos')
        self.assertEqual(result.returncode, 0, result.stderr)
        cargo, flutter = self.records()
        self.assertEqual([cargo['kind'], flutter['kind']], ['cargo', 'flutter'])
        self.assertEqual(cargo['library_path'], 'prepared-media-link')
        self.assertEqual(cargo['target'], str(self.project / 'target'))
        self.assertEqual(cargo['digest'], 'test-digest')
        self.assertIn('--dart-entrypoint-args=--data-root=' +
                      str(self.caller / 'isolated photos'), flutter['args'])
        self.assertNotIn('--', flutter['args'])

    def test_headless_dev_reaps_its_display_when_flutter_exits(self):
        self.executable(self.sdk / 'bin/Xvfb', """import os, time
from pathlib import Path
Path(os.environ['LAUNCH_TRACE'] + '.xvfb').write_text(str(os.getpid()))
while True: time.sleep(.1)
""")
        result = self.launch('dev', '--headless')
        self.assertEqual(result.returncode, 0, result.stderr)
        pid = int(Path(str(self.trace) + '.xvfb').read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_invalid_sdk_fails_before_build(self):
        self.env['PHOTO_FLUTTER_ROOT'] = str(self.root / 'missing-sdk')
        result = self.launch('release', '--build')
        self.assertEqual(result.returncode, 2)
        self.assertIn('not executable', result.stderr)
        self.assertFalse(self.trace.exists())

    def test_dev_rejects_unsupported_options_before_build(self):
        for args in [('--background',), ('--data-root', 'with,comma'), ('--data-root',)]:
            with self.subTest(args=args):
                result = self.launch('dev', *args)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(self.trace.exists())

    def test_android_installs_grants_and_launches_on_the_online_device(self):
        self.env.pop('ANDROID_HOME', None)
        self.env.pop('ANDROID_SDK_ROOT', None)
        result = self.launch('android')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [' '.join(e['args']) for e in self.records() if e['kind'] == 'adb']
        self.assertTrue(any(c.endswith(str(self.android_apk)) for c in calls), calls)
        self.assertTrue(any('MANAGE_EXTERNAL_STORAGE allow' in c for c in calls), calls)
        self.assertTrue(any('READ_MEDIA_IMAGES' in c for c in calls), calls)
        self.assertTrue(any('READ_MEDIA_VIDEO' in c for c in calls), calls)
        self.assertTrue(any('am start -n com.photoviewer.photo_client/.MainActivity' in c
                            for c in calls), calls)
        # The path-based library needs a real system grant, never a stub.
        self.assertTrue(any('appops set' in c for c in calls), calls)
        # Installing over a running app makes Android relaunch it by itself, so
        # the package must be stopped before the explicit launch; two engines in
        # one process leave the native runtime refusing to initialize twice.
        stop = next(i for i, c in enumerate(calls) if 'am force-stop' in c)
        start = next(i for i, c in enumerate(calls) if 'am start' in c)
        self.assertLess(stop, start)

    def test_android_rejects_desktop_only_options_before_touching_the_device(self):
        for args in [('--background',), ('--data-root', 'isolated'), ('--x11',),
                     ('--headless',)]:
            with self.subTest(args=args):
                result = self.launch('android', *args)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(self.trace.exists())

    def test_android_accepts_the_headless_emulator_flag(self):
        # The emulator opens a window by default; --no-window is the opt-out.
        result = self.launch('android', '--no-window')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(e['kind'] == 'adb' for e in self.records()))

    def test_android_without_a_device_reports_the_missing_avd_path(self):
        self.env['ADB_NO_DEVICES'] = '1'
        result = self.launch('android', '--no-avd')
        self.assertEqual(result.returncode, 1)
        self.assertIn('no online Android device', result.stderr)
        calls = [' '.join(e['args']) for e in self.records() if e['kind'] == 'adb']
        self.assertFalse(any('install' in c for c in calls), calls)
        self.assertFalse(any('am start' in c for c in calls), calls)
