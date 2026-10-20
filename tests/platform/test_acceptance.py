"""Strict smoke semantics and integration evidence flow, without running the GUI."""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import ANY, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import acceptance_cli as acceptance
from platform_config import ProfileError, generate, load_profile, profile_digest

DIGEST = "7d53d9326d3afebc855e822b4b243c29f6e3482c9445fb44cb284f5087801280"
NORMAL = {
    "result": "PASS", "real_window": True, "round_trip": True,
    "event_sequence": [1, 2, 3], "shutdown": True, "profile_digest": DIGEST,
    "profile_id": "linux-x86_64", "bridge_protocol_version": 1,
}


def smoke_line(value):
    return "PHOTO_CLIENT_SMOKE " + json.dumps(value) + "\n"


class SmokeContractTests(unittest.TestCase):
    def validate(self, text, exit_code=0, expected_rejection=None):
        return acceptance.validate_smoke(text, exit_code=exit_code, digest=DIGEST,
                                         expected_rejection=expected_rejection)

    def test_normal_record_requires_full_semantics(self):
        output = "GTK diagnostic\n" + smoke_line(NORMAL) + "other diagnostic\n"
        self.assertEqual(self.validate(output), NORMAL)

    def test_missing_malformed_ambiguous_or_non_object_json_cannot_pass(self):
        for text in (
            "", "PASS\n", "PHOTO_CLIENT_SMOKE\n", "PHOTO_CLIENT_SMOKE {\n",
            "PHOTO_CLIENT_SMOKE []\n", "PHOTO_CLIENT_SMOKE null\n",
            'PHOTO_CLIENT_SMOKE {"result":"FAIL"}\n',
            'PHOTO_CLIENT_SMOKE {"result":"PASS","result":"FAIL"}\n',
            'PHOTO_CLIENT_SMOKE {"result":"PASS","value":NaN}\n',
            smoke_line(NORMAL) + smoke_line(NORMAL),
            smoke_line(NORMAL) + "PHOTO_CLIENT_SMOKE broken\n",
        ):
            with self.subTest(text=text), self.assertRaises(ProfileError):
                self.validate(text)

    def test_every_required_normal_field_must_be_present(self):
        for key in ("result", "real_window", "round_trip", "event_sequence", "shutdown", "profile_digest"):
            missing = copy.deepcopy(NORMAL)
            del missing[key]
            with self.subTest(key=key), self.assertRaises(ProfileError):
                self.validate(smoke_line(missing))

    def test_booleans_must_be_exactly_true(self):
        for field in ("real_window", "round_trip", "shutdown"):
            for value in (False, 1, "true", None):
                changed = {**NORMAL, field: value}
                with self.subTest(field=field, value=value), self.assertRaises(ProfileError):
                    self.validate(smoke_line(changed))

    def test_event_sequence_must_have_three_monotonic_integers(self):
        for sequence in ([], [1, 2], [1, 2, 3, 4], [1, 1, 3], [3, 2, 1],
                         [1, 2.0, 3], [False, 1, 2], ["1", "2", "3"], None):
            with self.subTest(sequence=sequence), self.assertRaises(ProfileError):
                self.validate(smoke_line({**NORMAL, "event_sequence": sequence}))

    def test_wrong_profile_digest_or_supplied_identity_cannot_pass(self):
        for field, value in (("profile_digest", "wrong"), ("profile_id", "android-arm64"),
                             ("bridge_protocol_version", 2), ("bridge_protocol_version", True),
                             ("bridge_protocol_version", 1.0)):
            with self.subTest(field=field, value=value), self.assertRaises(ProfileError):
                self.validate(smoke_line({**NORMAL, field: value}))

    def test_nonzero_exit_overrides_valid_smoke_output(self):
        for exit_code in (None, 1, -9):
            with self.subTest(exit_code=exit_code), self.assertRaises(ProfileError):
                self.validate(smoke_line(NORMAL), exit_code=exit_code)

    def test_expected_rejections_require_exact_type_and_no_initialization(self):
        for rejection in ("BuildProfileMismatch", "BridgeMismatch"):
            expected = {"result": "PASS", "expected_rejection": rejection, "initialized": False}
            self.assertEqual(self.validate(smoke_line(expected), expected_rejection=rejection), expected)
            for change in ({"initialized": True}, {"initialized": 0}, {"initialized": None},
                           {"expected_rejection": "OtherError"}, {"result": "FAIL"}):
                with self.subTest(rejection=rejection, change=change), self.assertRaises(ProfileError):
                    self.validate(smoke_line({**expected, **change}), expected_rejection=rejection)
            for key in expected:
                missing = dict(expected)
                del missing[key]
                with self.subTest(missing=key), self.assertRaises(ProfileError):
                    self.validate(smoke_line(missing), expected_rejection=rejection)


class RepositoryFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.profile = load_profile(ROOT / "config/platforms/linux-x86_64.yaml", host=("Linux", "x86_64"))
        self.write("config/platforms/linux-x86_64.yaml", (ROOT / "config/platforms/linux-x86_64.yaml").read_bytes())
        self.write("Cargo.lock", b"rust-lock")
        self.write("app/pubspec.lock", b"dart-lock")
        self.write("crates/photo-bridge/src/frb_generated.rs", b"generated-rust")
        self.write("app/lib/src/rust/frb_generated.dart", b"generated-dart")
        self.write("app/lib/src/rust/api/bootstrap.dart", b"generated-api")
        self.write("target/release/libphoto_bridge.so", b"native-bridge")
        self.write("app/build/linux/x64/release/bundle/lib/libphoto_bridge.so", b"native-bridge")
        self.binary = self.write("app/build/linux/x64/release/bundle/photo_client", b"fixture executable; never run")
        self.binary.chmod(0o755)
        self.write("tests/platform/test_placeholder.py", b"# Discovery guard fixture; never executed")
        generate(self.profile, self.root)

    def write(self, path, data):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return target


class ArtifactTests(RepositoryFixture):
    def test_snapshot_records_native_bundle_locks_profiles_and_all_bindings(self):
        snapshot, executable = acceptance.artifact_snapshot(self.root, self.profile, "release")
        self.assertEqual(executable, self.binary)
        for category in ("native", "bundle", "locks", "profiles", "bindings"):
            self.assertTrue(snapshot[category])
        self.assertIn("app/lib/src/rust/api/bootstrap.dart", snapshot["bindings"])
        self.assertEqual(snapshot["native"]["target/release/libphoto_bridge.so"], hashlib.sha256(b"native-bridge").hexdigest())

    def test_missing_required_artifact_or_installed_bridge_cannot_pass(self):
        for name in ("Cargo.lock", "app/pubspec.lock", "crates/photo-bridge/src/frb_generated.rs",
                     "app/lib/src/rust/frb_generated.dart", "target/release/libphoto_bridge.so",
                     "app/build/linux/x64/release/bundle/lib/libphoto_bridge.so"):
            path = self.root / name
            data = path.read_bytes()
            path.unlink()
            with self.subTest(name=name), self.assertRaises(ProfileError):
                acceptance.artifact_snapshot(self.root, self.profile, "release")
            path.write_bytes(data)

    def test_installed_bridge_must_equal_built_library(self):
        self.write("app/build/linux/x64/release/bundle/lib/libphoto_bridge.so", b"stale")
        with self.assertRaisesRegex(ProfileError, "installed bridge differs"):
            acceptance.artifact_snapshot(self.root, self.profile, "release")

    def test_tampered_generated_profile_or_defines_cannot_pass(self):
        for name in ("profile.json", "dart-defines.json"):
            path = self.root / ".build/linux-x86_64" / name
            original = path.read_bytes()
            path.write_bytes(original + b"\n")
            with self.subTest(name=name), self.assertRaises(ProfileError):
                acceptance.artifact_snapshot(self.root, self.profile, "release")
            path.write_bytes(original)

    def test_repeat_build_rejects_changed_added_or_removed_binding_profile_or_lock(self):
        baseline, _ = acceptance.artifact_snapshot(self.root, self.profile, "release")
        for category in ("bindings", "profiles", "locks"):
            for mutation in ("change", "add", "remove"):
                altered = copy.deepcopy(baseline)
                entries = altered[category]
                key = next(iter(entries))
                if mutation == "change":
                    entries[key] = "changed hash"
                elif mutation == "add":
                    entries["new-file"] = "new hash"
                else:
                    del entries[key]
                with self.subTest(category=category, mutation=mutation), self.assertRaises(ProfileError):
                    acceptance.compare_repeat_snapshots(baseline, altered)

    def test_binary_hashes_are_recorded_without_claiming_s14_bit_reproducibility(self):
        baseline, _ = acceptance.artifact_snapshot(self.root, self.profile, "release")
        changed = copy.deepcopy(baseline)
        changed["native"]["target/release/libphoto_bridge.so"] = "new binary hash"
        acceptance.compare_repeat_snapshots(baseline, changed)


class CommandAndDisplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_commands_use_arrays_without_shell_and_have_bounded_waits(self):
        command = ["tool", "path with spaces", "$(must stay literal)"]
        with patch("acceptance_cli.subprocess.Popen") as popen:
            process = popen.return_value
            process.wait.return_value = 0
            result = acceptance.run_logged(command, cwd=self.root, log_path=self.root / "run.log", timeout=60)
        popen.assert_called_once_with(command, cwd=self.root, stdout=ANY, stderr=subprocess.STDOUT, start_new_session=True)
        process.wait.assert_called_once_with(timeout=60)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["command"], command)

    def test_timeout_kills_command_process_group_and_never_passes(self):
        command = ["tool"]
        with patch("acceptance_cli.subprocess.Popen") as popen, patch("acceptance_cli.os.killpg") as killpg:
            process = popen.return_value
            process.pid = 12345
            process.wait.side_effect = [subprocess.TimeoutExpired(command, 1), -9]
            result = acceptance.run_logged(command, cwd=self.root, log_path=self.root / "timeout.log", timeout=1)
        killpg.assert_called_once_with(12345, signal.SIGKILL)
        self.assertEqual(result["status"], "FAIL")
        self.assertTrue(result["timed_out"])
        self.assertEqual([call.kwargs["timeout"] for call in process.wait.call_args_list], [1, 5])
        self.assertIn("ACCEPTANCE_TIMEOUT", (self.root / "timeout.log").read_text())

    def test_process_reap_timeout_is_bounded_and_cannot_pass(self):
        command = ["tool"]
        with patch("acceptance_cli.subprocess.Popen") as popen, patch("acceptance_cli.os.killpg"):
            process = popen.return_value
            process.pid = 12345
            process.wait.side_effect = subprocess.TimeoutExpired(command, 1)
            result = acceptance.run_logged(command, cwd=self.root, log_path=self.root / "reap-timeout.log", timeout=1)
        self.assertEqual(result["status"], "FAIL")
        self.assertIsNone(result["exit_code"])
        self.assertTrue(result["timed_out"])
        self.assertIn("did not exit", result["execution_error"])
        self.assertEqual(process.wait.call_count, 2)

    def test_start_failure_is_recorded_as_failure(self):
        with patch("acceptance_cli.subprocess.Popen", side_effect=FileNotFoundError("missing tool")):
            result = acceptance.run_logged(["missing"], cwd=self.root, log_path=self.root / "missing.log", timeout=1)
        self.assertEqual(result["status"], "FAIL")
        self.assertIsNone(result["exit_code"])
        self.assertIn("execution_error", result)

    def test_existing_display_is_used_directly(self):
        with patch.dict(os.environ, {"DISPLAY": ":99"}, clear=True), patch("acceptance_cli.shutil.which") as which:
            self.assertEqual(acceptance.display_prefix(), ([], "existing DISPLAY"))
        which.assert_not_called()

    def test_xvfb_is_selected_only_when_display_is_absent(self):
        with patch.dict(os.environ, {}, clear=True), patch("acceptance_cli.shutil.which", return_value="/bin/xvfb-run"):
            prefix, description = acceptance.display_prefix()
        self.assertEqual(prefix[:2], ["/bin/xvfb-run", "-a"])
        self.assertIn("GPU visual validation NOT RUN", description)

    def test_no_display_and_no_xvfb_cannot_pass(self):
        with patch.dict(os.environ, {}, clear=True), patch("acceptance_cli.shutil.which", return_value=None):
            with self.assertRaisesRegex(ProfileError, "neither DISPLAY nor xvfb-run"):
                acceptance.display_prefix()


