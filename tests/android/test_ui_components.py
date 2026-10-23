"""Component-level Android checks driven by the accessibility tree.

These tests never look at pixels. They read Flutter's semantics nodes through
`uiautomator dump` (content-desc/text/bounds) and tap those nodes, so layout
changes do not make them pass or fail by accident.

They need a real device or emulator with the release APK installed and media
already indexed, because they exercise the real native library:

    PHOTO_ANDROID_UI=1 ANDROID_SERIAL=emulator-5554 \
        python3 -B -m unittest discover -s tests/android \
        -p 'test_ui_components.py' -v

Set PHOTO_ANDROID_APK to also verify an over-install relaunch. Without the
opt-in variable the module is skipped, so platform tests stay hermetic.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

PACKAGE = 'com.photoviewer.photo_client'
ACTIVITY = f'{PACKAGE}/.MainActivity'
ENGLISH_SUBTYPE = '1594443099'
MEDIA_SUFFIX = re.compile(r'\.(gif|png|jpe?g|heic|heif|webp|mp4|mov|m4v|webm)$', re.I)
YEAR_HEADER = re.compile(r'^19(?:6|7)\d年$|^19(?:6|7)\d$')
COUNT = re.compile(r'^(\d+)\s*(?:项|items?)$')


def adb_path() -> str:
    explicit = os.environ.get('ANDROID_ADB')
    if explicit:
        return explicit
    for candidate in (
        os.environ.get('ANDROID_SDK_ROOT'),
        os.environ.get('ANDROID_HOME'),
        str(Path.home() / 'Android/Sdk'),
    ):
        if candidate:
            path = Path(candidate) / 'platform-tools/adb'
            if path.is_file():
                return str(path)
    found = shutil.which('adb')
    if not found:
        raise unittest.SkipTest('adb is not available')
    return found


class Component:
    def __init__(self, adb: str, serial: str):
        self.adb = adb
        self.serial = serial
        self.original_subtype: str | None = None

    def shell(self, *args: str, check: bool = True) -> str:
        result = subprocess.run(
            [self.adb, '-s', self.serial, *args],
            capture_output=True,
            text=True,
            timeout=40,
        )
        if check and result.returncode != 0:
            raise AssertionError(
                f'adb {" ".join(args)} failed: {result.stdout}\n{result.stderr}'
            )
        return result.stdout

    def dump(self) -> ET.Element:
        for _ in range(6):
            result = subprocess.run(
                [self.adb, '-s', self.serial, 'shell', 'uiautomator', 'dump',
                 '/sdcard/photo_ui.xml'],
                capture_output=True,
                text=True,
                timeout=40,
            )
            if 'dumped' in (result.stdout + result.stderr).lower():
                xml = subprocess.run(
                    [self.adb, '-s', self.serial, 'exec-out', 'cat',
                     '/sdcard/photo_ui.xml'],
                    capture_output=True,
                    text=True,
                    timeout=40,
                ).stdout
                try:
                    return ET.fromstring(xml)
                except ET.ParseError:
                    pass
            time.sleep(0.4)
        raise AssertionError('uiautomator could not dump the hierarchy')

    @staticmethod
    def descs(root: ET.Element) -> list[str]:
        return [
            node.attrib['content-desc']
            for node in root.iter('node')
            if node.attrib.get('content-desc')
        ]

    @staticmethod
    def nodes(root: ET.Element) -> list[ET.Element]:
        return [
            node
            for node in root.iter('node')
            if node.attrib.get('content-desc') or node.attrib.get('text')
        ]

    @staticmethod
    def center(node: ET.Element) -> tuple[int, int]:
        left, top, right, bottom = map(int, re.findall(r'-?\d+', node.attrib['bounds']))
        return (left + right) // 2, (top + bottom) // 2

    def find(
        self,
        root: ET.Element,
        desc: str | None = None,
        contains: str | None = None,
        pattern: re.Pattern[str] | None = None,
        class_name: str | None = None,
        lowest: bool = False,
    ) -> ET.Element | None:
        found = []
        for node in self.nodes(root):
            value = node.attrib.get('content-desc', '')
            if desc is not None and value != desc:
                continue
            if contains is not None and contains not in value:
                continue
            if pattern is not None and not pattern.search(value):
                continue
            if class_name is not None and node.attrib.get('class') != class_name:
                continue
            found.append(node)
        if not found:
            return None
        return max(found, key=lambda n: self.center(n)[1]) if lowest else found[0]

    def has(self, root: ET.Element, **kwargs) -> bool:
        return self.find(root, **kwargs) is not None

    def wait(
        self,
        predicate,
        timeout: float = 15,
        interval: float = 0.35,
        message: str = 'condition not met',
    ):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            last = self.dump()
            value = predicate(last)
            if value is not None and value is not False:
                return value
            time.sleep(interval)
        raise AssertionError(
            f'{message}; visible descs: {self.descs(last)[:40]}'
            if last is not None
            else message
        )

    def tap(self, node: ET.Element):
        x, y = self.center(node)
        self.shell('shell', 'input', 'tap', str(x), str(y))

    def tap_desc(self, root: ET.Element, desc: str, lowest: bool = False):
        node = self.find(root, desc=desc, lowest=lowest)
        if node is None:
            raise AssertionError(f'no node with desc {desc!r}: {self.descs(root)[:40]}')
        self.tap(node)

    def tap_button(self, desc: str, root: ET.Element | None = None):
        # Context-menu rows keep their semantics while a dialog opens; dialog
        # actions are Buttons, menu rows are plain Views. Prefer the Button so
        # the same label in a stale menu cannot swallow the tap.
        root = root if root is not None else self.dump()
        node = self.find(root, desc=desc, class_name='android.widget.Button')
        if node is None:
            node = self.find(root, desc=desc, lowest=True)
        if node is None:
            raise AssertionError(f'no button {desc!r}: {self.descs(root)[:40]}')
        self.tap(node)

    @staticmethod
    def thumbnail_point(node: ET.Element) -> tuple[int, int]:
        # A grid row exposes the whole row as one semantics node; the touch
        # target is the thumbnail at its leading edge.
        left, top, right, bottom = map(int, re.findall(r'-?\d+', node.attrib['bounds']))
        return left + max(20, (right - left) // 8), (top + bottom) // 2

    def long_press(self, node: ET.Element):
        x, y = self.thumbnail_point(node)
        self.shell('shell', 'input', 'swipe', str(x), str(y), str(x), str(y), '900')

    def swipe(self, x1: int, y1: int, x2: int, y2: int, duration: int = 300):
        self.shell('shell', 'input', 'swipe', str(x1), str(y1), str(x2), str(y2),
                   str(duration))

    def launch(self):
        self.shell('shell', 'am', 'force-stop', PACKAGE)
        time.sleep(0.5)
        self.shell('shell', 'am', 'start', '-n', ACTIVITY)
        self.wait_grid()

    def wait_grid(self, timeout: float = 20) -> ET.Element:
        def ready(root: ET.Element):
            error = self.find(root, contains='照片加载失败')
            if error is not None:
                raise AssertionError(
                    'library failed to load: ' + str(self.descs(root)[:20])
                )
            if self.find(root, desc='照片', lowest=True) is None:
                return None
            return root if COUNT.match(self.count_desc(root) or '') else None

        root = self.wait(ready, timeout=timeout, message='photo grid did not load')
        return root

    def count_desc(self, root: ET.Element) -> str | None:
        for value in self.descs(root):
            if COUNT.match(value):
                return value
        return None

    def count(self, root: ET.Element) -> int:
        match = COUNT.match(self.count_desc(root) or '')
        if not match:
            raise AssertionError(f'no count node: {self.descs(root)[:30]}')
        return int(match.group(1))

    def tiles(self, root: ET.Element) -> list[ET.Element]:
        result = []
        for node in self.nodes(root):
            first = node.attrib.get('content-desc', '').split('\n')[0]
            if MEDIA_SUFFIX.search(first):
                result.append(node)
        return result

    def first_tile(self, root: ET.Element, suffix: str) -> ET.Element | None:
        pattern = re.compile(r'\.' + suffix + r'$', re.I)
        for node in self.tiles(root):
            name = node.attrib['content-desc'].split('\n')[0]
            if pattern.search(name):
                return node
        return None

    def viewer_header(self, root: ET.Element) -> ET.Element | None:
        return self.find(root, pattern=re.compile(r'·\s*\d+\s*/\s*\d+'))

    def open_more(self, root: ET.Element, action: str) -> None:
        self.tap_desc(root, '更多')
        menu = self.wait(lambda r: r if self.has(r, desc=action) else None,
                         message=f'viewer menu missing {action}')
        self.tap_desc(menu, action)

    def scroll_until(self, predicate, max_swipes: int = 8):
        for attempt in range(max_swipes + 1):
            root = self.dump()
            found = predicate(root)
            if found is not None:
                return root, found
            if attempt == max_swipes:
                break
            self.swipe(540, 1600, 540, 800, 450)
            time.sleep(0.5)
        raise AssertionError(f'item not found; visible: {self.descs(root)[:40]}')

    def wait_edit_text(self) -> ET.Element:
        return self.wait(
            lambda r: next((node for node in r.iter('node')
                            if node.attrib.get('class')
                            == 'android.widget.EditText'), None),
            message='text field did not appear',
        )

    def replace_text(self, text: str) -> None:
        field = self.wait_edit_text()
        self.tap(field)
        # Move to the end and clear in one adb call: 80 separate invocations
        # drop the IME connection before the new text is typed.
        self.shell('shell', 'input', 'keyevent', '123', *(['67'] * 80))
        self.shell('shell', 'input', 'text', text)
        time.sleep(0.5)
        actual = self.wait_edit_text().attrib.get('text', '')
        if actual != text:
            raise AssertionError(f'text field holds {actual!r}, expected {text!r}')

    def ensure_ascii_ime(self):
        if self.original_subtype is None:
            self.original_subtype = self.shell(
                'shell', 'settings', 'get', 'secure',
                'selected_input_method_subtype',
            ).strip()
        self.shell('shell', 'settings', 'put', 'secure',
                   'selected_input_method_subtype', ENGLISH_SUBTYPE)
        time.sleep(0.5)

    def restore_ime(self):
        if self.original_subtype is None:
            return
        self.shell('shell', 'settings', 'put', 'secure',
                   'selected_input_method_subtype', self.original_subtype)


class AndroidUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get('PHOTO_ANDROID_UI') != '1':
            raise unittest.SkipTest('set PHOTO_ANDROID_UI=1 to run device UI tests')
        adb = adb_path()
        serial = os.environ.get('ANDROID_SERIAL') or cls.first_device(adb)
        if not serial:
            raise unittest.SkipTest('no adb device is online')
        cls.ui = Component(adb, serial)

    @classmethod
    def first_device(cls, adb: str) -> str | None:
        output = subprocess.run([adb, 'devices'], capture_output=True, text=True,
                                timeout=20).stdout
        for line in output.splitlines()[1:]:
            parts = line.split()
            if len(parts) == 2 and parts[1] == 'device':
                return parts[0]
        return None

    def tearDown(self):
        self.ui.restore_ime()

    def test_grid_renders_indexed_media(self):
        self.ui.launch()
        root = self.ui.wait_grid()
        self.assertGreater(self.ui.count(root), 0)
        self.assertTrue(self.ui.tiles(root), self.ui.descs(root))
        self.assertIsNone(self.ui.find(root, contains='照片加载失败'))

    def test_viewer_swipes_between_media(self):
        self.ui.launch()
        root = self.ui.wait_grid()
        first = self.ui.tiles(root)[0]
        self.ui.tap(first)
        header = self.ui.wait(
            lambda r: self.ui.find(r, pattern=re.compile(r'·\s*\d+\s*/\s*\d+')),
            message='viewer header missing',
        )
        before = re.search(r'(\d+)\s*/\s*(\d+)', header.attrib['content-desc'])
        self.assertIsNotNone(before)
        self.assertIsNotNone(self.ui.find(self.ui.dump(), desc='返回图库'))
        # Swipe in the backdrop above the media so a video's scrubber cannot
        # swallow the gesture.
        self.ui.swipe(810, 600, 270, 600)
        after = self.ui.wait(
            lambda r: (
                node
                if (node := self.ui.find(r, pattern=re.compile(r'·\s*\d+\s*/\s*\d+')))
                is not None
                and node.attrib['content-desc'].split('·')[-1].strip()
                != before.group(0).replace(' ', '')
                else None
            ),
            message='viewer did not advance',
        )
        current = re.search(r'(\d+)\s*/\s*(\d+)', after.attrib['content-desc'])
        self.assertNotEqual(current.group(1), before.group(1))

    def test_favorite_toggle_round_trip(self):
        self.ui.launch()
        root = self.ui.wait_grid()
        self.ui.tap(self.ui.tiles(root)[0])
        self.ui.wait(lambda r: self.ui.find(r, desc='返回图库'))
        root = self.ui.dump()
        favorited = self.ui.find(root, desc='取消收藏') is not None
        self.ui.tap_desc(root, '取消收藏' if favorited else '收藏照片')
        expected = '收藏照片' if favorited else '取消收藏'
        self.ui.wait(lambda r: self.ui.find(r, desc=expected),
                     message='favorite state did not toggle')
        # Leave the library exactly as found.
        self.ui.tap_desc(self.ui.dump(), expected)
        self.ui.wait(lambda r: self.ui.find(
            r, desc='取消收藏' if favorited else '收藏照片'))

    def test_inline_search_uses_media_type_headers(self):
        self.ui.launch()
        root = self.ui.wait_grid()
        self.ui.tap_desc(root, '搜索')
        self.ui.wait(lambda r: self.ui.find(r, desc='全部'),
                     message='search page did not open')
        tile = next(
            (node for node in self.ui.tiles(root)
             if re.fullmatch(r'[A-Za-z0-9._-]+',
                             node.attrib['content-desc'].split('\n')[0])),
            None,
        )
        if tile is None:
            self.skipTest('no ASCII-named media to search for')
        stem = Path(tile.attrib['content-desc'].split('\n')[0]).stem
        query = re.sub(r'[^A-Za-z0-9]', '', stem)[:4]
        self.ui.ensure_ascii_ime()
        root = self.ui.dump()
        field = next(
            (node for node in root.iter('node')
             if node.attrib.get('class') == 'android.widget.EditText'),
            None,
        )
        self.assertIsNotNone(field, 'search field is missing')
        self.ui.tap(field)
        self.ui.shell('shell', 'input', 'text', query)
        result = self.ui.wait(
            lambda r: r if self.ui.has(r, desc='全部') and (
                self.ui.has(r, desc='图片') or self.ui.has(r, desc='视频')
            ) else None,
            message='search results did not settle',
        )
        self.assertEqual(
            [value for value in self.ui.descs(result) if YEAR_HEADER.match(value)],
            [],
            'search results were grouped by an epoch sentinel',
        )
        self.assertGreater(self.ui.count(result), 0)
        self.ui.tap_desc(result, '关闭')
        self.ui.wait_grid()

    def test_trash_and_restore_round_trip(self):
        self.ui.launch()
        root = self.ui.wait_grid()
        before = self.ui.count(root)
        tile = self.ui.tiles(root)[0]
        name = tile.attrib['content-desc'].split('\n')[0]
        self.ui.tap(tile)
        self.ui.wait(lambda r: self.ui.find(r, desc='返回图库'))
        self.ui.tap_desc(self.ui.dump(), '更多')
        menu = self.ui.wait(lambda r: r if self.ui.has(r, desc='移到回收站') else None,
                            message='viewer menu did not open')
        self.ui.tap_desc(menu, '移到回收站')
        dialog = self.ui.wait(
            lambda r: r if any('移到回收站' in value and '？' in value
                               for value in self.ui.descs(r)) else None,
            message='trash confirmation missing',
        )
        self.ui.tap_button('移到回收站')
        self.ui.wait(lambda r: self.ui.find(r, contains='已将 1 项移到回收站'),
                     message='trash confirmation toast missing')
        root = self.ui.dump()
        if self.ui.has(root, desc='返回图库'):
            self.ui.tap_desc(root, '返回图库')
        root = self.ui.wait_grid()
        self.assertEqual(self.ui.count(root), before - 1)

        self.ui.tap_desc(root, '相册', lowest=True)
        albums = self.ui.wait(lambda r: r if self.ui.has(r, contains='回收站，') else None,
                              message='albums page did not open')
        trash_entry = next(
            node for node in self.ui.nodes(albums)
            if node.attrib.get('content-desc', '').startswith('回收站，')
        )
        self.ui.tap(trash_entry)
        trash = self.ui.wait(lambda r: r if self.ui.has(r, desc='返回相册') else None,
                             message='trash page did not open')
        self.assertIsNotNone(self.ui.find(trash, contains=name), name)

        item = self.ui.find(trash, contains=name)
        self.ui.long_press(item)
        menu = self.ui.wait(lambda r: r if self.ui.has(r, desc='恢复') else None,
                            message='trash context menu missing')
        self.ui.tap_desc(menu, '恢复')
        self.ui.wait(lambda r: self.ui.find(r, contains='已恢复 1 项'),
                     message='restore toast missing')
        trash = self.ui.wait(
            lambda r: r if self.ui.has(r, desc='返回相册')
            and not self.ui.has(r, contains=name) else None,
            message='restored photo still in trash',
        )
        self.ui.tap_desc(trash, '返回相册')
        albums = self.ui.wait(lambda r: r if self.ui.has(r, contains='回收站，') else None,
                              message='albums page did not return')
        self.ui.tap_desc(albums, '照片', lowest=True)
        root = self.ui.wait_grid()
        self.assertEqual(self.ui.count(root), before)
        self.assertIsNotNone(self.ui.find(root, contains=name))

    def test_grid_rows_keep_square_tiles_after_fling(self):
        self.ui.launch()
        root = self.ui.wait_grid()
        tiles = self.ui.tiles(root)
        self.assertGreaterEqual(len(tiles), 2)
        first_y = self.ui.center(tiles[0])[1]
        row = [node for node in tiles if self.ui.center(node)[1] == first_y]
        widths = [right - left for left, _, right, _ in
                  (map(int, re.findall(r'-?\d+', n.attrib['bounds'])) for n in row)]
        heights = [bottom - top for _, top, _, bottom in
                   (map(int, re.findall(r'-?\d+', n.attrib['bounds'])) for n in row)]
        self.assertTrue(all(width == widths[0] for width in widths), widths)
        self.assertTrue(
            all(abs(width - height) <= 1 for width, height in zip(widths, heights)),
            list(zip(widths, heights)),
        )
        self.ui.swipe(540, 1800, 540, 500, 120)
        time.sleep(0.8)
        for tile in self.ui.tiles(self.ui.dump()):
            left, top, right, bottom = map(int, re.findall(r'-?\d+', tile.attrib['bounds']))
            self.assertGreater(right - left, 0)
            self.assertGreater(bottom - top, 0)
            self.assertGreaterEqual(left, -1)
            self.assertLessEqual(right, 1081)

    def test_viewer_chrome_and_filmstrip(self):
        self.ui.launch()
        root = self.ui.wait_grid()
        first = next(
            (node for node in self.ui.tiles(root)
             if '视频' not in node.attrib['content-desc']),
            None,
        )
        if first is None:
            self.skipTest('no image to open')
        self.ui.tap(first)
        header = self.ui.wait(lambda r: self.ui.viewer_header(r),
                              message='viewer did not open')
        current = header.attrib['content-desc'].split('\n')[0]
        for absent in ('上一张', '下一张', '放大', '缩小', '沉浸'):
            self.assertIsNone(self.ui.find(self.ui.dump(), desc=absent), absent)
        # Tap the stage to collapse chrome, tap again to restore it. A tap
        # during the stage cross-fade can be swallowed, so let it settle first.
        time.sleep(0.8)
        self.ui.shell('shell', 'input', 'tap', '540', '1140')
        self.ui.wait(lambda r: None if self.ui.has(r, desc='返回图库') else r,
                     message='chrome did not hide')
        self.ui.shell('shell', 'input', 'tap', '540', '1140')
        self.ui.wait(lambda r: r if self.ui.has(r, desc='返回图库') else None,
                     message='chrome did not return')
        # A filmstrip tile for another photo must switch the viewer.
        root = self.ui.dump()
        film = [
            node for node in self.ui.nodes(root)
            if MEDIA_SUFFIX.search(node.attrib.get('content-desc', '').split('\n')[0])
            and node.attrib['content-desc'].split('\n')[0] != current
            and (lambda bounds: bounds[2] - bounds[0] >= 80)(
                list(map(int, re.findall(r'-?\d+', node.attrib['bounds']))))
        ]
        if not film:
            self.skipTest('filmstrip has no alternative visible item')
        target_name = film[0].attrib['content-desc'].split('\n')[0]
        self.ui.tap(film[0])
        self.ui.wait(
            lambda r: (
                (header := self.ui.viewer_header(r)) is not None
                and header.attrib['content-desc'].split('\n')[0] == target_name
            ),
            message='filmstrip tap did not switch media',
        )

    def test_video_scrub_does_not_navigate_and_swipe_after_autohide(self):
        self.ui.launch()
        root = self.ui.wait_grid()
        video = next(
            (node for node in self.ui.tiles(root)
             if '视频' in node.attrib['content-desc']),
            None,
        )
        if video is None:
            self.skipTest('no video in the library')
        name = video.attrib['content-desc'].split('\n')[0]
        x, y = self.ui.thumbnail_point(video)
        self.ui.shell('shell', 'input', 'tap', str(x), str(y))
        self.ui.wait(lambda r: self.ui.viewer_header(r), message='video did not open')
        # Drag the scrubber area: it must not change the current item.
        self.ui.shell('shell', 'input', 'tap', '540', '1140')
        time.sleep(0.5)
        self.ui.swipe(900, 1140, 200, 1140, 500)
        time.sleep(1)
        header = self.ui.viewer_header(self.ui.dump())
        if header is None:
            self.ui.shell('shell', 'input', 'tap', '540', '1140')
            header = self.ui.wait(lambda r: self.ui.viewer_header(r),
                                  message='header missing after scrub')
        self.assertEqual(header.attrib['content-desc'].split('\n')[0], name)
        # After controls auto-hide, a backdrop swipe must navigate again.
        time.sleep(4.5)
        self.ui.swipe(270, 600, 810, 600, 300)
        self.ui.wait(
            lambda r: (
                (header := self.ui.viewer_header(r)) is not None
                and header.attrib['content-desc'].split('\n')[0] != name
            ),
            message='backdrop swipe did not navigate after auto-hide',
        )

    def test_editor_rotate_save_copy_and_purge(self):
        self.ui.launch()
        root = self.ui.wait_grid()
        before = self.ui.count(root)
        source = None
        for suffix in ('png', 'jpe?g', 'heic'):
            source = self.ui.first_tile(root, suffix=suffix)
            if source is not None:
                break
        if source is None:
            self.skipTest('no editable image in the library')
        source_name = source.attrib['content-desc'].split('\n')[0]
        self.ui.tap(source)
        self.ui.wait(lambda r: self.ui.viewer_header(r), message='viewer did not open')
        self.ui.open_more(self.ui.dump(), '编辑')
        self.ui.wait(lambda r: r if self.ui.has(r, desc='另存为副本') else None,
                     message='editor did not open')
        self.ui.tap_desc(self.ui.dump(), '向右旋转')
        time.sleep(0.5)
        self.ui.tap_desc(self.ui.dump(), '另存为副本')
        copied = self.ui.wait(
            lambda r: (
                header
                if (header := self.ui.viewer_header(r)) is not None
                and header.attrib['content-desc'].split('\n')[0] != source_name
                else None
            ),
            message='saved copy did not open',
        )
        copy_name = copied.attrib['content-desc'].split('\n')[0]
        root = self.ui.dump()
        if self.ui.has(root, desc='返回图库'):
            self.ui.tap_desc(root, '返回图库')
        root = self.ui.wait_grid()
        self.assertEqual(self.ui.count(root), before + 1)

        tile = self.ui.find(root, contains=copy_name)
        self.assertIsNotNone(tile, copy_name)
        self.ui.tap(tile)
        self.ui.wait(lambda r: self.ui.viewer_header(r), message='copy did not open')
        self.ui.open_more(self.ui.dump(), '移到回收站')
        dialog = self.ui.wait(
            lambda r: r if any('移到回收站' in value and '？' in value
                               for value in self.ui.descs(r)) else None,
            message='trash confirmation missing',
        )
        self.ui.tap_button('移到回收站')
        self.ui.wait(lambda r: self.ui.has(r, contains='已将 1 项移到回收站'),
                     message='trash toast missing')
        root = self.ui.dump()
        if self.ui.has(root, desc='返回图库'):
            self.ui.tap_desc(root, '返回图库')
        else:
            self.ui.shell('shell', 'input', 'keyevent', '4')
        root = self.ui.wait_grid()

        self.ui.tap_desc(root, '相册', lowest=True)
        albums = self.ui.wait(lambda r: r if self.ui.has(r, contains='回收站，') else None,
                              message='albums page did not open')
        trash_entry = next(
            node for node in self.ui.nodes(albums)
            if node.attrib.get('content-desc', '').startswith('回收站，')
        )
        self.ui.tap(trash_entry)
        trash = self.ui.wait(lambda r: r if self.ui.has(r, desc='返回相册') else None,
                             message='trash page did not open')
        item = self.ui.find(trash, contains=copy_name)
        self.assertIsNotNone(item, copy_name)
        self.ui.long_press(item)
        menu = self.ui.wait(lambda r: r if self.ui.has(r, desc='彻底删除') else None,
                            message='trash menu missing')
        self.ui.tap_desc(menu, '彻底删除')
        confirm = self.ui.wait(
            lambda r: r if any(value.startswith('彻底删除') and '？' in value
                               for value in self.ui.descs(r)) else None,
            message='purge confirmation missing',
        )
        self.ui.tap_button('彻底删除')
        self.ui.wait(lambda r: self.ui.has(r, contains='已彻底删除 1 项'),
                     message='purge toast missing')
        trash = self.ui.wait(
            lambda r: r if self.ui.has(r, desc='返回相册')
            and not self.ui.has(r, contains=copy_name) else None,
            message='purged copy still in trash',
        )
        self.ui.tap_desc(trash, '返回相册')
        albums = self.ui.wait(lambda r: r if self.ui.has(r, contains='回收站，') else None,
                              message='albums page did not return')
        self.ui.tap_desc(albums, '照片', lowest=True)
        root = self.ui.wait_grid()
        self.assertEqual(self.ui.count(root), before)
        self.assertIsNone(self.ui.find(root, contains=copy_name))

    def test_favorite_survives_force_stop(self):
        self.ui.launch()
        root = self.ui.wait_grid()
        before = self.ui.count(root)
        tile = self.ui.tiles(root)[0]
        name = tile.attrib['content-desc'].split('\n')[0]
        self.ui.tap(tile)
        self.ui.wait(lambda r: self.ui.viewer_header(r), message='viewer did not open')
        root = self.ui.dump()
        was_favorited = self.ui.has(root, desc='取消收藏')
        if not was_favorited:
            self.ui.tap_desc(root, '收藏照片')
            self.ui.wait(lambda r: self.ui.has(r, desc='取消收藏'),
                         message='favorite did not turn on')
        self.ui.shell('shell', 'am', 'force-stop', PACKAGE)
        time.sleep(0.5)
        self.ui.shell('shell', 'am', 'start', '-n', ACTIVITY)
        root = self.ui.wait_grid()
        self.assertEqual(self.ui.count(root), before)
        tile = self.ui.find(root, contains=name)
        self.assertIsNotNone(tile, name)
        self.ui.tap(tile)
        self.ui.wait(lambda r: self.ui.viewer_header(r), message='viewer did not reopen')
        self.ui.wait(lambda r: r if self.ui.has(r, desc='取消收藏') else None,
                     message='favorite did not survive force stop')
        # Restore the state observed at the start of the test.
        self.ui.tap_desc(self.ui.dump(), '取消收藏')
        self.ui.wait(lambda r: self.ui.has(r, desc='收藏照片'),
                     message='favorite did not revert')

    def test_album_create_rename_and_remove(self):
        album_dir = '/sdcard/UITestAlbum'
        self.ui.shell('shell', 'rm', '-rf', album_dir, check=False)
        self.ui.shell('shell', 'mkdir', '-p', album_dir)
        try:
            self.ui.launch()
            root = self.ui.wait_grid()
            self.ui.tap_desc(root, '相册', lowest=True)
            albums = self.ui.wait(lambda r: r if self.ui.has(r, contains='回收站，') else None,
                                  message='albums page did not open')
            original = next(
                (value for value in self.ui.descs(albums)
                 if re.match(r'^\d+\s*个相册$', value)),
                None,
            )
            self.assertIsNotNone(original)
            self.ui.tap_desc(albums, '新建相册')
            picker = self.ui.wait(lambda r: r if self.ui.has(r, desc='选择文件夹') else None,
                                  message='folder picker did not open')
            if self.ui.has(picker, desc='主目录'):
                self.ui.tap_desc(picker, '主目录')
                time.sleep(0.5)
            picker, row = self.ui.scroll_until(
                lambda r: self.ui.find(r, desc='UITestAlbum')
                if self.ui.has(r, desc='选择文件夹') else None,
                max_swipes=8,
            )
            # Enter the folder through its trailing button, then choose the
            # current folder. This avoids depending on row-selection state.
            left, top, right, bottom = map(
                int, re.findall(r'-?\d+', row.attrib['bounds'])
            )
            opener = next(
                node for node in picker.iter('node')
                if node.attrib.get('content-desc') == '打开文件夹'
                and (lambda b: top <= (b[1] + b[3]) // 2 <= bottom)(
                    list(map(int, re.findall(r'-?\d+', node.attrib['bounds']))))
            )
            self.ui.tap(opener)
            time.sleep(0.8)
            picker = self.ui.dump()
            self.assertIn('可选择当前文件夹', '\n'.join(self.ui.descs(picker)),
                          self.ui.descs(picker)[:10])
            self.ui.tap_desc(picker, '选择文件夹')
            self.ui.ensure_ascii_ime()
            self.ui.replace_text('UITestAlbum')
            self.ui.tap_button('创建')
            state = self.ui.wait(
                lambda r: r if self.ui.has(r, desc='返回相册')
                or self.ui.has(r, contains='UITestAlbum，') else None,
                message='album was not created',
            )
            if self.ui.has(state, desc='返回相册'):
                self.ui.tap_desc(state, '返回相册')
            albums = self.ui.wait(lambda r: r if self.ui.has(r, contains='UITestAlbum，') else None,
                                  message='created album missing from list')

            tile = self.ui.find(albums, contains='UITestAlbum，')
            self.ui.long_press(tile)
            menu = self.ui.wait(lambda r: r if self.ui.has(r, desc='重命名') else None,
                                message='album menu missing rename')
            self.ui.tap_desc(menu, '重命名')
            self.ui.replace_text('UITestRenamed')
            self.ui.tap_button('重命名')
            albums = self.ui.wait(lambda r: r if self.ui.has(r, contains='UITestRenamed，') else None,
                                  message='album rename failed on device')

            tile = self.ui.find(albums, contains='UITestRenamed，')
            self.ui.long_press(tile)
            menu = self.ui.wait(lambda r: r if self.ui.has(r, desc='从图库移除相册') else None,
                                message='album menu missing remove')
            self.ui.tap_desc(menu, '从图库移除相册')
            confirm = self.ui.wait(
                lambda r: r if any('移除相册' in value and '？' in value
                                   for value in self.ui.descs(r)) else None,
                message='album remove confirmation missing',
            )
            self.ui.tap_button('移除')
            albums = self.ui.wait(
                lambda r: None if self.ui.has(r, contains='UITestRenamed') else r,
                message='album still listed after removal',
            )
            self.assertEqual(
                next((value for value in self.ui.descs(albums)
                      if re.match(r'^\d+\s*个相册$', value)), None),
                original,
            )
        finally:
            self.ui.shell('shell', 'rm', '-rf', album_dir, check=False)

    def test_permission_gate_after_clearing_data(self):
        if os.environ.get('PHOTO_ANDROID_DESTRUCTIVE') != '1':
            self.skipTest('set PHOTO_ANDROID_DESTRUCTIVE=1 to clear app data')
        self.ui.shell('shell', 'pm', 'clear', PACKAGE)
        self.ui.shell('shell', 'appops', 'set', PACKAGE,
                      'MANAGE_EXTERNAL_STORAGE', 'deny', check=False)
        for permission in ('READ_MEDIA_IMAGES', 'READ_MEDIA_VIDEO'):
            self.ui.shell('shell', 'pm', 'revoke', PACKAGE,
                          f'android.permission.{permission}', check=False)
        self.ui.shell('shell', 'am', 'start', '-n', ACTIVITY)
        gate = self.ui.wait(
            lambda r: r if self.ui.has(r, contains='允许访问照片和视频') else None,
            message='permission gate did not appear',
        )
        self.assertIsNotNone(gate)
        self.ui.shell('shell', 'appops', 'set', PACKAGE,
                      'MANAGE_EXTERNAL_STORAGE', 'allow', check=False)
        for permission in ('READ_MEDIA_IMAGES', 'READ_MEDIA_VIDEO'):
            self.ui.shell('shell', 'pm', 'grant', PACKAGE,
                          f'android.permission.{permission}', check=False)
        root = self.ui.dump()
        if self.ui.has(root, desc='重新检查'):
            self.ui.tap_button('重新检查')
        else:
            self.ui.shell('shell', 'am', 'start', '-n', ACTIVITY)
        root = self.ui.wait_grid(timeout=60)
        self.assertGreater(self.ui.count(root), 0)

    def test_activity_recreation_reuses_the_library(self):
        self.ui.launch()
        before = self.ui.count(self.ui.wait_grid())
        # A task closed with Back destroys the activity but keeps the process;
        # the relaunched engine must attach to the still-open native session.
        self.ui.shell('shell', 'input', 'keyevent', '4')
        time.sleep(1)
        self.ui.shell('shell', 'am', 'start', '-n', ACTIVITY)
        root = self.ui.wait_grid(timeout=25)
        self.assertEqual(self.ui.count(root), before)
        self.assertIsNone(self.ui.find(root, contains='照片加载失败'))

    def test_over_install_relaunch_keeps_library_readable(self):
        apk = os.environ.get('PHOTO_ANDROID_APK')
        if not apk or not Path(apk).is_file():
            self.skipTest('PHOTO_ANDROID_APK is not set')
        self.ui.launch()
        before = self.ui.count(self.ui.wait_grid())
        install = subprocess.run(
            [self.ui.adb, '-s', self.ui.serial, 'install', '-r', apk],
            capture_output=True, text=True, timeout=180,
        )
        self.assertEqual(install.returncode, 0, install.stdout + install.stderr)
        # Installing over a running app makes Android relaunch it; an explicit
        # start may add a second engine, which must attach to the same session.
        self.ui.shell('shell', 'am', 'start', '-n', ACTIVITY)
        root = self.ui.wait_grid(timeout=25)
        self.assertEqual(self.ui.count(root), before)
        self.assertIsNone(self.ui.find(root, contains='照片加载失败'))


if __name__ == '__main__':
    unittest.main()
