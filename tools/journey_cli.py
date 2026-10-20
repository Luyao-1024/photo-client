"""Orchestrate real local journeys and record honest S02-S04 check coverage."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path
import sys

from acceptance_cli import artifact_snapshot, run_logged
from local_journey import XvfbDisplay, file_facts, make_fixtures, run_journey
from platform_config import (
    ROOT, ProfileError, canonical_json, load_profile, profile_digest, profile_path,
)

PLAN_VERSION = 2
BUILD_TIMEOUT = 900
PROVISION_TIMEOUT = 600
HOLD_TIMEOUT = 240
PROBE_TIMEOUT = 120
REOPEN_TIMEOUT = 300
MISSING_TIMEOUT = 300
HOLD_SECONDS = 45
MAIN_WINDOW = "1440x900"
RESPONSIVE_WINDOWS = ("390x844", "800x600", "1440x900")
MISSING_FIXTURE = "nested/gamma.webp"
RUN_NAMES = ("provision", "hold", "probe-rejected", "probe-independent", "reopen",
             *(f"reopen-{window}" for window in RESPONSIVE_WINDOWS), "missing")
SCOPING_TEST = ("crates/photo-core/tests/local_library.rs::"
                "foreign_source_and_invalid_batch_roll_back_counts")
SCHEMA_TEST = ("crates/photo-core/tests/local_library.rs::"
               "one_writer_per_data_root_and_future_schema_is_not_reset")
RESCAN_TESTS = ("crates/photo-core/tests/media_local.rs::"
                "recursive_discovery_streams_batches_before_finishing_the_root and ::"
                "cancellation_before_start_and_at_first_batch_stops_discovery")
CACHE_TESTS = ("crates/photo-core/tests/media_local.rs::"
               "thumbnails_are_jpeg_aspect_preserving_and_leave_read_only_originals_unchanged, ::"
               "all_eight_exif_orientations_have_correct_dimensions_and_quadrants and ::"
               "source_size_or_mtime_changes_reject_stale_work_and_preserve_existing_cache")
CHECK_ORDER = ("L02-01", "L02-02", "L02-03", "L02-04",
               "L03-01", "L03-01-dialog", "L03-02", "L03-02-rescan",
               "L03-03", "L03-03-bounds", "L03-04",
               "L04-01", "L04-02", "L04-02-viewer-gestures", "L04-03",
               "L04-04", "L04-04-hover")


def validate_evidence_dir(evidence_dir: Path) -> Path:
    """A fresh or empty evidence directory is required before any run."""
    evidence_dir.mkdir(parents=True, exist_ok=True)
    if any(evidence_dir.iterdir()):
        raise ProfileError("evidence: directory already exists with files; choose a fresh directory")
    return evidence_dir


def build_command(root: Path, mode: str) -> list[str]:
    """The exact platform build command used unless --skip-build is given."""
    return [sys.executable, "-B", str(root / "tools/platform"), "build",
            "--profile", "linux-x86_64", "--mode", mode]


def provision_args(photos: Path, window: str = MAIN_WINDOW) -> list[str]:
    """Arguments for the provision phase against the isolated fixture tree."""
    return [f"--source={photos}", f"--window-size={window}"]


def reopen_args(library_id: str, count: int, favorite_path: str,
                window: str | None = None) -> list[str]:
    """Arguments pinning a reopen run to the identity provision recorded."""
    args = [f"--expect-library-id={library_id}", f"--expect-count={count}",
            f"--expect-favorite-path={favorite_path}"]
    if window is not None:
        args.append(f"--window-size={window}")
    return args


def missing_target(photos: Path, favorite_path: str) -> Path:
    """The fixture deleted for the missing phase; never the favorited photo."""
    target = photos / MISSING_FIXTURE
    if str(target) == favorite_path:
        raise ProfileError("journey: the missing phase would delete the favorited photo")
    return target


def run_ok(run) -> bool:
    """A run passes only on exit 0 with a record whose every step is PASS."""
    record = run.record
    if record is None or run.error is not None or run.exit_code != 0 or run.timed_out:
        return False
    if record.get("result") != "PASS":
        return False
    steps = record.get("steps")
    return (type(steps) is list and len(steps) > 0
            and all(type(step) is dict and step.get("status") == "PASS" for step in steps))


def provision_facts(record: dict | None) -> tuple[str, int, str]:
    """Identity, count and favorite path the reopen phase must be pinned to."""
    facts = (record or {}).get("facts")
    facts = facts if type(facts) is dict else {}
    first = facts.get("first_photo")
    first = first if type(first) is dict else {}
    library_id, count, path = facts.get("library_id"), facts.get("opened_count"), first.get("path")
    if type(library_id) is not str or type(count) is not int or type(path) is not str:
        raise ProfileError("journey: provision record lacks library_id/opened_count/first_photo.path")
    return library_id, count, path


def scan_matches_fixtures(facts: dict | None, fixtures: dict) -> bool:
    """The provision scan counts must equal the generated fixture manifest."""
    scan = (facts or {}).get("scan") if type(facts) is dict else None
    if type(scan) is not dict:
        return False
    return (scan.get("discovered") == fixtures["expected_images"]
            and scan.get("skipped") == fixtures["expected_skipped"]
            and scan.get("failed") == fixtures["expected_failed"])


def _decided(*values: bool | None) -> bool | None:
    if any(value is False for value in values):
        return False
    if any(value is None for value in values):
        return None
    return True


def _verdict(ok: bool | None, reason: str) -> dict:
    status = "NOT RUN" if ok is None else "PASS" if ok else "FAIL"
    return {"status": status, "reason": reason}


def build_checks(statuses: dict[str, bool | None], *, source_unchanged: bool | None,
                 scan_ok: bool | None) -> dict[str, dict]:
    """Map run outcomes onto acceptance IDs without inflating coverage."""

    def runs(*names: str) -> bool | None:
        return _decided(*(statuses.get(name) for name in names))

    provision = statuses.get("provision")
    checks = {
        "L02-01": _verdict(runs("provision", "reopen"),
                           "provision and reopen asserted library_id, opened_count and the favorite "
                           "path across a real restart on an isolated data root; the journey "
                           "environment has no cloud account or session bus."),
        "L02-02": _verdict(runs("hold", "probe-rejected", "probe-independent"),
                           "A second instance on the same data root was rejected while the first "
                           "held it, and an independent data root opened concurrently."),
        "L02-03": {"status": "NOT RUN",
                   "reason": f"Cross-library foreign-key and command-scoping rejection is not "
                             f"driven end-to-end; component coverage: {SCOPING_TEST}."},
        "L02-04": {"status": "NOT RUN",
                   "reason": "Transaction failure and interrupted-migration retention are not "
                             f"driven end-to-end; component coverage: {SCHEMA_TEST}."},
        "L03-01": _verdict(_decided(provision, source_unchanged),
                           "Recursive scan of the real fixture tree was indexed and browsable, and "
                           "file_facts proved source bytes/mtimes unchanged; the modal dialog "
                           "sub-item is tracked as L03-01-dialog."),
        "L03-01-dialog": {"status": "NOT RUN",
                          "reason": "The real GTK file/directory chooser is never driven: the "
                                    "journey substitutes ScriptedSourcePicker for the modal dialog."},
        "L03-02": _verdict(_decided(runs("provision", "missing"), scan_ok),
                           "Unsupported and broken fixtures were skipped/failed without blocking "
                           "other items (scan counts matched the fixture manifest) and a missing "
                           "source did not block healthy photos; rescan/cancel is L03-02-rescan."),
        "L03-02-rescan": {"status": "NOT RUN",
                          "reason": "Duplicate-source rescan dedup and mid-scan cancellation are "
                                    f"not driven end-to-end; component coverage: {RESCAN_TESTS}."},
        "L03-03": _verdict(provision,
                           "EXIF orientation (axis swap for oriented.jpg) and decoded-size/cache-"
                           "class bounds were asserted by provision record steps."),
        "L03-03-bounds": {"status": "NOT RUN",
                          "reason": "256/512/1024 cache-file matching, visible/prefetch decode "
                                    "priority and bounded queue/memory are not measured end-to-"
                                    f"end; component coverage: {CACHE_TESTS}."},
        "L03-04": {"status": "NOT RUN",
                   "reason": "A source changing during decode/cache commit is not driven end-to-"
                             "end; component coverage: crates/photo-core/tests/media_local.rs::"
                             "source_size_or_mtime_changes_reject_stale_work_and_preserve_existing_cache."},
        "L04-01": _verdict(provision,
                           "grid-is-database-driven asserted the paged grid is fed by real "
                           "FFI/database rows with rendered tiles, not sample data."),
        "L04-02": _verdict(provision,
                           "Open, next/previous buttons, ArrowRight and Escape were driven with "
                           "real X11 input against the rendered viewer; gestures are tracked as "
                           "L04-02-viewer-gestures."),
        "L04-02-viewer-gestures": {"status": "NOT RUN",
                                   "reason": "Fullscreen, zoom/pan and rapid-switch anchor "
                                             "retention are not driven end-to-end."},
        "L04-03": _verdict(runs("provision", "reopen"),
                           "The favorite was set through the real UI, verified by a fresh "
                           "favorites-only native query, and survived the restart at the exact "
                           "path; the details dialog showed the real source path and size."),
        "L04-04": _verdict(runs(*(f"reopen-{window}" for window in RESPONSIVE_WINDOWS)),
                           "The reopen flow completed at 390x844, 800x600 and 1440x900 window "
                           "sizes; hover/focus is tracked as L04-04-hover."),
        "L04-04-hover": {"status": "NOT RUN",
                         "reason": "Hover-does-not-activate-album and focus/touch-target checks "
                                   "are not driven end-to-end."},
    }
    return {key: checks[key] for key in CHECK_ORDER}


def gate_status(checks: dict[str, dict], commands: list[dict] = ()) -> str:
    """Any FAIL fails, all-PASS passes, any critical NOT RUN stays INCOMPLETE."""
    statuses = {check["status"] for check in checks.values()}
    if "FAIL" in statuses or any(command.get("status") == "FAIL" for command in commands):
        return "FAIL"
    if statuses == {"PASS"}:
        return "passed"
    return "INCOMPLETE"


def _collect(report: dict, evidence_dir: Path, root: Path, *, mode: str,
             skip_build: bool) -> None:
    profile = load_profile(profile_path("linux-x86_64", root))
    report["profile_digest"] = profile_digest(profile)
    if not skip_build:
        record = run_logged(build_command(root, mode), cwd=root,
                            log_path=evidence_dir / "build.log", timeout=BUILD_TIMEOUT)
        report["commands"].append(record)
        if record["status"] != "PASS":
            raise ProfileError(f"journey: build failed; see {record['log']}")
    snapshot, executable = artifact_snapshot(root, profile, mode)
    report["artifacts"] = snapshot
    report["executable"] = str(executable)

    fixtures = make_fixtures(evidence_dir / "fixtures")
    report["fixtures"] = fixtures
    photos = Path(fixtures["photos_dir"])
    data_root = evidence_dir / "data-root"
    data_root_b = evidence_dir / "data-root-b"
    statuses: dict[str, bool | None] = {name: None for name in RUN_NAMES}
    counters: dict[str, int] = {}

    with XvfbDisplay() as display:
        report["display"] = display

        def journey(name: str, phase: str, run_data_root: Path, args: list[str],
                    timeout: int, *, helper: bool = True, on_ready=None):
            counters[phase] = counters.get(phase, 0) + 1
            run_dir = evidence_dir / "runs" / f"{phase}-{counters[phase]}"
            run = run_journey(executable, display=display, phase=phase,
                              data_root=run_data_root, evidence_dir=run_dir,
                              log_name=f"{phase}.log", timeout=timeout, args=args,
                              helper=helper, on_ready=on_ready)
            statuses[name] = run_ok(run)
            report["runs"][name] = {**run.as_evidence(run_dir), "timeout_seconds": timeout}
            return run

        facts_before = file_facts(photos)
        provision = journey("provision", "provision", data_root,
                            provision_args(photos), PROVISION_TIMEOUT)
        facts_after = file_facts(photos)
        report["source_facts"] = {"unchanged": facts_before == facts_after,
                                  "before": facts_before, "after": facts_after}
        record = provision.record if type(provision.record) is dict else {}
        facts = record.get("facts") if type(record.get("facts")) is dict else {}
        scan_ok = scan_matches_fixtures(facts, fixtures)

        def probe_same_root():
            journey("probe-rejected", "probe-open", data_root, ["--expect-rejected"],
                    PROBE_TIMEOUT, helper=False)

        journey("hold", "hold", data_root, [f"--hold-seconds={HOLD_SECONDS}"],
                HOLD_TIMEOUT, on_ready=probe_same_root)
        journey("probe-independent", "probe-open", data_root_b, [], PROBE_TIMEOUT,
                helper=False)

        if statuses["provision"] is True:
            library_id, count, favorite_path = provision_facts(provision.record)
            report["anchors"] = {"library_id": library_id, "opened_count": count,
                                 "favorite_path": favorite_path}
            journey("reopen", "reopen", data_root,
                    reopen_args(library_id, count, favorite_path), REOPEN_TIMEOUT)
            for window in RESPONSIVE_WINDOWS:
                journey(f"reopen-{window}", "reopen", data_root,
                        reopen_args(library_id, count, favorite_path, window),
                        REOPEN_TIMEOUT)
            target = missing_target(photos, favorite_path)
            target.unlink()
            report["missing_deleted"] = str(target)
            journey("missing", "missing", data_root, [f"--missing-path={target}"],
                    MISSING_TIMEOUT)

    report["checks"] = build_checks(statuses,
                                    source_unchanged=report["source_facts"]["unchanged"],
                                    scan_ok=scan_ok)


def run_local(evidence_dir: Path, root: Path = ROOT, *, mode: str = "release",
              skip_build: bool = False) -> int:
    """Run every journey phase inside evidence_dir and write report.json."""
    validate_evidence_dir(evidence_dir)
    report: dict = {
        "plan_version": PLAN_VERSION,
        "phase": "local",
        "mode": mode,
        "skip_build": skip_build,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "commands": [],
        "runs": {},
        "checks": {},
        "user_review": "NOT RECORDED",
    }
    try:
        _collect(report, evidence_dir, root, mode=mode, skip_build=skip_build)
    except (ProfileError, OSError) as exc:
        report["error"] = str(exc)
    reason = report.get("error", "the journey aborted before this check was decided")
    for key in CHECK_ORDER:
        report["checks"].setdefault(key, {"status": "NOT RUN", "reason": reason})
    report["checks"] = {key: report["checks"][key] for key in CHECK_ORDER}
    report["gate_status"] = gate_status(report["checks"], report["commands"])
    report_path = evidence_dir / "report.json"
    report_path.write_text(canonical_json(report) + "\n", encoding="utf-8")
    print(f"journey {report['gate_status']}: {report_path}")
    if report["gate_status"] != "passed":
        print("Critical NOT RUN sub-items (GTK dialog, rescan/cancel, cache bounds, viewer "
              "gestures, hover/focus, L02-03/L02-04, L03-04) keep the gate open.")
    return 0 if report["gate_status"] == "passed" else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run the real local journey and record honest S02-S04 coverage.")
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    run.add_argument("--evidence-dir", type=Path, required=True)
    run.add_argument("--mode", choices=("debug", "release"), default="release")
    run.add_argument("--skip-build", action="store_true",
                     help="Reuse existing artifacts; artifact_snapshot still verifies them")
    options = parser.parse_args(argv)
    try:
        return run_local(options.evidence_dir.resolve(), mode=options.mode,
                         skip_build=options.skip_build)
    except (ProfileError, OSError) as exc:
        print(f"journey: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