class IntegrationWorkflowTests(RepositoryFixture):
    def setUp(self):
        super().setUp()
        console = patch("acceptance_cli.print", create=True)
        console.start()
        self.addCleanup(console.stop)
        self.smokes = {
            "smoke-window.log": smoke_line(NORMAL),
            "smoke-profile-mismatch.log": smoke_line({"result": "PASS", "expected_rejection": "BuildProfileMismatch", "initialized": False}),
            "smoke-bridge-mismatch.log": smoke_line({"result": "PASS", "expected_rejection": "BridgeMismatch", "initialized": False}),
        }
        self.fail_command = None
        self.on_second_build = None
        self.calls = []

    def fake_command(self, command, *, cwd, log_path, timeout):
        # All actions in these workflow tests are mocked. No Flutter or GUI starts.
        self.calls.append(command)
        if log_path.name == "build-2.log" and self.on_second_build:
            self.on_second_build()
        log_path.write_text(self.smokes.get(log_path.name, "simulated command log\n"))
        failed = log_path.name == self.fail_command
        return {"command": list(command), "cwd": str(cwd), "log": log_path.name,
                "timeout_seconds": timeout, "elapsed_seconds": 0.01, "timed_out": False,
                "exit_code": 7 if failed else 0, "status": "FAIL" if failed else "PASS"}

    def run_stage(self, integration=True):
        with patch("acceptance_cli.run_logged", side_effect=self.fake_command), patch("acceptance_cli.display_prefix", return_value=(["/bin/xvfb-run", "-a"], "mocked Xvfb")):
            result = acceptance.run_s01(self.root / "evidence", self.root, integration=integration)
        return result, json.loads((self.root / "evidence/report.json").read_text())

    def test_default_never_builds_or_approves_gui(self):
        result, report = self.run_stage(integration=False)
        self.assertEqual(result, 1)
        self.assertEqual(report["gate_status"], "INCOMPLETE")
        self.assertEqual(report["gui_validation"], "NOT RUN")
        self.assertIsNone(report["integration"])
        self.assertEqual(len(self.calls), 1)

    def test_integration_pass_requires_two_builds_and_three_semantic_smokes(self):
        result, report = self.run_stage()
        self.assertEqual(result, 0)
        self.assertEqual(report["gate_status"], "PASS")
        self.assertEqual([c["status"] for c in report["checks"] if c["id"].startswith("S01-C")], ["PASS"] * 3)
        integration = report["integration"]
        self.assertEqual(len(integration["commands"]), 5)
        self.assertEqual(set(integration["snapshots"]), {"build_1", "build_2"})
        self.assertEqual(integration["commands"][2]["command"], ["/bin/xvfb-run", "-a", str(self.binary), "--self-test"])
        self.assertIn("--expect-profile-mismatch", integration["commands"][3]["command"])
        self.assertIn("--expect-bridge-mismatch", integration["commands"][4]["command"])
        self.assertEqual(report["gpu_visual_validation"], "NOT RUN")
        self.assertEqual(report["packaging_validation"], "NOT RUN")
        self.assertEqual(report["user_review"], "NOT RECORDED")

    def test_failed_first_or_second_build_cannot_pass(self):
        # Fresh evidence directories are required for separate runs.
        for number in (1, 2):
            self.fail_command = f"build-{number}.log"
            evidence = self.root / f"evidence-build-{number}"
            with patch("acceptance_cli.run_logged", side_effect=self.fake_command):
                result = acceptance.run_s01(evidence, self.root, integration=True)
            report = json.loads((evidence / "report.json").read_text())
            with self.subTest(number=number):
                self.assertNotEqual(result, 0)
                self.assertEqual(report["gate_status"], "FAIL")
                self.assertEqual(report["gui_validation"], "NOT RUN")
                self.assertFalse(report["integration"]["smoke"])

    def test_missing_smoke_output_with_exit_zero_cannot_approve_stage(self):
        self.smokes["smoke-window.log"] = "process exited normally without smoke evidence\n"
        result, report = self.run_stage()
        self.assertNotEqual(result, 0)
        self.assertEqual(report["gate_status"], "FAIL")
        self.assertEqual(report["gui_validation"], "FAIL")

    def test_malformed_smoke_output_with_exit_zero_cannot_approve_stage(self):
        self.smokes["smoke-window.log"] = "PHOTO_CLIENT_SMOKE {invalid json}\n"
        result, report = self.run_stage()
        self.assertNotEqual(result, 0)
        self.assertEqual(report["gate_status"], "FAIL")

    def test_nonzero_smoke_exit_cannot_pass_even_with_valid_record(self):
        self.fail_command = "smoke-window.log"
        result, report = self.run_stage()
        self.assertNotEqual(result, 0)
        self.assertEqual(report["gate_status"], "FAIL")

    def test_rejection_after_initialization_fails_c02(self):
        self.smokes["smoke-profile-mismatch.log"] = smoke_line({"result": "PASS", "expected_rejection": "BuildProfileMismatch", "initialized": True})
        result, report = self.run_stage()
        self.assertNotEqual(result, 0)
        c02 = next(check for check in report["checks"] if check["id"] == "S01-C02")
        self.assertEqual(c02["status"], "FAIL")

    def test_changed_binding_on_repeat_build_fails_c03(self):
        self.on_second_build = lambda: self.write("app/lib/src/rust/frb_generated.dart", b"changed")
        result, report = self.run_stage()
        self.assertNotEqual(result, 0)
        c03 = next(check for check in report["checks"] if check["id"] == "S01-C03")
        self.assertEqual(c03["status"], "FAIL")
        self.assertIn("bindings changed", c03["reason"])
        self.assertFalse(report["integration"]["smoke"])

    def test_missing_display_leaves_integration_incomplete(self):
        with patch("acceptance_cli.run_logged", side_effect=self.fake_command), patch("acceptance_cli.display_prefix", side_effect=ProfileError("display: unavailable")):
            result = acceptance.run_s01(self.root / "evidence", self.root, integration=True)
        report = json.loads((self.root / "evidence/report.json").read_text())
        self.assertEqual(result, 1)
        self.assertEqual(report["gate_status"], "INCOMPLETE")
        self.assertEqual(report["gui_validation"], "NOT RUN")
        self.assertEqual(len(report["integration"]["commands"]), 2)

    def test_unknown_stage_with_integration_still_returns_not_implemented(self):
        with patch("acceptance_cli.run_s01") as run:
            result = acceptance.main(["run", "--stage", "S14", "--integration", "--evidence-dir", str(self.root / "no-evidence")])
        self.assertEqual(result, 2)
        run.assert_not_called()
        self.assertFalse((self.root / "no-evidence").exists())


if __name__ == "__main__":
    unittest.main()
