"""Real UX journey: shipped UI -> FFI/SQLite -> filesystem effects.

The Dart journey drives every common button through real X11 input and asserts
the immediate UI/database/file result. This module builds the bundle, prepares
isolated fixtures, runs the journey under a dedicated X server, then verifies
the final bytes, trash entries, backups, exported copies and SQLite preferences
independently from Python.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import sys
import time

from local_journey import (
    FIXTURE_IMAGES,
    XvfbDisplay,
    file_facts,
    make_fixtures,
    run_journey,
)
from platform_config import ROOT, ProfileError, canonical_json, load_profile, profile_digest, profile_path

BUILD_TIMEOUT = 1800
JOURNEY_TIMEOUT = 1800
CHECK_ORDER = ("UX-01", "UX-02", "UX-03", "UX-04", "UX-05",
               "UX-06", "UX-07", "UX-08", "UX-09", "UX-10", "UX-11")
CHECK_STEPS = {
    "UX-01": ("ux-empty-library", "ux-open-settings-button",
              "ux-settings-add-folder", "ux-settings-add-files",
              "ux-settings-rescan",
              "ux-settings-remove-file-source-keeps-file",
              "ux-sidebar-media-filters"),
    "UX-02": ("ux-settings-shortcuts", "ux-settings-appearance",
              "ux-settings-grid-controls"),
    "UX-03": ("ux-grid-modes", "ux-search-name-scope", "ux-search-date-scope",
              "ux-search-open-viewer"),
    "UX-04": ("ux-select-all-and-favorite", "ux-favorites-destination",
              "ux-batch-unfavorite"),
    "UX-05": ("ux-create-album", "ux-copy-to-album", "ux-move-to-album",
              "ux-set-album-cover", "ux-rename-album-folder",
              "ux-reorder-albums", "ux-album-navigation"),
    "UX-06": ("ux-grid-rename-photo", "ux-tile-details-dialog",
              "ux-batch-export-no-overwrite"),
    "UX-07": ("ux-trash-one-and-restore", "ux-restore-from-trash",
              "ux-batch-purge", "ux-empty-trash", "ux-viewer-trash-undo"),
    "UX-08": ("ux-viewer-favorite-and-zoom", "ux-viewer-rotate-changes-file",
              "ux-viewer-details-and-rename",
              "ux-viewer-filmstrip-and-arrows", "ux-viewer-immersive",
              "ux-viewer-fullscreen-preview", "ux-keyboard-grid-and-viewer"),
    "UX-09": ("ux-editor-reset-and-close", "ux-editor-discard-protection",
              "ux-editor-save-copy", "ux-editor-overwrite-and-backup"),
    "UX-10": ("ux-remove-source-re-add", "ux-remove-album-keeps-files",
              "ux-remove-source-keeps-originals", "ux-clear-cache-and-logs",
              "ux-final-facts"),
    "UX-11": ("ux-media-kinds-scan", "ux-media-kind-filters",
              "ux-media-kind-video-playback", "ux-media-kind-motion",
              "ux-media-kind-heic-and-gif", "ux-media-kind-remove-source"),
}


def _sha256(path: Path) -> str:
    import hashlib
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _run_logged(command: list[str], *, cwd: Path, log_path: Path, timeout: int,
                env: dict[str, str] | None = None) -> dict:
    started = time.monotonic()
    record = {"command": command, "cwd": str(cwd), "log": log_path.name,
              "timeout_seconds": timeout, "exit_code": None, "timed_out": False}
    with log_path.open("x", encoding="utf-8") as log:
        process = subprocess.Popen(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                                   env=env, start_new_session=True)
        try:
            record["exit_code"] = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            record["timed_out"] = True
            try:
                os.killpg(process.pid, 9)
            except (ProcessLookupError, OSError):
                pass
            try:
                record["exit_code"] = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                record["execution_error"] = "process did not exit after kill"
            log.write(f"\nUX_TIMEOUT after {timeout} seconds\n")
    record["elapsed_seconds"] = round(time.monotonic() - started, 3)
    record["status"] = "PASS" if record["exit_code"] == 0 and not record["timed_out"] else "FAIL"
    return record


def build_environment(root: Path = ROOT) -> dict[str, str]:
    flutter_root = Path(os.environ.get(
        "PHOTO_FLUTTER_ROOT", str(Path.home() / ".local/share/photo-client/flutter")))
    if not (flutter_root / "bin" / "flutter").is_file():
        raise ProfileError("toolchain: set PHOTO_FLUTTER_ROOT to a Flutter SDK")
    environment = os.environ.copy()
    prefixed = [str(flutter_root / "bin"), str(root / ".tooling" / "bin")]
    environment["PHOTO_FLUTTER_ROOT"] = str(flutter_root)
    environment["PATH"] = ":".join(prefixed + [environment.get("PATH", "")])
    return environment


def build_bundle(evidence_dir: Path, root: Path, mode: str) -> tuple[dict, Path]:
    log_path = evidence_dir / "build.log"
    command = [sys.executable, "-B", str(root / "tools/platform"), "build",
               "--profile", "linux-x86_64", "--mode", mode]
    record = _run_logged(command, cwd=root, log_path=log_path, timeout=BUILD_TIMEOUT,
                         env=build_environment(root))
    if record["status"] != "PASS":
        raise ProfileError(f"build failed; see {log_path.name}")
    bundle = root / "app/build/linux/x64" / mode / "bundle"
    executables = sorted(path for path in bundle.iterdir()
                         if path.is_file() and os.access(path, os.X_OK))
    if len(executables) != 1:
        raise ProfileError("build: expected exactly one executable in the bundle")
    return record, executables[0]


def _ffmpeg(*args: str) -> None:
    result = subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    if result.returncode != 0:
        raise ProfileError(f"fixtures: ffmpeg failed: {result.stderr.strip()[:400]}")


def _write_motion_photo(source_video: Path, target: Path) -> None:
    """JPEG body plus an appended MP4 and the GCamera XMP the scanner reads."""
    from PIL import Image

    image = Image.new("RGB", (320, 240))
    pixels = image.load()
    for y in range(240):
        for x in range(320):
            pixels[x, y] = ((x * 3) % 256, (y * 5) % 256, ((x + y) * 2) % 256)
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=88)
    jpeg = buffer.getvalue()
    video = source_video.read_bytes()
    xmp = (
        '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '<rdf:Description rdf:about=""\n'
        ' xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"\n'
        ' GCamera:MicroVideo="1"\n'
        ' GCamera:MicroVideoVersion="1"\n'
        f' GCamera:MicroVideoOffset="{len(video)}"\n'
        ' GCamera:MicroVideoPresentationTimestampUs="1000000"/>\n'
        '</rdf:RDF>\n'
        '</x:xmpmeta>\n'
        '<?xpacket end="w"?>'
    ).encode("utf-8")
    payload = b"http://ns.adobe.com/xap/1.0/\x00" + xmp
    app1 = b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload
    if len(payload) + 2 > 0xFFFF:
        raise ProfileError("fixtures: motion-photo XMP does not fit APP1")
    target.write_bytes(jpeg[:2] + app1 + jpeg[2:] + video)


def _make_media_kinds(fixtures_root: Path) -> Path:
    """Video, motion photo, HEIC and animated GIF for the media-kind journey."""
    try:
        from PIL import Image
    except ModuleNotFoundError as exc:  # pragma: no cover - environment guard
        raise ProfileError("fixtures: Pillow is required for UX fixtures") from exc
    if not shutil.which("ffmpeg"):
        raise ProfileError("fixtures: ffmpeg is required for media-kind fixtures")
    heic_source = ROOT / "tests/fixtures/media/real_phone.heic"
    if not heic_source.is_file():
        raise ProfileError(f"fixtures: missing HEIC fixture {heic_source}")
    directory = fixtures_root / "media-kinds"
    directory.mkdir()
    clip = directory / "clip.mp4"
    _ffmpeg(
        "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24:duration=6",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=6",
        "-c:v", "libopenh264", "-pix_fmt", "yuv420p", "-c:a", "aac",
        "-shortest", str(clip),
    )
    motion_clip = directory / "motion-clip.mp4"
    _ffmpeg(
        "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=24:duration=1",
        "-c:v", "libopenh264", "-pix_fmt", "yuv420p", str(motion_clip),
    )
    _write_motion_photo(motion_clip, directory / "motion.jpg")
    motion_clip.unlink()
    shutil.copy2(heic_source, directory / "still.heic")
    frames = []
    for index, color in enumerate(((220, 40, 40), (40, 90, 220), (30, 190, 90))):
        frame = Image.new("RGB", (160, 120), color)
        for x in range(index * 30, index * 30 + 20):
            for y in range(20):
                frame.putpixel((x, y), (255, 255, 255))
        frames.append(frame)
    frames[0].save(
        directory / "loop.gif", save_all=True, append_images=frames[1:],
        duration=140, loop=0, format="GIF",
    )
    return directory


def make_ux_fixtures(evidence_dir: Path) -> dict:
    """Standard photo fixtures plus the picker's album/export/file targets."""
    try:
        from PIL import Image
    except ModuleNotFoundError as exc:  # pragma: no cover - environment guard
        raise ProfileError("fixtures: Pillow is required for UX fixtures") from exc
    fixtures_root = evidence_dir / "fixtures"
    manifest = make_fixtures(fixtures_root)
    media_dir = _make_media_kinds(fixtures_root)
    ux = evidence_dir / "ux"
    albums = ux / "albums"
    export = ux / "export"
    extra_root = ux / "extra"
    for directory in (albums, export, extra_root, ux / "xdg-data" / "Trash",
                      ux / "data-root"):
        directory.mkdir(parents=True, exist_ok=True)
    extra = extra_root / "extra.png"
    image = Image.new("RGB", (120, 80))
    pixels = image.load()
    for y in range(80):
        for x in range(120):
            pixels[x, y] = ((x * 2) % 256, (y * 3) % 256, (x + y) % 256)
    image.save(extra, format="PNG")
    return {
        **manifest,
        "ux_root": str(ux),
        "photos_dir": str(fixtures_root / "photos"),
        "media_dir": str(media_dir),
        "media_names": sorted(path.name for path in media_dir.iterdir()),
        "albums_dir": str(albums),
        "export_dir": str(export),
        "extra_file": str(extra),
        "xdg_data_home": str(ux / "xdg-data"),
        "data_root": str(ux / "data-root"),
    }


