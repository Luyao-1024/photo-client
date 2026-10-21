"""Focused tests for the cloud acceptance orchestrator; never starts a server."""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import cloud_journey as cloud


class EvidenceDirTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_fresh_directory_is_created(self):
        target = self.root / "nested/evidence"
        self.assertEqual(cloud.validate_evidence_dir(target), target)
        self.assertTrue(target.is_dir())

    def test_non_empty_directory_is_rejected(self):
        target = self.root / "dirty"
        target.mkdir()
        (target / "old.json").write_text("{}", encoding="utf-8")
        with self.assertRaises(cloud.CloudJourneyError):
            cloud.validate_evidence_dir(target)


class LibrarySnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "real.sqlite"
        with sqlite3.connect(self.source) as connection:
            connection.execute(
                "CREATE TABLE media (media_id TEXT PRIMARY KEY, state TEXT, "
                "parent_uri TEXT, source_uri TEXT, mime_type TEXT, "
                "media_kind TEXT, size_bytes INTEGER, sort_time_ms INTEGER)"
            )
            connection.execute("CREATE TABLE cloud_accounts (account_id TEXT)")
            for index in range(3):
                connection.execute(
                    "INSERT INTO media VALUES (?, 'active', ?, ?, 'image/jpeg', "
                    "'image', 10, 0)",
                    (f"m{index}", f"/album{index}", str(self.root / f"p{index}.jpg")),
                )

    def test_snapshot_keeps_real_rows_and_rejects_signed_in_library(self):
        target = cloud.snapshot_library(self.source, self.root / "copy")
        with sqlite3.connect(target) as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM media").fetchone()[0], 3)
        self.assertEqual(cloud.ensure_library_is_fresh(target), 3)
        with sqlite3.connect(target) as connection:
            connection.execute("INSERT INTO cloud_accounts VALUES ('a')")
        with self.assertRaises(cloud.CloudJourneyError):
            cloud.ensure_library_is_fresh(target)

    def test_album_choice_uses_three_distinct_single_photo_albums(self):
        rows = [
            ("/one", str(self.root / "one.jpg"), "image/jpeg", 100),
            ("/two", str(self.root / "two.png"), "image/png", 200),
            ("/three", str(self.root / "three.jpg"), "image/jpeg", 300),
            ("/many", str(self.root / "many.jpg"), "image/jpeg", 50),
            ("/many", str(self.root / "many2.jpg"), "image/jpeg", 60),
        ]
        for _, source, _, _ in rows:
            Path(source).write_bytes(b"x")
        database = self.root / "albums.sqlite"
        with sqlite3.connect(database) as connection:
            connection.execute(
                "CREATE TABLE media (parent_uri TEXT, source_uri TEXT, "
                "mime_type TEXT, size_bytes INTEGER, media_kind TEXT, state TEXT, "
                "sort_time_ms INTEGER)"
            )
            connection.executemany(
                "INSERT INTO media VALUES (?, ?, ?, ?, 'image', 'active', 0)", rows
            )
        chosen = cloud.choose_albums(database)
        self.assertEqual(set(chosen.values()), {"/one", "/two", "/three"})
        self.assertEqual(chosen["batch"], "/one")
        self.assertEqual(chosen["single"], "/two")

    def test_album_choice_requires_three_candidates(self):
        database = self.root / "thin.sqlite"
        with sqlite3.connect(database) as connection:
            connection.execute(
                "CREATE TABLE media (parent_uri TEXT, source_uri TEXT, "
                "mime_type TEXT, size_bytes INTEGER, media_kind TEXT, state TEXT, "
                "sort_time_ms INTEGER)"
            )
        with self.assertRaises(cloud.CloudJourneyError):
            cloud.choose_albums(database)


class ClientFileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.jpg"
        self.source.write_bytes(b"original-bytes")
        self.account = "11111111-1111-1111-1111-111111111111"
        self.photo = "22222222-2222-2222-2222-222222222222"
        self.generation = "33333333-3333-3333-3333-333333333333"
        directory = self.root / "cloud" / self.account / "media" / self.photo / self.generation
        directory.mkdir(parents=True)
        (directory / "original.jpg").write_bytes(self.source.read_bytes())
        self.thumbnail = b"\xff\xd8\xff\xe0thumbnail"
        (directory / "thumbnail.jpg").write_bytes(self.thumbnail)
        self.binding = {
            "photo_id": self.photo,
            "content_generation": self.generation,
            "media_id": "media-1",
            "relative_path": "Uploads/2026/a.jpg",
            "source_uri": str(self.source),
            "thumbnail_sha256": hashlib.sha256(self.thumbnail).hexdigest(),
        }

    def test_downloaded_files_match_source_and_recorded_digest(self):
        report = cloud.verify_client_files(self.root, [self.binding])
        self.assertEqual(report["account"], self.account)
        self.assertEqual(report["bindings"][0]["original_bytes"], len(b"original-bytes"))

    def test_source_drift_is_rejected(self):
        self.source.write_bytes(b"changed")
        with self.assertRaises(cloud.CloudJourneyError):
            cloud.verify_client_files(self.root, [self.binding])

    def test_thumbnail_digest_drift_is_rejected(self):
        self.binding["thumbnail_sha256"] = "0" * 64
        with self.assertRaises(cloud.CloudJourneyError):
            cloud.verify_client_files(self.root, [self.binding])

    def test_digest_is_standard_base64_sha256(self):
        digest = cloud.b64_digest(self.source)
        self.assertEqual(
            digest,
            base64.b64encode(hashlib.sha256(self.source.read_bytes()).digest()).decode(),
        )


class PhaseArgumentTests(unittest.TestCase):
    def test_phase_arguments_name_only_real_values(self):
        args = cloud.phase_args("http://127.0.0.1:8790", "e2e", {
            "batch": "/photos/camera",
            "single": "/photos/mobile",
            "extra": "/photos/gif",
        }, 3)
        joined = "\n".join(args)
        self.assertIn("--cloud-endpoint=http://127.0.0.1:8790", args)
        self.assertIn("--cloud-batch-album=/photos/camera", args)
        self.assertIn("--cloud-expected-photos=3", args)
        self.assertNotIn("password", joined.lower())


if __name__ == "__main__":
    unittest.main()
