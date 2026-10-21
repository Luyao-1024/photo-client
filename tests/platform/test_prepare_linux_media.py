"""Regression checks for runtime-only and bundled HEIF linking."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
import prepare_linux_media as media


class HeifLinkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runtime = self.root / '.tooling/media-runtime'
        for name, value in [('ROOT', self.root), ('RUNTIME', self.runtime)]:
            patcher = patch.object(media, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_runtime_only_host_gets_linker_alias_and_keeps_existing_search_path(self):
        library = self.root / 'system/libheif.so.1'
        library.parent.mkdir()
        library.touch()
        original = {'LIBRARY_PATH': '/existing path', 'OTHER': 'unchanged'}
        with patch.object(media, 'prepare', return_value=None), patch.object(
            media.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 0, stdout=str(library) + '\n',
            ),
        ):
            env, runtime = media.environment(original)
        self.assertIsNone(runtime)
        alias = Path(env['LIBRARY_PATH'].split(os.pathsep)[0]) / 'libheif.so'
        self.assertEqual(alias.resolve(), library)
        self.assertTrue(env['LIBRARY_PATH'].endswith(os.pathsep + '/existing path'))
        self.assertEqual(original, {'LIBRARY_PATH': '/existing path', 'OTHER': 'unchanged'})

    def test_bundled_decoder_takes_priority_and_updates_stale_alias(self):
        library = self.runtime / 'usr/lib64/libheif.so.1'
        library.parent.mkdir(parents=True)
        library.touch()
        directory = self.root / '.tooling/media-link'
        directory.mkdir(parents=True)
        alias = directory / 'libheif.so'
        alias.symlink_to(self.root / 'removed-system-library')
        with patch.object(media.subprocess, 'run') as compiler:
            self.assertEqual(media.prepare_heif_linker(), directory)
            media.prepare_heif_linker()
        compiler.assert_not_called()
        self.assertEqual(alias.resolve(), library)

    def test_missing_runtime_reports_dependency_error(self):
        with patch.object(media.subprocess, 'run', return_value=
                          subprocess.CompletedProcess([], 0, stdout='libheif.so.1\n')):
            with self.assertRaisesRegex(RuntimeError, 'Cannot locate libheif'):
                media.prepare_heif_linker()
        self.assertFalse((self.root / '.tooling/media-link/libheif.so').exists())