def _step_map(record: dict) -> dict[str, dict]:
    return {step.get("id"): step for step in record.get("steps", [])}


def step_checks(record: dict | None) -> dict[str, dict]:
    """Map journey steps onto the ten UX areas without inflating coverage."""
    steps = _step_map(record or {})
    checks: dict[str, dict] = {}
    for check, required in CHECK_STEPS.items():
        failures = []
        missing = []
        for step_id in required:
            step = steps.get(step_id)
            if step is None:
                missing.append(step_id)
            elif step.get("status") != "PASS":
                failures.append(f"{step_id}: {step.get('detail') or 'failed'}")
        if failures:
            checks[check] = {"status": "FAIL", "reason": "; ".join(failures[:4])}
        elif missing:
            checks[check] = {"status": "NOT RUN",
                             "reason": f"steps did not run: {', '.join(missing[:4])}"}
        else:
            checks[check] = {"status": "PASS",
                             "reason": f"all {len(required)} UI steps passed"}
    return checks


def verify_effects(record: dict, manifest: dict, initial_facts: dict,
                   paths: dict) -> tuple[dict[str, dict], dict]:
    """Independent file/SQLite verification keyed by UX check id."""
    errors: dict[str, list[str]] = defaultdict(list)
    evidence: dict[str, object] = {}

    def fail(check: str, message: str) -> None:
        errors[check].append(message)

    def expect(check: str, condition: bool, message: str) -> None:
        if not condition:
            fail(check, message)

    facts = (record or {}).get("facts") or {}
    ux = facts.get("ux") or {}
    evidence["ux_facts"] = ux

    source = Path(ux.get("source_root", "")) if ux else Path("/nonexistent")
    trips = Path(ux.get("trips_path", "")) if ux else Path("/nonexistent")
    export = Path(ux.get("export_root", "")) if ux else Path("/nonexistent")
    data_root = Path(ux.get("data_root", "")) if ux else Path("/nonexistent")

    scan_folder = ux.get("scan_folder") or {}
    expect("UX-01", scan_folder.get("discovered") == 6,
           f"add folder discovered {scan_folder.get('discovered')} not 6")
    expect("UX-01", (ux.get("scan_files") or {}).get("discovered") == 1,
           "add files did not discover the selected file")
    expect("UX-01", (ux.get("rescan") or {}).get("total") == 7,
           "rescan did not keep seven unique rows")
    expect("UX-01", ux.get("extra_source_removed") is True,
           "the extra file source was not removed")
    expect("UX-01", (Path(manifest["extra_file"]).is_file()),
           "removing a source deleted its original file")

    initial_photo_hashes = {
        name: payload["sha256"]
        for name, payload in initial_facts.items()
        if name.startswith("photos/")
    }
    expect("UX-01",
           _sha256(source / "beta.jpg") == initial_photo_hashes.get("photos/beta.jpg"),
           "the UX journey changed beta.jpg without an explicit edit")
    expect("UX-01",
           _sha256(source / "oriented.jpg") == initial_photo_hashes.get("photos/oriented.jpg"),
           "restoring oriented.jpg did not preserve its bytes")

    expect("UX-02", ux.get("theme") == "dark", "dark theme was not recorded")
    expect("UX-02", ux.get("material") == "liquid_glass", "fixed liquid glass was not recorded")
    expect("UX-02", ux.get("follow_scroll") is True, "background following was not restored")
    blur = ux.get("background_blur")
    expect("UX-02", isinstance(blur, (int, float)) and .5 < blur <= 1,
           "background blur was not adjusted")
    expect("UX-02", ux.get("reduce_motion") is True, "Reduce motion was not recorded")
    day_columns = ux.get("day_columns")
    expect("UX-02", isinstance(day_columns, int) and 3 <= day_columns <= 8,
           f"invalid day column count {day_columns!r}")

    expect("UX-03", (ux.get("search_name") or {}).get("total") == 1,
           "name search did not return exactly one photo")
    expect("UX-03", (ux.get("search_date") or {}).get("total", 0) >= 1,
           "date search returned nothing")
    expect("UX-03", len(ux.get("modes") or {}) == 3,
           "Year/Month/Day modes did not all render")
    search_viewer = ux.get("search_viewer") or {}
    expect("UX-03", search_viewer.get("position") == "1 / 1",
           "the viewer did not honour the single-result search scope")
    expect("UX-03", search_viewer.get("restored_total") == 6,
           "closing the search-scoped viewer did not restore the library")

    expect("UX-04", ux.get("favorite_all") == 6, "batch favorite did not mark six")
    expect("UX-04", ux.get("favorite_all_off") == 0, "batch unfavorite did not clear")

    album_names = ux.get("album_copy_files")
    expect("UX-05", album_names == 6, f"copy-to-album produced {album_names!r} files")
    expect("UX-05", ux.get("album_renamed") == str(trips),
           "album folder was not renamed on disk")
    expect("UX-05", (ux.get("album_order_first") or "").endswith("/Second"),
           "album drag ordering did not persist")
    expect("UX-05", ux.get("album_cover_id") is not None,
           "album cover was not recorded")
    expect("UX-05", (ux.get("album_navigation") or {}).get("album_total") == 7,
           "the album destination did not show the seven album photos")
    trip_files = sorted(path.name for path in trips.iterdir()) if trips.is_dir() else []
    # Six copies survive: the seventh album file was trashed and purged by the
    # empty-trash step before the album itself was removed.
    expect("UX-05", len(trip_files) == 6,
           f"album folder has {len(trip_files)} files after removal, expected 6")
    moved_name = Path(ux.get("album_move_file") or "").name
    expect("UX-05", moved_name in trip_files,
           f"the moved photo {moved_name!r} is missing from the album folder")
    expect("UX-05", ux.get("album_move_id") is not None,
           "the journey did not record the moved photo's id")
    evidence["album_files"] = trip_files

    expect("UX-06", (ux.get("renamed_file") or "").endswith("tiny.png"),
           "grid rename was not recorded")
    expect("UX-06", ux.get("details_path") is not None,
           "the details dialog did not show the real path")
    expect("UX-06", ux.get("export_files") == 24,
           "two exports did not create 24 copies")
    export_names = sorted(path.name for path in export.iterdir()) if export.is_dir() else []
    expect("UX-06", len(export_names) == 24,
           f"export directory has {len(export_names)} files, expected 24")
    expect("UX-06", len(set(export_names)) == 24,
           "export reused a destination name instead of adding a suffix")
    known_hashes = set(initial_photo_hashes.values()) | {_sha256(Path(manifest["extra_file"]))}
    for name in export_names:
        candidate = export / name
        expect("UX-06", candidate.stat().st_size > 0, f"exported {name} is empty")
        expect("UX-06", _sha256(candidate) in known_hashes,
               f"exported {name} does not match any original photo")

    trash_info = ux.get("trash_info") or ""
    expect("UX-07", "[Trash Info]" in trash_info and "Path=" in trash_info,
           ".trashinfo was not observed for a trashed photo")
    expect("UX-07", (ux.get("trash_payload") or "") != "",
           "the system trash payload path was not recorded")
    expect("UX-07", ux.get("restored_oriented") is True, "restore was not recorded")
    expect("UX-07", ux.get("purged_gamma") is True, "permanent deletion failed")
    expect("UX-07", ux.get("empty_trash") is True, "Empty trash failed")
    expect("UX-07", ux.get("viewer_undo") is True, "viewer undo failed")
    expect("UX-07", not (source / "gamma.webp").exists(),
           "purged gamma.webp still exists")

    rotate = ux.get("viewer_rotate") or {}
    before = rotate.get("before") or []
    after = rotate.get("after") or []
    expect("UX-08", len(before) == 2 and len(after) == 2 and before == after[::-1],
           f"rotate did not swap axes: {before!r} -> {after!r}")
    expect("UX-08", ux.get("viewer_renamed", "").endswith("alpha2.png"),
           "viewer rename was not recorded")
    expect("UX-08", ux.get("immersive") is True, "immersive mode was not recorded")
    expect("UX-08", ux.get("fullscreen_preview") is True,
           "fullscreen preview was not recorded")
    initial_offset = ux.get("filmstrip_offset_initial")
    expect("UX-08", isinstance(initial_offset, (int, float)) and
           abs(initial_offset) <= 2.5,
           f"the initial filmstrip thumbnail is off centre: {initial_offset!r}")
    offsets = ux.get("filmstrip_offsets") or {}
    expect("UX-08", bool(offsets) and
           all(isinstance(value, (int, float)) and abs(value) <= 2.5
               for value in offsets.values()),
           f"navigation left the current thumbnail off centre: {offsets!r}")
    keyboard = ux.get("keyboard") or {}
    expect("UX-08", keyboard.get("moved_to") not in (None, keyboard.get("anchor")),
           "arrow keys did not move tile focus")
    expect("UX-08", isinstance(keyboard.get("opened"), str),
           "Enter did not open the focused tile")
    expect("UX-08", keyboard.get("favorite_key") is True and
           keyboard.get("details_key") is True,
           "viewer keyboard shortcuts did not act on the photo")

    edited = ux.get("edited_copy") or {}
    edited_path = Path(edited.get("path", "/nonexistent"))
    expect("UX-09", edited_path.is_file(), "the saved copy is missing")
    if edited_path.is_file():
        try:
            from PIL import Image
            with Image.open(edited_path) as image:
                expect("UX-09", image.width == image.height,
                       f"the 1:1 crop saved {image.width}x{image.height}")
        except Exception as exc:  # pragma: no cover - evidence failure
            fail("UX-09", f"the saved copy could not be decoded: {exc}")
    expect("UX-09", edited.get("original_unchanged") is True,
           "save copy reported a changed original")
    backup = ux.get("overwrite_backup")
    expect("UX-09", bool(backup) and Path(backup).is_file() and Path(backup).stat().st_size > 0,
           "overwrite did not leave a non-empty backup")

    expect("UX-10", ux.get("final_total") == 0,
           f"the final library total is {ux.get('final_total')!r}")
    final_names = set(ux.get("source_files") or [])
    # broken.jpg and notes.txt are fixture debris the scan never indexes; they
    # must survive every source remove like the photos do.
    expected_fixed = {"alpha2.png", "beta.jpg", "oriented.jpg", "tiny.png",
                      "broken.jpg", "notes.txt"}
    edited_names = {name for name in final_names if name.startswith("beta_edited_")}
    expect("UX-10", len(edited_names) == 1,
           f"expected one edited copy in the source, found {sorted(edited_names)}")
    expect("UX-10", final_names == expected_fixed | edited_names,
           f"unexpected source files after cleanup: {sorted(final_names)}")
    expect("UX-10", (source / "alpha2.png").is_file(), "alpha2.png is missing")
    expect("UX-10", not (source / "alpha.png").exists(), "alpha.png was not renamed")
    expect("UX-10", not (source / "small.png").exists(), "small.png was not renamed")
    expect("UX-10", (source / "tiny.png").is_file(), "tiny.png is missing")
    expect("UX-10", not (source / "large.jpg").exists(),
           "moving large.jpg to the album left the source behind")
    expect("UX-10", ux.get("album_removed_files") == 6,
           "removing the album did not keep its six remaining files")
    cache = data_root / "cache"
    cache_files = [path for path in cache.rglob("*") if path.is_file()] if cache.is_dir() else []
    expect("UX-10", cache_files == [], "Clear cache left thumbnail files")
    log = data_root / "logs" / "local.log"
    log_lines = log.read_text(encoding="utf-8").splitlines() if log.is_file() else []
    expect("UX-10", ux.get("logs_before_lines", 0) > 1,
           "the log had no history before Clear logs")
    expect("UX-10", ux.get("logs_after_clear", 99) <= 1,
           "Clear logs kept the previous history")
    marker = ux.get("logs_before_marker") or ""
    if marker:
        expect("UX-10", marker not in log_lines,
               "Clear logs kept a line that predated the clear")

    database = data_root / "library.sqlite"
    expect("UX-10", database.is_file(), "the library database is missing")
    if database.is_file():
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        try:
            preferences = {}
            for key, value in connection.execute("SELECT key,value FROM local_preferences"):
                try:
                    preferences[key] = json.loads(value)
                except ValueError:
                    preferences[key] = value
            expected_preferences = {
                "theme": "dark",
                "backgroundBlur": blur,
                "followScroll": True,
                "locale": "en",
                "reduceMotion": True,
                "dayColumns": day_columns,
                "thumbnailWorkers": 4,
                "logLevel": "debug",
                "order": "date_desc",
            }
            for key, value in expected_preferences.items():
                expect("UX-10", preferences.get(key) == value,
                       f"preference {key} persisted as {preferences.get(key)!r}, "
                       f"expected {value!r}")
            media_count = connection.execute(
                "SELECT media_count FROM libraries").fetchone()[0]
            expect("UX-10", media_count == 0,
                   f"media_count is {media_count} after removing every source")
            disabled = [row[0] for row in connection.execute(
                "SELECT enabled FROM sources")]
            expect("UX-10", bool(disabled) and all(value == 0 for value in disabled),
                   f"sources stayed enabled after removal: {disabled}")
            evidence["preferences"] = preferences
            evidence["media_count"] = media_count
        finally:
            connection.close()

    media_scan = ux.get("media_scan") or {}
    expect("UX-11", media_scan.get("discovered") == 4,
           f"the media source discovered {media_scan.get('discovered')} files")
    media_filter = ux.get("media_filter") or {}
    expect("UX-11", media_filter.get("videos") == 1,
           f"the Videos filter showed {media_filter.get('videos')!r} items")
    expect("UX-11", (media_filter.get("images") or 0) >= 4,
           f"the Images filter showed {media_filter.get('images')!r} items")
    video = ux.get("video_playback") or {}
    expect("UX-11", video.get("playing") is True and video.get("paused") is True
           and video.get("resumed") is True,
           "the video did not play, pause and resume through Space")
    duration = video.get("duration_ms")
    expect("UX-11", isinstance(duration, int) and 1000 <= duration <= 10000,
           f"the video duration metadata is {duration!r}")
    expect("UX-11", bool(video.get("duration_label")),
           "the video tile did not render its duration label")
    motion = ux.get("motion_photo") or {}
    expect("UX-11", motion.get("played") is True and (motion.get("bytes") or 0) > 0,
           "the motion photo clip was not extracted and played")
    heic = ux.get("heic_preview") or {}
    expect("UX-11", (heic.get("width") or 0) > 0 and (heic.get("height") or 0) > 0,
           f"the HEIC preview did not decode: {heic!r}")
    expect("UX-11", ux.get("gif_animated") is True,
           "the animated GIF was not flagged as animated")
    expect("UX-11", ux.get("media_source_removed") is True,
           "the media source was not removed")
    media_dir = Path(manifest["media_dir"])
    expect("UX-11", sorted(ux.get("media_files") or []) == manifest["media_names"],
           f"removing the media source changed its files: {ux.get('media_files')!r}")
    for name in manifest["media_names"]:
        path = media_dir / name
        key = f"media-kinds/{name}"
        expected = (initial_facts.get(key) or {}).get("sha256")
        expect("UX-11", path.is_file() and _sha256(path) == expected,
               f"the media fixture {name} was altered or deleted")
    evidence["media_files"] = sorted(
        path.name for path in media_dir.iterdir()) if media_dir.is_dir() else []

    checks = {}
    for check in CHECK_ORDER:
        reasons = errors.get(check, [])
        checks[check] = ({
            "status": "FAIL",
            "reason": "; ".join(reasons[:5]),
        } if reasons else {
            "status": "PASS",
            "reason": "UI steps and real file/database effects agree",
        })
    return checks, evidence


