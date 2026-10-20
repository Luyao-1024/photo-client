"""Pure orchestration logic for the local journey runner; never starts the app."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import journey_cli as journey
import local_journey
from platform_config import ProfileError

FIXTURES = {"expected_images": 6, "expected_skipped": 2, "expected_failed": 1}
SCAN = {"discovered": 6, "skipped": 2, "failed": 1, "cancelled": False}
FACTS = {"library_id": "lib-1", "opened_count": 6,
         "first_photo": {"path": "/evidence/fixtures/photos/alpha.png"}, "scan": SCAN}
ALL_PASS = {name: True for name in journey.RUN_NAMES}
MAIN_IDS = ("L02-01", "L02-02", "L03-01", "L03-02", "L03-03",
            "L04-01", "L04-02", "L04-03", "L04-04")
NOT_RUN_IDS = ("L02-03", "L02-04", "L03-01-dialog", "L03-02-rescan", "L03-03-bounds",
               "L03-04", "L04-02-viewer-gestures", "L04-04-hover")


def make_run(record=None, exit_code=0, timed_out=False, error=None):
    return local_journey.JourneyRun(["tool"], Path("run.log"), exit_code, timed_out,
                                    0.1, record, None, [], error)


class EvidenceDirTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_missing_directory_is_created(self):
        target = self.root / "nested/evidence"
        self.assertEqual(journey.validate_evidence_dir(target), target)
        self.assertTrue(target.is_dir())

    def test_empty_directory_is_accepted(self):
        target = self.root / "empty"
        target.mkdir()
        journey.validate_evidence_dir(target)

    def test_non_empty_directory_is_rejected(self):
        target = self.root / "dirty"
        target.mkdir()
        (target / "report.json").write_text("{}")
        with self.assertRaisesRegex(ProfileError, "fresh directory"):
            journey.validate_evidence_dir(target)

    def test_main_rejects_dirty_evidence_dir_with_exit_two(self):
        target = self.root / "dirty-main"
        target.mkdir()
        (target / "leftover.log").write_text("x")
        self.assertEqual(journey.main(["run", "--evidence-dir", str(target)]), 2)


class CommandAssemblyTests(unittest.TestCase):
    def test_build_command_targets_the_platform_tool(self):
        command = journey.build_command(Path("/repo"), "release")
        self.assertEqual(command, [sys.executable, "-B", "/repo/tools/platform", "build",
                                   "--profile", "linux-x86_64", "--mode", "release"])

    def test_provision_args_point_only_at_the_fixture_tree(self):
        self.assertEqual(journey.provision_args(Path("/e/fixtures/photos")),
                         ["--source=/e/fixtures/photos", "--window-size=1440x900"])

    def test_reopen_args_pin_identity_count_and_favorite(self):
        args = journey.reopen_args("lib-1", 6, "/p/alpha.png")
        self.assertEqual(args, ["--expect-library-id=lib-1", "--expect-count=6",
                                "--expect-favorite-path=/p/alpha.png"])
        self.assertEqual(journey.reopen_args("lib-1", 6, "/p/alpha.png", "390x844")[-1],
                         "--window-size=390x844")

    def test_missing_target_is_gamma_and_never_the_favorite(self):
        photos = Path("/e/fixtures/photos")
        self.assertEqual(journey.missing_target(photos, "/e/fixtures/photos/alpha.png"),
                         photos / "nested/gamma.webp")
        with self.assertRaisesRegex(ProfileError, "favorited photo"):
            journey.missing_target(photos, str(photos / "nested/gamma.webp"))


class RecordParsingTests(unittest.TestCase):
    def test_run_ok_requires_clean_exit_and_all_steps_passing(self):
        record = local_journey.parse_record(
            'PHOTO_CLIENT_LOCAL {"result":"PASS","steps":[{"id":"a","status":"PASS"}]}')
        self.assertTrue(journey.run_ok(make_run(record)))

    def test_run_ok_rejects_every_weaker_outcome(self):
        passing = {"result": "PASS", "steps": [{"id": "a", "status": "PASS"}]}
        cases = (
            make_run(None),
            make_run(passing, exit_code=1),
            make_run(passing, timed_out=True),
            make_run(passing, error="journey timed out after 60 seconds"),
            make_run({**passing, "result": "FAIL"}),
            make_run({**passing, "steps": [{"id": "a", "status": "FAIL"}]}),
            make_run({**passing, "steps": []}),
            make_run({**passing, "steps": "PASS"}),
            make_run({"result": "PASS"}),
        )
        for run in cases:
            with self.subTest(exit_code=run.exit_code, record=run.record):
                self.assertFalse(journey.run_ok(run))

    def test_provision_facts_extracts_reopen_anchors(self):
        self.assertEqual(journey.provision_facts({"facts": FACTS}),
                         ("lib-1", 6, "/evidence/fixtures/photos/alpha.png"))

    def test_provision_facts_rejects_incomplete_records(self):
        for facts in (None, {}, {"library_id": "lib-1"},
                      {"library_id": "lib-1", "opened_count": "6",
                       "first_photo": {"path": "/p"}},
                      {"library_id": "lib-1", "opened_count": 6, "first_photo": {}}):
            with self.subTest(facts=facts), self.assertRaises(ProfileError):
                journey.provision_facts({"facts": facts} if facts is not None else {})

    def test_scan_must_match_the_fixture_manifest(self):
        self.assertTrue(journey.scan_matches_fixtures(FACTS, FIXTURES))
        for scan in ({**SCAN, "discovered": 5}, {**SCAN, "skipped": 0},
                     {**SCAN, "failed": 0}, None):
            with self.subTest(scan=scan):
                self.assertFalse(journey.scan_matches_fixtures({"scan": scan}, FIXTURES))
        self.assertFalse(journey.scan_matches_fixtures(None, FIXTURES))


class ChecksAggregationTests(unittest.TestCase):
    def checks(self, statuses=None, source_unchanged=True, scan_ok=True):
        return journey.build_checks(statuses if statuses is not None else dict(ALL_PASS),
                                    source_unchanged=source_unchanged, scan_ok=scan_ok)

    def test_all_runs_passing_passes_main_ids_but_keeps_sub_items_not_run(self):
        checks = self.checks()
        for key in MAIN_IDS:
            self.assertEqual(checks[key]["status"], "PASS", key)
        for key in NOT_RUN_IDS:
            self.assertEqual(checks[key]["status"], "NOT RUN", key)
        self.assertEqual(list(checks), list(journey.CHECK_ORDER))

    def test_gtk_dialog_sub_item_names_the_scripted_substitute(self):
        checks = self.checks()
        self.assertIn("ScriptedSourcePicker", checks["L03-01-dialog"]["reason"])
        self.assertIn("local_library.rs", checks["L02-03"]["reason"])
        self.assertIn("local_library.rs", checks["L02-04"]["reason"])
        self.assertIn("media_local.rs", checks["L03-02-rescan"]["reason"])

    def test_not_run_sub_items_keep_the_gate_incomplete(self):
        self.assertEqual(journey.gate_status(self.checks()), "INCOMPLETE")

    def test_gate_passes_only_when_every_check_passes(self):
        all_pass = {key: {"status": "PASS", "reason": "r"} for key in journey.CHECK_ORDER}
        self.assertEqual(journey.gate_status(all_pass), "passed")
        self.assertEqual(journey.gate_status({**all_pass,
                                              "L02-03": {"status": "NOT RUN", "reason": "r"}}),
                         "INCOMPLETE")
        self.assertEqual(journey.gate_status({**all_pass,
                                              "L04-01": {"status": "FAIL", "reason": "r"}}),
                         "FAIL")
        self.assertEqual(journey.gate_status({}), "INCOMPLETE")

    def test_failed_build_command_fails_the_gate(self):
        all_pass = {key: {"status": "PASS", "reason": "r"} for key in journey.CHECK_ORDER}
        self.assertEqual(journey.gate_status(all_pass, [{"status": "FAIL"}]), "FAIL")

    def test_provision_failure_fails_dependent_ids_and_leaves_widths_not_run(self):
        checks = self.checks({**ALL_PASS, "provision": False})
        for key in ("L02-01", "L03-01", "L03-02", "L03-03", "L04-01", "L04-02", "L04-03"):
            self.assertEqual(checks[key]["status"], "FAIL", key)
        self.assertEqual(checks["L02-02"]["status"], "PASS")
        self.assertEqual(checks["L04-04"]["status"], "PASS")

    def test_unrun_phases_never_pass(self):
        checks = self.checks({name: None for name in journey.RUN_NAMES},
                             source_unchanged=None, scan_ok=None)
        for key in MAIN_IDS:
            self.assertEqual(checks[key]["status"], "NOT RUN", key)

    def test_modified_source_or_wrong_scan_counts_fail_their_ids(self):
        self.assertEqual(self.checks(source_unchanged=False)["L03-01"]["status"], "FAIL")
        self.assertEqual(self.checks(scan_ok=False)["L03-02"]["status"], "FAIL")
        self.assertEqual(self.checks(scan_ok=False)["L03-01"]["status"], "PASS")

    def test_width_reopens_decide_l04_04(self):
        checks = self.checks({**ALL_PASS, "reopen-800x600": False})
        self.assertEqual(checks["L04-04"]["status"], "FAIL")
        self.assertEqual(checks["L02-01"]["status"], "PASS")


class OrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.evidence = self.root / "evidence"
        self.photos = self.evidence / "fixtures" / "photos"
        self.calls: list[dict] = []
        self.build_calls: list[list[str]] = []
        self.fail_phases: set[str] = set()
        self.build_status = "PASS"
        console = patch("journey_cli.print", create=True)
        console.start()
        self.addCleanup(console.stop)

    def fake_make_fixtures(self, target, *, bulk_count=0):
        photos = Path(target) / "photos"
        (photos / "nested").mkdir(parents=True)
        (photos / "alpha.png").write_bytes(b"alpha")
        (photos / "nested/gamma.webp").write_bytes(b"gamma")
        return {"root": str(target), "photos_dir": str(photos), "expected_images": 6,
                "expected_skipped": 2, "expected_failed": 1, "bulk_count": 0, "images": {}}

    def fake_run_journey(self, executable, *, display, phase, data_root, evidence_dir,
                         log_name, timeout, args=None, helper=True, on_ready=None):
        Path(evidence_dir).mkdir(parents=True, exist_ok=True)
        self.calls.append({"phase": phase, "dir": Path(evidence_dir).name,
                           "data_root": str(data_root), "args": list(args or []),
                           "helper": helper, "timeout": timeout})
        if on_ready is not None:
            on_ready()
        if phase in self.fail_phases:
            record = {"result": "FAIL", "phase": phase, "facts": {},
                      "steps": [{"id": "s", "status": "FAIL", "detail": "boom"}]}
            exit_code = 1
        else:
            record = {"result": "PASS", "phase": phase, "facts": dict(FACTS),
                      "steps": [{"id": "s", "status": "PASS"}]}
            exit_code = 0
        facts = {**FACTS, "first_photo": {"path": str(self.photos / "alpha.png")}}
        if exit_code == 0:
            record["facts"] = facts
        return local_journey.JourneyRun([str(executable), phase],
                                        Path(evidence_dir) / log_name, exit_code,
                                        False, 0.01, record, None, [])

    def fake_run_logged(self, command, *, cwd, log_path, timeout):
        self.build_calls.append(list(command))
        log_path.write_text("simulated build log\n")
        failed = self.build_status != "PASS"
        return {"command": list(command), "log": log_path.name, "status": self.build_status,
                "exit_code": 1 if failed else 0, "timed_out": False, "elapsed_seconds": 0.01,
                "timeout_seconds": timeout}

    def run_stage(self, *, skip_build=True):
        binary = self.root / "bundle/photo_client"
        with patch.object(journey, "make_fixtures", side_effect=self.fake_make_fixtures), \
                patch.object(journey, "run_journey", side_effect=self.fake_run_journey), \
                patch.object(journey, "run_logged", side_effect=self.fake_run_logged), \
                patch.object(journey, "XvfbDisplay") as display_cls, \
                patch.object(journey, "load_profile", return_value={"profile_id": "linux-x86_64"}), \
                patch.object(journey, "profile_digest", return_value="digest"), \
                patch.object(journey, "artifact_snapshot", return_value=({"native": {}}, binary)):
            display_cls.return_value.__enter__.return_value = ":99"
            result = journey.run_local(self.evidence, self.root, mode="release",
                                       skip_build=skip_build)
        return result, json.loads((self.evidence / "report.json").read_text())

    def test_full_sequence_runs_in_order_inside_the_evidence_dir(self):
        result, report = self.run_stage()
        self.assertEqual(result, 1)
        self.assertEqual(report["plan_version"], 2)
        self.assertEqual(report["phase"], "local")
        self.assertEqual(report["gate_status"], "INCOMPLETE")
        self.assertEqual(report["display"], ":99")
        self.assertTrue(report["source_facts"]["unchanged"])
        self.assertEqual(self.build_calls, [])
        self.assertEqual([call["dir"] for call in self.calls],
                         ["provision-1", "hold-1", "probe-open-1", "probe-open-2",
                          "reopen-1", "reopen-2", "reopen-3", "reopen-4", "missing-1"])
        self.assertEqual([call["phase"] for call in self.calls],
                         ["provision", "hold", "probe-open", "probe-open",
                          "reopen", "reopen", "reopen", "reopen", "missing"])
        for key in MAIN_IDS:
            self.assertEqual(report["checks"][key]["status"], "PASS", key)
        self.assertEqual(report["runs"]["provision"]["timeout_seconds"],
                         journey.PROVISION_TIMEOUT)
        self.assertEqual(report["runs"]["provision"]["exit_code"], 0)

    def test_phase_arguments_match_the_plan(self):
        self.run_stage()
        by_dir = {call["dir"]: call for call in self.calls}
        data_root = str(self.evidence / "data-root")
        self.assertEqual(by_dir["provision-1"]["args"],
                         [f"--source={self.photos}", "--window-size=1440x900"])
        self.assertEqual(by_dir["hold-1"]["args"], ["--hold-seconds=45"])
        self.assertEqual(by_dir["probe-open-1"]["args"], ["--expect-rejected"])
        self.assertFalse(by_dir["probe-open-1"]["helper"])
        self.assertEqual(by_dir["probe-open-1"]["data_root"], data_root)
        self.assertEqual(by_dir["probe-open-2"]["args"], [])
        self.assertFalse(by_dir["probe-open-2"]["helper"])
        self.assertEqual(by_dir["probe-open-2"]["data_root"],
                         str(self.evidence / "data-root-b"))
        self.assertEqual(by_dir["reopen-1"]["args"],
                         ["--expect-library-id=lib-1", "--expect-count=6",
                          f"--expect-favorite-path={self.photos / 'alpha.png'}"])
        for directory, window in (("reopen-2", "390x844"), ("reopen-3", "800x600"),
                                  ("reopen-4", "1440x900")):
            self.assertEqual(by_dir[directory]["args"][-1], f"--window-size={window}")
        self.assertEqual(by_dir["missing-1"]["args"],
                         [f"--missing-path={self.photos / 'nested/gamma.webp'}"])
        for call in self.calls:
            if call["dir"] != "probe-open-2":
                self.assertEqual(call["data_root"], data_root)

    def test_missing_phase_deletes_gamma_and_keeps_the_favorite(self):
        self.run_stage()
        self.assertFalse((self.photos / "nested/gamma.webp").exists())
        self.assertTrue((self.photos / "alpha.png").exists())

    def test_build_runs_by_default_and_its_command_is_recorded(self):
        result, report = self.run_stage(skip_build=False)
        self.assertEqual(self.build_calls, [journey.build_command(self.root, "release")])
        self.assertEqual(report["commands"][0]["status"], "PASS")
        self.assertEqual(result, 1)

    def test_failed_build_fails_the_gate_without_running_journeys(self):
        self.build_status = "FAIL"
        result, report = self.run_stage(skip_build=False)
        self.assertEqual(result, 1)
        self.assertEqual(report["gate_status"], "FAIL")
        self.assertEqual(self.calls, [])
        self.assertIn("build failed", report["error"])
        for key in journey.CHECK_ORDER:
            self.assertEqual(report["checks"][key]["status"], "NOT RUN")

    def test_failed_provision_blocks_reopen_and_missing_phases(self):
        self.fail_phases = {"provision"}
        result, report = self.run_stage()
        self.assertEqual(result, 1)
        self.assertEqual(report["gate_status"], "FAIL")
        self.assertEqual([call["phase"] for call in self.calls],
                         ["provision", "hold", "probe-open", "probe-open"])
        self.assertEqual(report["checks"]["L02-01"]["status"], "FAIL")
        self.assertEqual(report["checks"]["L02-02"]["status"], "PASS")
        self.assertEqual(report["checks"]["L04-04"]["status"], "NOT RUN")
        self.assertTrue((self.photos / "nested/gamma.webp").exists())

    def test_evidence_dir_must_stay_empty(self):
        self.evidence.mkdir(parents=True)
        (self.evidence / "old.log").write_text("x")
        with self.assertRaises(ProfileError):
            self.run_stage()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
