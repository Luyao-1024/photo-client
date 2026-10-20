"""Collect bounded S01 execution evidence; never infer acceptance from exit alone."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time

import local_stages
from platform_config import (
    ROOT, ProfileError, canonical_json, dart_defines, generate, load_profile,
    profile_digest, profile_path,
)

BUILD_TIMEOUT = 900
SMOKE_TIMEOUT = 60
TEST_TIMEOUT = 180
SMOKE_PREFIX = "PHOTO_CLIENT_SMOKE "


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _fingerprints(root: Path) -> dict[str, str]:
    paths = [root / "Cargo.lock", root / "app/pubspec.lock", root / "rust-toolchain.toml"]
    return {str(path.relative_to(root)): _sha256(path) for path in paths if path.is_file()}


def run_logged(command: list[str], *, cwd: Path, log_path: Path, timeout: int) -> dict:
    """Capture a command and stop its process group on timeout (including children)."""
    started = time.monotonic()
    result = {
        "command": command, "cwd": str(cwd), "log": log_path.name,
        "timeout_seconds": timeout, "exit_code": None, "timed_out": False,
    }
    # Exclusive creation preserves logs even when a previous run was interrupted.
    with log_path.open("x", encoding="utf-8") as log:
        try:
            process = subprocess.Popen(
                command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                result["exit_code"] = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                result["timed_out"] = True
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    result["exit_code"] = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    result["execution_error"] = "Process did not exit after process-group kill"
                log.write(f"\nACCEPTANCE_TIMEOUT after {timeout} seconds\n")
        except OSError as exc:
            result["execution_error"] = str(exc)
            log.write(f"\nACCEPTANCE_EXECUTION_ERROR: {exc}\n")
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    result["status"] = "PASS" if result["exit_code"] == 0 and not result["timed_out"] else "FAIL"
    return result


def _unique_json_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate smoke field: {key}")
        result[key] = value
    return result


def _invalid_constant(value: str) -> None:
    raise ValueError(f"invalid JSON constant: {value}")


def validate_smoke(output: str, *, exit_code: int | None, digest: str,
                   expected_rejection: str | None = None) -> dict:
    if exit_code != 0:
        raise ProfileError(f"smoke: expected exit 0, got {exit_code}")
    lines = [line for line in output.splitlines() if line.startswith("PHOTO_CLIENT_SMOKE")]
    if len(lines) != 1 or not lines[0].startswith(SMOKE_PREFIX):
        raise ProfileError("smoke: expected exactly one PHOTO_CLIENT_SMOKE JSON record")
    try:
        smoke = json.loads(lines[0][len(SMOKE_PREFIX):], object_pairs_hook=_unique_json_object,
                           parse_constant=_invalid_constant)
    except (ValueError, RecursionError) as exc:
        raise ProfileError("smoke: invalid or ambiguous JSON record") from exc
    if type(smoke) is not dict or smoke.get("result") != "PASS":
        raise ProfileError("smoke: expected an object with result PASS")
    if expected_rejection is not None:
        if expected_rejection not in {"BuildProfileMismatch", "BridgeMismatch"}:
            raise ProfileError("smoke: unsupported expected rejection")
        if smoke.get("expected_rejection") != expected_rejection or smoke.get("initialized") is not False:
            raise ProfileError(f"smoke: expected {expected_rejection} with initialized=false")
    else:
        if any(smoke.get(key) is not True for key in ("real_window", "round_trip", "shutdown")):
            raise ProfileError("smoke: real_window, round_trip and shutdown must all be true")
        sequence = smoke.get("event_sequence")
        if (type(sequence) is not list or len(sequence) != 3
                or any(type(value) is not int for value in sequence)
                or not sequence[0] < sequence[1] < sequence[2]):
            raise ProfileError("smoke: expected exactly three strictly increasing integer events")
        if smoke.get("profile_digest") != digest:
            raise ProfileError("smoke: profile_digest differs from the selected profile")
        # The runner may include these fields; they must agree when present.
        if "profile_id" in smoke and smoke["profile_id"] != "linux-x86_64":
            raise ProfileError("smoke: unexpected profile_id")
        if "bridge_protocol_version" in smoke and (type(smoke["bridge_protocol_version"]) is not int
                                                  or smoke["bridge_protocol_version"] != 1):
            raise ProfileError("smoke: unexpected bridge_protocol_version")
    return smoke


def _hash_files(paths: list[Path], root: Path) -> dict[str, str]:
    return {str(path.relative_to(root)): _sha256(path) for path in sorted(paths)}


def artifact_snapshot(root: Path, profile: dict, mode: str) -> tuple[dict, Path]:
    native = root / "target" / mode / "libphoto_bridge.so"
    bundle = root / "app/build/linux/x64" / mode / "bundle"
    executables = sorted(p for p in bundle.iterdir() if p.is_file() and os.access(p, os.X_OK)) if bundle.is_dir() else []
    if len(executables) != 1:
        raise ProfileError("artifacts: bundle must contain exactly one executable")
    installed_native = bundle / "lib/libphoto_bridge.so"
    required_locks = [root / "Cargo.lock", root / "app/pubspec.lock"]
    rust_binding = root / "crates/photo-bridge/src/frb_generated.rs"
    dart_binding = root / "app/lib/src/rust/frb_generated.dart"
    generated_dir = root / ".build" / profile["profile_id"]
    profile_files = [profile_path(profile["profile_id"], root), generated_dir / "profile.json", generated_dir / "dart-defines.json"]
    for path in (native, installed_native, rust_binding, dart_binding, *required_locks, *profile_files):
        if not path.is_file():
            raise ProfileError(f"artifacts: required file missing: {path.relative_to(root)}")
    if (generated_dir / "profile.json").read_bytes() != canonical_json(profile).encode("utf-8"):
        raise ProfileError("artifacts: generated profile differs from the selected canonical profile")
    if (generated_dir / "dart-defines.json").read_bytes() != canonical_json(dart_defines(profile)).encode("utf-8"):
        raise ProfileError("artifacts: generated Dart defines differ from the selected profile")
    if _sha256(native) != _sha256(installed_native):
        raise ProfileError("artifacts: installed bridge differs from the built native library")
    bindings = sorted(set((root / "crates/photo-bridge/src").glob("frb_generated*.rs"))
                      | set((root / "app/lib/src/rust").rglob("*.dart")))
    return {
        "native": _hash_files([native], root),
        "bundle": _hash_files([p for p in bundle.rglob("*") if p.is_file()], root),
        "locks": _fingerprints(root),
        "bindings": _hash_files(bindings, root),
        "profiles": _hash_files(profile_files, root),
    }, executables[0]


def compare_repeat_snapshots(before: dict, after: dict) -> None:
    # Record binary hashes without promising bit-reproducible S14 packaging.
    for category in ("bindings", "profiles", "locks"):
        if before[category] != after[category]:
            raise ProfileError(f"repeat-build: {category} changed between builds")


def display_prefix() -> tuple[list[str], str]:
    if os.environ.get("DISPLAY"):
        return [], "existing DISPLAY"
    xvfb = shutil.which("xvfb-run")
    if not xvfb:
        raise ProfileError("display: neither DISPLAY nor xvfb-run is available")
    return [xvfb, "-a", "-s", "-screen 0 1440x900x24"], "Xvfb (GPU visual validation NOT RUN)"


def run_integration(evidence_dir: Path, root: Path, profile: dict, mode: str) -> dict:
    stages = {key: {"id": key, "status": "NOT RUN", "reason": "Integration prerequisites not completed."}
              for key in ("S01-C01", "S01-C02", "S01-C03")}
    evidence = {"commands": [], "snapshots": {}, "smoke": {}, "checks": stages,
                "gui_validation": "NOT RUN", "mode": mode}
    command = [sys.executable, "-B", str(root / "tools/platform"), "build", "--profile", profile["profile_id"], "--mode", mode]
    for number in (1, 2):
        record = run_logged(command, cwd=root, log_path=evidence_dir / f"build-{number}.log", timeout=BUILD_TIMEOUT)
        evidence["commands"].append(record)
        if record["status"] != "PASS":
            failed_stage = "S01-C01" if number == 1 else "S01-C03"
            stages[failed_stage] = {"id": failed_stage, "status": "FAIL", "reason": f"Build {number} failed; see {record['log']}."}
            return evidence
        try:
            snapshot, executable = artifact_snapshot(root, profile, mode)
        except (ProfileError, OSError) as exc:
            failed_stage = "S01-C01" if number == 1 else "S01-C03"
            stages[failed_stage] = {"id": failed_stage, "status": "FAIL", "reason": str(exc)}
            return evidence
        evidence["snapshots"][f"build_{number}"] = snapshot
    try:
        compare_repeat_snapshots(evidence["snapshots"]["build_1"], evidence["snapshots"]["build_2"])
    except ProfileError as exc:
        stages["S01-C03"] = {"id": "S01-C03", "status": "FAIL", "reason": str(exc)}
        return evidence
    stages["S01-C03"] = {"id": "S01-C03", "status": "PASS", "reason": "Two builds succeeded; generated bindings, profiles and lockfiles unchanged. Unsupported-stage rejection covered by platform tests."}
    try:
        prefix, display = display_prefix()
    except ProfileError as exc:
        for key in ("S01-C01", "S01-C02"):
            stages[key]["reason"] = str(exc)
        return evidence
    evidence["display"] = display
    cases = [
        ("window", ["--self-test"], None),
        ("profile-mismatch", ["--self-test", "--expect-profile-mismatch"], "BuildProfileMismatch"),
        ("bridge-mismatch", ["--self-test", "--expect-bridge-mismatch"], "BridgeMismatch"),
    ]
    for name, arguments, rejection in cases:
        log_path = evidence_dir / f"smoke-{name}.log"
        record = run_logged([*prefix, str(executable), *arguments], cwd=executable.parent,
                            log_path=log_path, timeout=SMOKE_TIMEOUT)
        evidence["commands"].append(record)
        try:
            if record["status"] != "PASS":
                raise ProfileError(f"smoke: command failed; see {log_path.name}")
            # Bound parsing memory even when a faulty runner floods its log.
            with log_path.open("rb") as log:
                output = log.read(1024 * 1024 + 1)
            if len(output) > 1024 * 1024:
                raise ProfileError("smoke: output exceeds 1 MiB")
            smoke = validate_smoke(output.decode("utf-8"), exit_code=record["exit_code"],
                                   digest=profile_digest(profile), expected_rejection=rejection)
            evidence["smoke"][name] = {"status": "PASS", "record": smoke, "log": log_path.name}
        except (ProfileError, OSError, UnicodeError) as exc:
            evidence["smoke"][name] = {"status": "FAIL", "reason": str(exc), "log": log_path.name}
    normal = evidence["smoke"]["window"]["status"]
    evidence["gui_validation"] = normal
    stages["S01-C01"] = {"id": "S01-C01", "status": normal,
                            "reason": "Real-window/round-trip/events/shutdown evidence: smoke-window.log"}
    rejected = all(evidence["smoke"][key]["status"] == "PASS" for key in ("profile-mismatch", "bridge-mismatch"))
    stages["S01-C02"] = {"id": "S01-C02", "status": "PASS" if rejected else "FAIL",
                            "reason": "Runtime profile/protocol refusal evidence in mismatch logs; planned targets and unknown adapters covered by platform tests."}
    return evidence


def run_s01(evidence_dir: Path, root: Path = ROOT, *, integration: bool = False, mode: str = "release") -> int:
    evidence_dir.mkdir(parents=True, exist_ok=True)
    report_path = evidence_dir / "report.json"
    log_path = evidence_dir / "platform-tests.log"
    if any(evidence_dir.iterdir()):
        raise ProfileError("evidence: directory already exists with files; choose a fresh directory")
    checks = []
    digest = None
    profile = None
    try:
        profile = load_profile(profile_path("linux-x86_64", root))
        digest = profile_digest(profile)
        with tempfile.TemporaryDirectory(prefix="photo-s01-profile-") as temp:
            generated = generate(profile, Path(temp))
            if generated["profile_json"].read_bytes() != canonical_json(profile).encode("utf-8"):
                raise ProfileError("generated profile differs from canonical input")
            if generated["dart_defines"].read_bytes() != canonical_json(dart_defines(profile)).encode("utf-8"):
                raise ProfileError("generated Dart defines differ from canonical input")
        checks.append({"id": "profile-generation", "status": "PASS", "profile_digest": digest})
    except (ProfileError, OSError) as exc:
        checks.append({"id": "profile-generation", "status": "FAIL", "reason": str(exc)})
    command = [sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests/platform", "-p", "test_*.py", "-v"]
    if not list((root / "tests/platform").glob("test_*.py")):
        log_path.write_text("No platform tests implemented.\n", encoding="utf-8")
        checks.append({"id": "platform-tests", "status": "FAIL", "reason": "No tests implemented"})
    else:
        record = run_logged(command, cwd=root, log_path=log_path, timeout=TEST_TIMEOUT)
        checks.append({"id": "platform-tests", **record})
    integration_result = None
    if integration and all(check["status"] == "PASS" for check in checks):
        integration_result = run_integration(evidence_dir, root, profile, mode)
        checks.extend(integration_result["checks"].values())
    else:
        reason = "Integration checks require --integration and passing platform checks."
        checks.extend({"id": key, "status": "NOT RUN", "reason": reason}
                      for key in ("S01-C01", "S01-C02", "S01-C03"))
    statuses = {check["status"] for check in checks}
    status = "FAIL" if "FAIL" in statuses else "PASS" if statuses == {"PASS"} else "INCOMPLETE"
    report = {
        "stage": "S01", "gate_status": status, "integration_requested": integration,
        "scope": "S01 engineering/configuration/runtime checks; S14 installation/packaging and GPU visual acceptance are not certified.",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "profile_digest": digest, "dependency_fingerprints": _fingerprints(root),
        "checks": checks, "integration": integration_result,
        "gui_validation": integration_result["gui_validation"] if integration_result else "NOT RUN",
        "gpu_visual_validation": "NOT RUN", "packaging_validation": "NOT RUN",
        "user_review": "NOT RECORDED",
    }
    report_path.write_text(canonical_json(report) + "\n", encoding="utf-8")
    print(f"S01 {status}: {report_path}")
    print("GPU visual/packaging acceptance NOT RUN; user review NOT RECORDED.")
    return 0 if status == "PASS" else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Collect stage evidence without fabricating gate results.")
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    run.add_argument("--stage", required=True)
    run.add_argument("--evidence-dir", type=Path, required=True)
    run.add_argument("--integration", action="store_true", help="Run two actual builds and real-window/rejection smoke checks")
    run.add_argument("--mode", choices=("debug", "release"), default="release")
    run.add_argument(
        "--bulk-count", type=int, default=None,
        help="Override the synthetic bulk fixture size for S03 visible-window evidence")
    options = parser.parse_args(argv)
    try:
        if options.stage == "S01":
            return run_s01(options.evidence_dir.resolve(), integration=options.integration,
                           mode=options.mode)
        if options.stage in local_stages.STAGE_CHECKS:
            if options.bulk_count is not None:
                local_stages.BULK_COUNT = max(0, options.bulk_count)
            return local_stages.run(options.stage, options.evidence_dir.resolve(),
                                    integration=options.integration, mode=options.mode)
    except (ProfileError, OSError) as exc:
        print(f"acceptance: {exc}", file=sys.stderr)
        return 2
    print(f"{options.stage}: NOT IMPLEMENTED", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
