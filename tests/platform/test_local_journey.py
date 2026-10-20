"""Fixture, thumbnail-math and record contracts for the local journeys."""
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
import sys
sys.path.insert(0, str(ROOT / "tools"))

from local_journey import (FIXTURE_IMAGES, JOURNEY_PREFIX, expected_thumbnail_size, file_facts,
                           make_fixtures, parse_record)
from platform_config import ProfileError
import local_stages


class FixtureContractTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="photo-fixture-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "fixtures"

    def test_fixture_tree_matches_the_documented_scan_expectations(self):
        manifest = make_fixtures(self.root)
        photos = self.root / "photos"
        self.assertEqual(manifest["expected_images"], len(FIXTURE_IMAGES))
        for name in FIXTURE_IMAGES:
            self.assertTrue((photos / name).is_file(), name)
        self.assertTrue((photos / "notes.txt").is_file())
        self.assertTrue((photos / "broken.jpg").is_file())
        self.assertTrue((photos / "link.png").is_symlink())
        self.assertEqual((photos / "link.png").resolve(), (photos / "alpha.png").resolve())
        # The oriented JPEG must really carry EXIF orientation 6.
        from PIL import Image
        with Image.open(photos / "oriented.jpg") as image:
            exif = image.getexif()
        self.assertEqual(exif.get(274), 6)
        self.assertEqual((photos / "nested" / "gamma.webp").parent.name, "nested")

    def test_bulk_fixtures_add_only_the_requested_files(self):
        manifest = make_fixtures(self.root, bulk_count=7)
        bulk = sorted((self.root / "bulk").glob("*.png"))
        self.assertEqual(len(bulk), 7)
        self.assertEqual(manifest["bulk_count"], 7)

    def test_fixture_creation_refuses_a_populated_root(self):
        make_fixtures(self.root)
        with self.assertRaises(ProfileError):
            make_fixtures(self.root)

    def test_file_facts_track_content_size_and_mtime(self):
        make_fixtures(self.root)
        before = file_facts(self.root)
        target = self.root / "photos" / "beta.jpg"
        data = target.read_bytes()
        target.write_bytes(data + b"\x00")
        after = file_facts(self.root)
        self.assertNotEqual(before, after)
        changed = [name for name in before if before[name] != after.get(name)]
        self.assertEqual(changed, ["photos/beta.jpg"])


class ThumbnailMathTests(unittest.TestCase):
    def test_classes_downscale_with_aspect_and_orientation(self):
        self.assertEqual(expected_thumbnail_size(1600, 1200, 1, 1024), (1024, 768))
        self.assertEqual(expected_thumbnail_size(1600, 1200, 1, 512), (512, 384))
        self.assertEqual(expected_thumbnail_size(1600, 1200, 1, 256), (256, 192))
        # EXIF 6 swaps the display axes after reduction.
        self.assertEqual(expected_thumbnail_size(600, 400, 6, 512), (341, 512))
        # Sources smaller than the class are never upscaled.
        self.assertEqual(expected_thumbnail_size(32, 32, 1, 1024), (32, 32))

    def test_all_fixture_classes_are_distinguishable(self):
        for name, (_, width, height, orientation) in FIXTURE_IMAGES.items():
            sizes = {expected_thumbnail_size(width, height, orientation, size)
                     for size in (256, 512, 1024)}
            with self.subTest(name=name):
                if max(width, height) > 1024:
                    self.assertEqual(len(sizes), 3)


class RecordContractTests(unittest.TestCase):
    def record(self, payload):
        return JOURNEY_PREFIX + json.dumps(payload) + "\n"

    def test_single_wellformed_record_parses(self):
        record = parse_record("noise\n" + self.record({"result": "PASS", "steps": []}))
        self.assertEqual(record["result"], "PASS")

    def test_missing_duplicate_or_broken_records_are_rejected(self):
        good = self.record({"result": "PASS"})
        duplicate = JOURNEY_PREFIX + '{"result": "PASS", "result": "FAIL"}\n'
        for text in ("", good + good, duplicate,
                     JOURNEY_PREFIX + "{broken\n", self.record([1, 2])):
            with self.subTest(text=text[:40]), self.assertRaises(ProfileError):
                parse_record(text)

    def test_a_failing_record_parses_but_never_satisfies_require_pass(self):
        from local_journey import JourneyRun
        record = parse_record(self.record({"result": "FAIL", "failure": "boom", "steps": []}))
        run = JourneyRun(["exe"], Path("log"), 1, False, 1.0, record, None, [], None)
        with self.assertRaises(ProfileError):
            local_stages.require_pass(run, "example")


class StageReportTests(unittest.TestCase):
    def test_non_integration_runs_never_claim_pass(self):
        from unittest import mock
        with tempfile.TemporaryDirectory(prefix="photo-stage-") as tmp:
            evidence = Path(tmp) / "evidence"
            with mock.patch.object(local_stages, "run_component_tests", return_value={}):
                code = local_stages.run("S02", evidence, integration=False)
            self.assertNotEqual(code, 0)
            report = json.loads((evidence / "report.json").read_text())
            self.assertEqual(report["gate_status"], "INCOMPLETE")
            self.assertEqual(report["gui_validation"], "NOT RUN")
            statuses = {check["id"]: check["status"] for check in report["checks"]}
            self.assertEqual(set(statuses), set(local_stages.STAGE_CHECKS["S02"]))
            self.assertEqual(set(statuses.values()), {"NOT RUN"})

    def test_a_populated_evidence_directory_is_refused(self):
        from unittest import mock
        with tempfile.TemporaryDirectory(prefix="photo-stage-") as tmp:
            evidence = Path(tmp) / "evidence"
            evidence.mkdir(parents=True)
            (evidence / "stale.log").write_text("old\n", encoding="utf-8")
            with mock.patch.object(local_stages, "run_component_tests", return_value={}):
                with self.assertRaises(ProfileError):
                    local_stages.run("S03", evidence, integration=False)


class StageMappingTests(unittest.TestCase):
    def test_every_documented_item_has_a_check(self):
        self.assertEqual(local_stages.STAGE_CHECKS["S02"],
                         ("L02-01", "L02-02", "L02-03", "L02-04"))
        self.assertEqual(local_stages.STAGE_CHECKS["S03"],
                         ("L03-01", "L03-02", "L03-03", "L03-04"))
        self.assertEqual(local_stages.STAGE_CHECKS["S04"],
                         ("L04-01", "L04-02", "L04-03", "L04-04"))

    def test_component_items_reference_existing_targets(self):
        for item, (target, _) in local_stages.COMPONENT_ITEMS.items():
            self.assertIn(target, ("local_library", "media_local"))
            self.assertIn(item, ("L02-03", "L02-04", "L03-04"))

    def test_component_check_reports_missing_execution(self):
        check = local_stages.component_check("L02-03", {})
        self.assertEqual(check["status"], "NOT RUN")
        self.assertEqual(check["evidence_level"], "component")

    def test_component_check_fails_when_the_named_test_is_absent(self):
        components = {"local_library": {"status": "PASS", "log": "x.log",
                                        "passed_tests": ["some_other_test"]}}
        check = local_stages.component_check("L02-03", components)
        self.assertEqual(check["status"], "FAIL")


if __name__ == "__main__":
    unittest.main()
