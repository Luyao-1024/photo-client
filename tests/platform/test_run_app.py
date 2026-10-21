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
