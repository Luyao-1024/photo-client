"""Fixture, mapping and independent-effect contracts for the UX journey."""
from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import ux_journey
from local_journey import FIXTURE_IMAGES, file_facts
from platform_config import ProfileError


class UxFixtureTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="photo-ux-fixture-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)

    def test_fixtures_add_picker_targets_without_touching_user_data(self):
        manifest = ux_journey.make_ux_fixtures(self.root / "evidence")
        photos = Path(manifest["photos_dir"])
        self.assertEqual(manifest["expected_images"], len(FIXTURE_IMAGES))
        self.assertTrue((photos / "alpha.png").is_file())
        self.assertTrue(Path(manifest["extra_file"]).is_file())
        self.assertTrue(Path(manifest["albums_dir"]).is_dir())
        self.assertTrue(Path(manifest["export_dir"]).is_dir())
        self.assertTrue(Path(manifest["data_root"]).is_dir())
        self.assertTrue((Path(manifest["xdg_data_home"]) / "Trash").is_dir())
        media = Path(manifest["media_dir"])
        self.assertEqual(manifest["media_names"],
                         ["clip.mp4", "loop.gif", "motion.jpg", "still.heic"])
        for name in manifest["media_names"]:
            self.assertTrue((media / name).is_file(), name)
        facts = file_facts(self.root / "evidence" / "fixtures")
        self.assertIn("photos/alpha.png", facts)
        self.assertIn("media-kinds/clip.mp4", facts)
        self.assertNotIn("../", " ".join(facts))


class StepMappingTests(unittest.TestCase):
    def test_all_checks_are_ordered_and_reference_known_steps(self):
        self.assertEqual(list(ux_journey.CHECK_STEPS), list(ux_journey.CHECK_ORDER))

    def test_missing_and_failed_steps_never_pass(self):
        record = {"steps": [
            {"id": "ux-empty-library", "status": "PASS"},
            {"id": "ux-open-settings-button", "status": "FAIL", "detail": "boom"},
        ]}
        checks = ux_journey.step_checks(record)
        self.assertEqual(checks["UX-01"]["status"], "FAIL")
        self.assertIn("ux-open-settings-button", checks["UX-01"]["reason"])
        self.assertEqual(checks["UX-02"]["status"], "NOT RUN")
        self.assertEqual(checks["UX-10"]["status"], "NOT RUN")

    def test_every_required_step_passes(self):
        record = {"steps": [
            {"id": step, "status": "PASS"}
            for steps in ux_journey.CHECK_STEPS.values()
            for step in steps
        ]}
        checks = ux_journey.step_checks(record)
        self.assertEqual({entry["status"] for entry in checks.values()}, {"PASS"})


def _png(path: Path, size=(16, 16), color=(10, 20, 30)) -> bytes:
    from PIL import Image
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", size, color).save(path, format="PNG")
    return path.read_bytes()


class EffectVerificationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="photo-ux-effects-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.fixtures = self.root / "fixtures"
        self.photos = self.fixtures / "photos"
        self.photos.mkdir(parents=True)
        _png(self.photos / "beta.jpg")  # PNG bytes are fine for hashing.
        _png(self.photos / "oriented.jpg", (8, 8), (1, 2, 3))
        _png(self.photos / "small.png", (4, 4), (3, 2, 1))
        extra = self.root / "ux/extra/extra.png"
        _png(extra, (12, 8), (9, 9, 9))
        media = self.fixtures / "media-kinds"
        media.mkdir()
        for name in ("clip.mp4", "loop.gif", "motion.jpg", "still.heic"):
            (media / name).write_bytes(f"fixture-{name}".encode())
        self.initial = file_facts(self.fixtures)
        self.manifest = {"extra_file": str(extra),
                         "media_dir": str(media),
                         "media_names": ["clip.mp4", "loop.gif",
                                         "motion.jpg", "still.heic"]}

        self.source = self.root / "source"
        self.source.mkdir()
        _png(self.source / "beta.jpg")
        _png(self.source / "oriented.jpg", (8, 8), (1, 2, 3))
        _png(self.source / "tiny.png", (4, 4), (3, 2, 1))
        _png(self.source / "alpha2.png", (640, 480), (5, 5, 5))
        _png(self.source / "beta_edited_1.jpg", (100, 100), (6, 6, 6))
        # Unindexed fixture debris that a source removal must also preserve.
        (self.source / "notes.txt").write_text("not an image\n")
        _png(self.source / "broken.jpg", (4, 4), (1, 1, 1))
        self.trips = self.root / "ux/albums/Trips"
        # One of the seven album copies was emptied from the trash earlier.
        for name in ("large.jpg", "large_1.jpg", "beta.jpg",
                     "gamma.webp", "oriented.jpg", "small.png"):
            _png(self.trips / name)
        self.export = self.root / "ux/export"
        beta_bytes = (self.photos / "beta.jpg").read_bytes()
        for index in range(24):
            (self.export / f"copy-{index}.png").parent.mkdir(parents=True, exist_ok=True)
            (self.export / f"copy-{index}.png").write_bytes(beta_bytes)
        self.data = self.root / "ux/data-root"
        (self.data / "cache").mkdir(parents=True)
        (self.data / "logs").mkdir()
        (self.data / "logs/local.log").write_text('{"one":1}\n')
        backup = self.data / "backups/media-1/v1.bak"
        backup.parent.mkdir(parents=True)
        backup.write_bytes(b"backup")
        self.database = self.data / "library.sqlite"
        connection = sqlite3.connect(self.database)
        connection.executescript("""
            CREATE TABLE local_preferences(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE libraries(media_count INTEGER);
            CREATE TABLE sources(enabled INTEGER);
        """)
        for key, value in {
            "theme": '"dark"', "glassMode": '"auto"', "locale": '"en"',
            "backgroundBlur": "0.75", "followScroll": "true",
            "reduceMotion": "true", "dayColumns": "8",
            "thumbnailWorkers": "4", "logLevel": '"debug"',
            "order": '"date_desc"',
        }.items():
            connection.execute("INSERT INTO local_preferences VALUES(?,?)", (key, value))
        connection.execute("INSERT INTO libraries VALUES(0)")
        connection.execute("INSERT INTO sources VALUES(0)")
        connection.execute("INSERT INTO sources VALUES(0)")
        connection.commit()
        connection.close()

        self.facts = {
            "source_root": str(self.source),
            "trips_path": str(self.trips),
            "export_root": str(self.export),
            "data_root": str(self.data),
            "scan_folder": {"discovered": 6},
            "scan_files": {"discovered": 1},
            "rescan": {"total": 7},
            "extra_source_removed": True,
            "theme": "dark", "material": "liquid_glass", "reduce_motion": True,
            "background_blur": 0.75, "follow_scroll": True,
            "day_columns": 8,
            "search_name": {"total": 1}, "search_date": {"total": 2},
            "modes": {"year": "1", "month": "1", "day": "1"},
            "favorite_all": 6, "favorite_all_off": 0,
            "album_copy_files": 6,
            "album_move_file": str(self.trips / "large_1.jpg"),
            "album_move_id": "moved-1",
            "album_removed_files": 6,
            "album_renamed": str(self.trips),
            "album_order_first": str(self.root / "ux/albums/Second"),
            "album_cover_id": "cover-1",
            "renamed_file": str(self.source / "tiny.png"),
            "details_path": str(self.source / "beta.jpg"),
            "export_files": 24,
            "trash_info": "[Trash Info]\nPath=/x\n",
            "trash_payload": "/trash/files/beta.jpg",
            "restored_oriented": True, "purged_gamma": True,
            "empty_trash": True, "viewer_undo": True,
            "viewer_rotate": {"before": [640, 480], "after": [480, 640]},
            "viewer_renamed": str(self.source / "alpha2.png"),
            "immersive": True, "fullscreen_preview": True,
            "filmstrip_offset_initial": 0.0,
            "filmstrip_offsets": {"beta": 0.0, "previous": 0.0,
                                  "returned": 0.0},
            "search_viewer": {"position": "1 / 1", "restored_total": 6},
            "album_navigation": {"album_total": 7, "first": "large.jpg",
                                 "second": "large_1.jpg"},
            "keyboard": {"anchor": "photo-a", "moved_to": "photo-b",
                         "opened": "beta.jpg", "favorite_key": True,
                         "details_key": True},
            "media_scan": {"base_total": 11, "discovered": 4},
            "media_filter": {"images": 14, "videos": 1},
            "video_playback": {"duration_ms": 1500, "position_ms": 300,
                               "duration_label": "00:01",
                               "playing": True, "paused": True,
                               "resumed": True},
            "motion_photo": {"extracted": str(self.data / "cache/motion.mp4"),
                             "bytes": 2048, "played": True},
            "heic_preview": {"path": str(self.data / "cache/preview.jpg"),
                             "width": 200, "height": 150},
            "gif_animated": True,
            "media_source_removed": True,
            "media_files": ["clip.mp4", "loop.gif", "motion.jpg", "still.heic"],
            "edited_copy": {"path": str(self.source / "beta_edited_1.jpg"),
                            "width": 100, "height": 100,
                            "original_unchanged": True},
            "overwrite_backup": str(backup),
            "final_total": 0,
            "source_files": sorted(path.name for path in self.source.iterdir()),
            "logs_before_lines": 46,
            "logs_before_marker": '{"old":1}',
            "logs_after_clear": 1,
        }
        self.record = {"result": "PASS", "steps": [], "facts": {"ux": self.facts}}

    def test_matching_effects_pass_every_check(self):
        checks, evidence = ux_journey.verify_effects(
            self.record, self.manifest, self.initial, {})
        self.assertEqual({entry["status"] for entry in checks.values()}, {"PASS"},
                         {key: value["reason"] for key, value in checks.items()
                          if value["status"] != "PASS"})
        self.assertEqual(evidence["media_count"], 0)
        self.assertEqual(evidence["preferences"]["thumbnailWorkers"], 4)

    def test_fixed_material_and_follow_setting_are_required(self):
        self.facts["material"] = "reduced"
        checks, _ = ux_journey.verify_effects(self.record, self.manifest, self.initial, {})
        self.assertEqual(checks["UX-02"]["status"], "FAIL")
        self.facts["material"] = "liquid_glass"
        self.facts["follow_scroll"] = False
        checks, _ = ux_journey.verify_effects(self.record, self.manifest, self.initial, {})
        self.assertEqual(checks["UX-02"]["status"], "FAIL")

    def test_missing_export_copy_fails_the_export_check_only(self):
        (self.export / "copy-0.png").unlink()
        checks, _ = ux_journey.verify_effects(
            self.record, self.manifest, self.initial, {})
        self.assertEqual(checks["UX-06"]["status"], "FAIL")
        self.assertIn("24", checks["UX-06"]["reason"])
        self.assertEqual(checks["UX-10"]["status"], "PASS")

    def test_changed_untouched_original_or_preference_fails_its_area(self):
        (self.source / "beta.jpg").write_bytes(b"changed")
        connection = sqlite3.connect(self.database)
        connection.execute("UPDATE local_preferences SET value='\"light\"' WHERE key='theme'")
        connection.commit()
        connection.close()
        checks, _ = ux_journey.verify_effects(
            self.record, self.manifest, self.initial, {})
        self.assertEqual(checks["UX-01"]["status"], "FAIL")
        self.assertEqual(checks["UX-10"]["status"], "FAIL")
        self.assertIn("theme", checks["UX-10"]["reason"])

    def test_clear_cache_leftover_and_missing_backup_are_reported(self):
        (self.data / "cache/thumbnail.jpg").write_bytes(b"left")
        (self.data / "backups/media-1/v1.bak").unlink()
        checks, _ = ux_journey.verify_effects(
            self.record, self.manifest, self.initial, {})
        self.assertEqual(checks["UX-10"]["status"], "FAIL")
        self.assertEqual(checks["UX-09"]["status"], "FAIL")
        self.assertIn("cache", checks["UX-10"]["reason"].lower())
        self.assertIn("backup", checks["UX-09"]["reason"].lower())

    def test_altered_media_fixture_fails_only_the_media_kinds_check(self):
        (self.fixtures / "media-kinds/motion.jpg").write_bytes(b"changed")
        checks, _ = ux_journey.verify_effects(
            self.record, self.manifest, self.initial, {})
        self.assertEqual(checks["UX-11"]["status"], "FAIL")
        self.assertIn("motion.jpg", checks["UX-11"]["reason"])
        self.assertEqual(checks["UX-10"]["status"], "PASS")


class RunGuardTests(unittest.TestCase):
    def test_populated_evidence_directory_is_refused_without_building(self):
        with tempfile.TemporaryDirectory(prefix="photo-ux-run-") as tmp:
            evidence = Path(tmp) / "evidence"
            evidence.mkdir()
            (evidence / "stale.log").write_text("old")
            with self.assertRaises(ProfileError):
                ux_journey.run(evidence, skip_build=True)


if __name__ == "__main__":
    unittest.main()