def run(evidence_dir: Path, root: Path = ROOT, *, mode: str = "debug",
        skip_build: bool = False) -> int:
    evidence_dir = evidence_dir.resolve()
    evidence_dir.mkdir(parents=True, exist_ok=True)
    if any(evidence_dir.iterdir()):
        raise ProfileError("ux evidence: directory already exists with files; "
                           "choose a fresh directory")
    profile = load_profile(profile_path("linux-x86_64", root))
    report: dict = {
        "stage": "UX",
        "plan_version": 2,
        "phase": "local-ux",
        "mode": mode,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.gmtime()),
        "profile_digest": profile_digest(profile),
        "commands": [],
        "checks": {},
        "journey": None,
        "evidence": {},
        "user_review": "NOT RECORDED",
        "gpu_visual_validation": "NOT RUN",
    }
    try:
        if not skip_build:
            build, executable = build_bundle(evidence_dir, root, mode)
            report["commands"].append(build)
            report["executable"] = str(executable)
        else:
            bundle = root / "app/build/linux/x64" / mode / "bundle"
            executables = sorted(path for path in bundle.iterdir()
                                 if path.is_file() and os.access(path, os.X_OK))
            if len(executables) != 1:
                raise ProfileError("ux: expected exactly one executable in the bundle")
            executable = executables[0]
            report["executable"] = str(executable)
        manifest = make_ux_fixtures(evidence_dir)
        initial_facts = file_facts(evidence_dir / "fixtures")
        paths = {"data_root": Path(manifest["data_root"]),
                 "xdg_data_home": Path(manifest["xdg_data_home"])}
        report["fixtures"] = manifest
        report["source_facts_before"] = initial_facts
        with XvfbDisplay() as display:
            report["display"] = display
            run_result = run_journey(
                executable,
                display=display,
                phase="ux",
                data_root=Path(manifest["data_root"]),
                evidence_dir=evidence_dir,
                log_name="journey-ux.log",
                timeout=JOURNEY_TIMEOUT,
                args=[f"--source={manifest['photos_dir']}",
                      "--window-size=1440x900"],
                env_extra={"XDG_DATA_HOME": manifest["xdg_data_home"]},
            )
        report["journey"] = run_result.as_evidence(root)
        record = run_result.record
        if record is None:
            raise ProfileError(f"ux: no journey record ({run_result.error or 'no log'})")
        if run_result.exit_code != 0 or record.get("result") != "PASS":
            details = record.get("failure") or run_result.error or f"exit {run_result.exit_code}"
            failed = [step.get("id") for step in record.get("steps", [])
                      if step.get("status") != "PASS"]
            raise ProfileError(f"ux journey failed: {details}; steps: {failed}")
        source_after = file_facts(evidence_dir / "fixtures")
        report["source_facts_after"] = source_after
        checks = step_checks(record)
        effects, evidence = verify_effects(record, manifest, initial_facts, paths)
        report["evidence"] = evidence
        for check in CHECK_ORDER:
            step = checks[check]
            effect = effects[check]
            if step["status"] == "PASS" and effect["status"] == "PASS":
                report["checks"][check] = step
            elif step["status"] == "FAIL" or effect["status"] == "FAIL":
                report["checks"][check] = {
                    "status": "FAIL",
                    "reason": "; ".join(filter(None, [
                        step["reason"] if step["status"] == "FAIL" else "",
                        effect["reason"] if effect["status"] == "FAIL" else "",
                    ])),
                }
            else:
                report["checks"][check] = step
        statuses = {check["status"] for check in report["checks"].values()}
        gate = "PASS" if statuses == {"PASS"} else "FAIL" if "FAIL" in statuses else "INCOMPLETE"
        report["gate_status"] = gate
        report["gui_validation"] = "PASS" if gate == "PASS" else gate
        (evidence_dir / "report.json").write_text(canonical_json(report) + "\n",
                                                  encoding="utf-8")
        print(f"UX {gate}: {evidence_dir / 'report.json'}")
        for check in CHECK_ORDER:
            entry = report["checks"][check]
            print(f"  {check}: {entry['status']} - {entry['reason'][:160]}")
        return 0 if gate == "PASS" else 1
    except (ProfileError, OSError, sqlite3.Error) as exc:
        report["gate_status"] = "FAIL"
        report["error"] = str(exc)
        report.setdefault("checks", {})
        for check in CHECK_ORDER:
            report["checks"].setdefault(check, {"status": "NOT RUN", "reason": str(exc)})
        (evidence_dir / "report.json").write_text(canonical_json(report) + "\n",
                                                  encoding="utf-8")
        print(f"UX FAIL: {exc}", file=sys.stderr)
        return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("run")
    command.add_argument("--evidence-dir", type=Path, required=True)
    command.add_argument("--mode", choices=("debug", "release"), default="debug")
    command.add_argument("--skip-build", action="store_true")
    options = parser.parse_args(argv)
    try:
        return run(options.evidence_dir, mode=options.mode,
                   skip_build=options.skip_build)
    except ProfileError as exc:
        print(f"ux: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
