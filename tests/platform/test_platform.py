"""Configuration, build command, argument forwarding and evidence boundaries."""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import acceptance_cli
import platform_cli
from platform_config import (
    ProfileError, canonical_json, dart_defines, generate, load_profile,
    profile_digest, require_active, validate_profile,
)

LINUX_HOST = ("Linux", "x86_64")


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.profile = load_profile(ROOT / "config/platforms/linux-x86_64.yaml", host=LINUX_HOST)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "profile.yaml"

    def load_text(self, text):
        self.path.write_text(text, encoding="utf-8")
        return load_profile(self.path, host=LINUX_HOST)

    def check_invalid(self, changed, error):
        with self.assertRaisesRegex(ProfileError, error):
            validate_profile(changed, host=LINUX_HOST)

    def test_actual_profiles_preserve_all_design_values(self):
        examples = json.loads((ROOT / "docs/design/contracts/platform-profiles.json").read_text())["profiles"]
        for expected in examples:
            with self.subTest(profile=expected["profile_id"]):
                actual = load_profile(ROOT / f"config/platforms/{expected['profile_id']}.yaml", host=LINUX_HOST)
                self.assertEqual(actual, expected)

    def test_malformed_yaml_and_multiple_documents(self):
        for text in ("platform: [broken", "---\nplatform: linux\n---\nplatform: windows"):
            with self.subTest(text=text), self.assertRaisesRegex(ProfileError, "valid YAML"):
                self.load_text(text)

    def test_duplicate_keys_at_root_and_nested(self):
        baseline = yaml.safe_dump(self.profile)
        for text in (baseline + "platform: linux\n", baseline.replace("  transfer_parallelism: 4", "  transfer_parallelism: 4\n  transfer_parallelism: 2")):
            with self.subTest(text=text), self.assertRaisesRegex(ProfileError, "duplicate YAML field"):
                self.load_text(text)

    def test_aliases_and_unsafe_yaml_tags_are_rejected(self):
        for text in ("a: &x [1]\nb: *x", "!!python/object:os.system {}", "!!map text"):
            with self.subTest(text=text), self.assertRaises(ProfileError):
                self.load_text(text)

    def test_non_string_mapping_keys_and_non_mapping_root(self):
        for text in ("1: value", "[a, b]", "null", "? [a, b]\n: value"):
            with self.subTest(text=text), self.assertRaises(ProfileError):
                self.load_text(text)

    def test_missing_and_unknown_fields_at_every_level(self):
        for section in (None, "adapters", "limits", "ui", "packaging"):
            for operation in ("unknown", "missing"):
                value = copy.deepcopy(self.profile)
                mapping = value if section is None else value[section]
                if operation == "unknown":
                    mapping["shell_command"] = "$(do-not-execute)"
                else:
                    mapping.pop(next(iter(mapping)))
                with self.subTest(section=section, operation=operation):
                    self.check_invalid(value, f"{operation} fields")

    def test_strict_scalar_types(self):
        mutations = [
            ("schema_version", True), ("schema_version", "1"), ("profile_id", 1),
            ("status", False), ("platform", 3), ("flutter_target", None), ("rust_target", []),
            ("limits.transfer_parallelism", True), ("limits.transfer_parallelism", 1.0),
            ("limits.transfer_parallelism", "4"), ("limits.transfer_parallelism", 0),
            ("limits.transfer_parallelism", -1), ("ui.touch", 1), ("ui.keyboard_mouse", "true"),
            ("adapters.storage", True), ("packaging.format", 2),
        ]
        for path, replacement in mutations:
            value = copy.deepcopy(self.profile)
            keys = path.split(".")
            parent = value if len(keys) == 1 else value[keys[0]]
            parent[keys[-1]] = replacement
            with self.subTest(path=path, replacement=replacement):
                self.check_invalid(value, path)

    def test_target_adapter_packaging_and_layout_consistency(self):
        mutations = [
            ("platform", "macos"), ("profile_id", "../../escape"), ("status", "enabled"),
            ("flutter_target", "windows"), ("rust_target", "aarch64-linux-android"),
            ("adapters.storage", "windows_app_data"), ("adapters.codec", "unknown"),
            ("packaging.format", "windows_installer"), ("ui.layout", "desktop"),
        ]
        for path, replacement in mutations:
            value = copy.deepcopy(self.profile)
            keys = path.split(".")
            parent = value if len(keys) == 1 else value[keys[0]]
            parent[keys[-1]] = replacement
            with self.subTest(path=path):
                self.check_invalid(value, path)

    def test_dependent_resource_limits(self):
        for key, other in (("original_parallelism", "transfer_parallelism"), ("decoder_single_mib", "decoder_total_mib")):
            value = copy.deepcopy(self.profile)
            value["limits"][key] = value["limits"][other] + 1
            self.check_invalid(value, key)

    def test_numeric_limits_reject_u32_overflow(self):
        for key in self.profile["limits"]:
            for overflow in (1 << 32, 1 << 80):
                value = copy.deepcopy(self.profile)
                value["limits"][key] = overflow
                with self.subTest(key=key, overflow=overflow):
                    self.check_invalid(value, f"limits.{key}: expected a positive u32 integer")

    def test_numeric_limits_accept_u32_max_with_valid_dependent_limits(self):
        maximum = (1 << 32) - 1
        for key in self.profile["limits"]:
            if key == "gallery_rows_limit":
                continue
            value = copy.deepcopy(self.profile)
            value["limits"][key] = maximum
            if key == "original_parallelism":
                value["limits"]["transfer_parallelism"] = maximum
            elif key == "decoder_single_mib":
                value["limits"]["decoder_total_mib"] = maximum
            with self.subTest(key=key):
                validated = validate_profile(value, host=LINUX_HOST)
                self.assertEqual(validated["limits"][key], maximum)

    def test_gallery_rows_limit_has_a_hard_bound_of_2000(self):
        for rows in (1, 1000, 2000):
            value = copy.deepcopy(self.profile)
            value["limits"]["gallery_rows_limit"] = rows
            with self.subTest(accepted_rows=rows):
                self.assertEqual(validate_profile(value, host=LINUX_HOST)["limits"]["gallery_rows_limit"], rows)
        for rows in (2001, (1 << 32) - 1):
            value = copy.deepcopy(self.profile)
            value["limits"]["gallery_rows_limit"] = rows
            with self.subTest(rejected_rows=rows):
                self.check_invalid(value, "limits.gallery_rows_limit: must be <= 2000")

    def test_active_linux_rejects_wrong_host(self):
        for host in (("Windows", "AMD64"), ("Linux", "aarch64"), ("Darwin", "x86_64")):
            with self.subTest(host=host), self.assertRaisesRegex(ProfileError, "host:"):
                validate_profile(self.profile, host=host)

    def test_planned_inspection_allowed_but_build_run_refused(self):
        for name in ("android-arm64", "windows-x86_64"):
            value = load_profile(ROOT / f"config/platforms/{name}.yaml", host=("Linux", "x86_64"))
            with self.assertRaisesRegex(ProfileError, "planned"):
                require_active(value)
            value["status"] = "active"
            self.check_invalid(value, "not activated")

    def test_canonical_json_digest_and_generated_defines(self):
        # Independent expected serializer also exercises nested order and UTF-8.
        vector = {"z": {"b": "照片", "a": 1}, "a": [True, 2]}
        self.assertEqual(canonical_json(vector), '{"a":[true,2],"z":{"a":1,"b":"照片"}}')
        reordered = dict(reversed(list(self.profile.items())))
        reordered["limits"] = dict(reversed(list(reordered["limits"].items())))
        expected = json.dumps(self.profile, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.assertEqual(profile_digest(reordered), hashlib.sha256(expected).hexdigest())
        with patch("platform_config.host_platform.system", return_value="Linux"), patch("platform_config.host_platform.machine", return_value="x86_64"):
            paths = generate(reordered, Path(self.temp.name))
        self.assertEqual(paths["profile_json"].read_bytes(), expected)
        defines = json.loads(paths["dart_defines"].read_text())
        self.assertEqual(defines["PHOTO_PROFILE_JSON"].encode("utf-8"), expected)
        self.assertEqual(defines["PHOTO_PROFILE_DIGEST"], hashlib.sha256(expected).hexdigest())
        self.assertEqual(defines["PHOTO_BRIDGE_PROTOCOL_VERSION"], "1")
        self.assertEqual(defines, dart_defines(self.profile))
        self.assertNotIn(str(ROOT), defines["PHOTO_PROFILE_JSON"])

    def test_profile_size_and_encoding_are_bounded(self):
        for raw in (b"a" * (256 * 1024 + 1), b"\xff\xfe"):
            self.path.write_bytes(raw)
            with self.assertRaises(ProfileError):
                load_profile(self.path)


class ToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def cli(self, *args):
        return subprocess.run([sys.executable, "-B", str(ROOT / "tools/platform"), *args], text=True, capture_output=True, check=False)

    def test_planned_build_and_run_stop_before_tool_discovery(self):
        for operation in ("build", "run"):
            result = self.cli(operation, "--profile", "android-arm64")
            self.assertEqual(result.returncode, 2)
            self.assertIn("planned", result.stderr)
            self.assertNotIn("toolchain", result.stderr)

    def test_profile_file_negative_cli(self):
        path = self.root / "bad.yaml"
        path.write_text("schema_version: 1\nschema_version: 1\n")
        result = self.cli("validate", "--profile-file", str(path))
        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_unknown_profile_and_invalid_mode_are_rejected(self):
        for args in (("describe", "--profile", "../../escape"), ("build", "--mode", "profile")):
            result = self.cli(*args)
            self.assertEqual(result.returncode, 2)

    def test_flutter_root_takes_precedence_and_bad_override_fails(self):
        flutter = self.root / "bin/flutter"
        flutter.parent.mkdir()
        flutter.write_text("#!/bin/sh\nexit 0\n")
        flutter.chmod(0o755)
        with patch.dict(os.environ, {"PHOTO_FLUTTER_ROOT": str(self.root)}):
            self.assertEqual(platform_cli.discover_flutter(), str(flutter))
        with patch.dict(os.environ, {"PHOTO_FLUTTER_ROOT": str(self.root / "missing")}):
            with self.assertRaisesRegex(ProfileError, "not executable"):
                platform_cli.discover_flutter()

    def test_flutter_path_discovery(self):
        with patch.dict(os.environ, {}, clear=True), patch("platform_cli.shutil.which", return_value="/toolchain/flutter"):
            self.assertEqual(platform_cli.discover_flutter(), "/toolchain/flutter")
        with patch.dict(os.environ, {}, clear=True), patch("platform_cli.shutil.which", return_value=None):
            with self.assertRaisesRegex(ProfileError, "not found"):
                platform_cli.discover_flutter()

    def test_build_order_paths_and_shared_profile_values(self):
        profile = load_profile(ROOT / "config/platforms/linux-x86_64.yaml", host=LINUX_HOST)
        (self.root / "app").mkdir()
        for path in ("Cargo.toml", "Cargo.lock", "app/pubspec.yaml"):
            (self.root / path).touch()
        for mode in ("debug", "release"):
            calls = []

            def execute(args, *, cwd, env=None):
                calls.append((args, cwd, env))
                if len(calls) == 1:
                    native = self.root / "target" / mode / "libphoto_bridge.so"
                    native.parent.mkdir(parents=True, exist_ok=True)
                    native.touch()
                else:
                    (self.root / "app/build/linux/x64" / mode / "bundle").mkdir(parents=True, exist_ok=True)

            with self.subTest(mode=mode), patch("platform_cli.discover_flutter", return_value="/flutter/bin/flutter"), patch("platform_cli.shutil.which", return_value="/cargo/bin/cargo"), patch("platform_cli.execute", side_effect=execute):
                bundle = platform_cli.build(profile, mode, self.root)
            expected = ["/cargo/bin/cargo", "build", "--locked", "-p", "photo-bridge"]
            if mode == "release":
                expected.append("--release")
            self.assertEqual(calls[0][0], expected)
            self.assertEqual(calls[0][1], self.root)
            self.assertEqual(calls[1][0][:5], ["/flutter/bin/flutter", "--no-version-check", "build", "linux", f"--{mode}"])
            self.assertEqual(calls[1][1], self.root / "app")
            self.assertEqual(calls[0][2]["PHOTO_PROFILE_DIGEST"], profile_digest(profile))
            self.assertEqual(calls[0][2]["PHOTO_PROFILE_JSON"], calls[1][2]["PHOTO_PROFILE_JSON"])
            self.assertEqual(calls[0][2]["CARGO_TARGET_DIR"], str(self.root / "target"))
            self.assertEqual(calls[0][2]["PHOTO_NATIVE_LIB_DIR"], str(self.root / "target" / mode))
            self.assertEqual(calls[1][2]["PHOTO_NATIVE_LIB_DIR"], str(self.root / "target" / mode))
            defines = self.root / ".build/linux-x86_64/dart-defines.json"
            self.assertEqual(calls[1][0][5], f"--dart-define-from-file={defines}")
            self.assertEqual(bundle, self.root / f"app/build/linux/x64/{mode}/bundle")

    def test_cargo_failure_stops_flutter(self):
        profile = load_profile(ROOT / "config/platforms/linux-x86_64.yaml", host=LINUX_HOST)
        (self.root / "app").mkdir()
        for path in ("Cargo.toml", "Cargo.lock", "app/pubspec.yaml"):
            (self.root / path).touch()
        with patch("platform_cli.discover_flutter", return_value="flutter"), patch("platform_cli.shutil.which", return_value="cargo"), patch("platform_cli.execute", side_effect=subprocess.CalledProcessError(8, ["cargo"])) as execute:
            with self.assertRaises(subprocess.CalledProcessError):
                platform_cli.build(profile, "debug", self.root)
            self.assertEqual(execute.call_count, 1)

    def test_launch_forwards_literal_arguments_without_shell(self):
        executable = self.root / "photo_client"
        executable.touch(mode=0o755)
        args = ["--", "--data-root", "a path with spaces", "$(touch should-never-run)"]
        with patch("platform_cli.execute") as execute:
            platform_cli.launch(self.root, args)
        execute.assert_called_once_with([str(executable), *args[1:]], cwd=self.root)
        self.assertFalse((self.root / "should-never-run").exists())

    def test_actual_subprocess_uses_no_shell_and_does_not_print_env(self):
        with patch("platform_cli.subprocess.run") as run, patch("builtins.print") as output:
            platform_cli.execute(["tool", "space argument"], cwd=self.root, env={"PRIVATE_TOKEN": "secret"})
        run.assert_called_once_with(["tool", "space argument"], cwd=self.root, env={"PRIVATE_TOKEN": "secret"}, check=True)
        self.assertNotIn("secret", str(output.call_args_list))

    def test_unknown_stages_never_create_pass_or_evidence(self):
        for stage in (*[f"S{i:02}" for i in range(2, 15)], "S99", "unknown"):
            directory = self.root / stage
            result = subprocess.run([sys.executable, "-B", str(ROOT / "tools/acceptance"), "run", "--stage", stage, "--evidence-dir", str(directory)], text=True, capture_output=True, check=False)
            with self.subTest(stage=stage):
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("NOT IMPLEMENTED", result.stderr)
                self.assertFalse(directory.exists())

    def test_s01_evidence_cannot_claim_unexecuted_gui_pass(self):
        (self.root / "tests/platform").mkdir(parents=True)
        (self.root / "tests/platform/test_example.py").touch()
        # Test evidence state transitions without recursive unittest execution.
        with patch("acceptance_cli.run_logged", return_value={"status": "PASS", "exit_code": 0}):
            result = acceptance_cli.run_s01(self.root / "evidence", ROOT)
        self.assertNotEqual(result, 0)
        report = json.loads((self.root / "evidence/report.json").read_text())
        self.assertEqual(report["gate_status"], "INCOMPLETE")
        self.assertEqual(report["gui_validation"], "NOT RUN")
        self.assertEqual(report["gpu_visual_validation"], "NOT RUN")
        self.assertEqual(report["user_review"], "NOT RECORDED")
        self.assertEqual([c["status"] for c in report["checks"] if c["id"].startswith("S01-C")], ["NOT RUN"] * 3)
        with self.assertRaisesRegex(ProfileError, "already exists"):
            acceptance_cli.run_s01(self.root / "evidence", ROOT)


if __name__ == "__main__":
    unittest.main()
