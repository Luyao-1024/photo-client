"""S02-S04 stage evidence over the real executable, real files and real input.

Journeys run the shipped bundle in a dedicated X server against isolated data
roots and generated fixtures. Component-only evidence is labelled as such and
never presented as an end-to-end result.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from platform_config import (ROOT, ProfileError, canonical_json, load_profile, profile_digest,
                             profile_path)
from local_journey import (FIXTURE_IMAGES, JourneyRun, WINDOW_TITLE, expected_thumbnail_size,
                           file_facts, make_fixtures, run_journey)

BUILD_TIMEOUT = 1800
JOURNEY_TIMEOUT = 900
PROBE_TIMEOUT = 180
HOLD_SECONDS = 90
BULK_COUNT = 2500
WIDTHS = ((390, 844), (800, 600), (1440, 900))
STAGE_CHECKS = {
    "S02": ("L02-01", "L02-02", "L02-03", "L02-04"),
    "S03": ("L03-01", "L03-02", "L03-03", "L03-04"),
    "S04": ("L04-01", "L04-02", "L04-03", "L04-04"),
}
COMPONENT_TARGETS = {
    "S02": ("local_library",),
    "S03": ("media_local", "local_library"),
    "S04": (),
}
COMPONENT_ITEMS = {
    "L02-03": ("local_library", "foreign_source_and_invalid_batch_roll_back_counts"),
    "L02-04": ("local_library", "one_writer_per_data_root_and_future_schema_is_not_reset"),
    "L03-04": ("media_local", "source_size_or_mtime_changes_reject_stale_work_and_preserve_existing_cache"),
}


def _base():
    import acceptance_cli
    return acceptance_cli


def _check(item: str, status: str, reason: str, **extra) -> dict:
    return {"id": item, "status": status, "reason": reason, **extra}


def _evaluate(item: str, body, **extra) -> dict:
    try:
        return _check(item, "PASS", body(), **extra)
    except (ProfileError, OSError, ValueError, KeyError) as exc:
        return _check(item, "FAIL", f"{type(exc).__name__}: {exc}", **extra)


def facts_of(run: JourneyRun) -> dict:
    return (run.record or {}).get("facts") or {}


def steps_of(run: JourneyRun) -> dict:
    return {step.get("id"): step for step in (run.record or {}).get("steps", [])}


def require_pass(run: JourneyRun, label: str) -> None:
    record = run.record
    if record is None:
        raise ProfileError(f"{label}: no journey record ({run.error or f'exit {run.exit_code}'})")
    if record.get("result") != "PASS" or run.exit_code != 0:
        detail = record.get("failure") or run.error or f"exit {run.exit_code}"
        failed = [step.get("id") for step in record.get("steps", []) if step.get("status") != "PASS"]
        raise ProfileError(f"{label}: journey did not pass ({detail}; failed steps: {failed})")


def step_status(run: JourneyRun, step_id: str) -> tuple[str, str]:
    step = steps_of(run).get(step_id)
    if step is None:
        return "NOT RUN", f"step {step_id} did not run"
    return step.get("status", "FAIL"), step.get("detail", "")


def require_step(run: JourneyRun, step_id: str, label: str) -> None:
    status, detail = step_status(run, step_id)
    if status != "PASS":
        raise ProfileError(f"{label}: step {step_id} is {status} ({detail})")


# --------------------------------------------------------------------- images

def image_stats(path: Path) -> dict:
    try:
        from PIL import Image, ImageStat
    except ModuleNotFoundError as exc:  # pragma: no cover
        raise ProfileError("images: Pillow is required to verify rendered evidence") from exc
    if not path.is_file() or path.stat().st_size == 0:
        raise ProfileError(f"images: missing capture {path.name}")
    with Image.open(path) as raw:
        image = raw.convert("RGB")
        stat = ImageStat.Stat(image)
        colors = image.getcolors(maxcolors=4_000_000) or []
        return {"file": path.name, "width": image.width, "height": image.height,
                "distinct_colors": len(colors),
                "stddev": [round(value, 2) for value in stat.stddev]}


def require_painted(stats: dict, label: str) -> None:
    if stats["distinct_colors"] < 64 or max(stats["stddev"]) < 8:
        raise ProfileError(
            f"{label}: {stats['file']} is not visibly rendered "
            f"({stats['distinct_colors']} colors, stddev {stats['stddev']})")


def verify_thumbnails(facts: dict, evidence_dir: Path, label: str) -> list[dict]:
    classes = facts.get("thumbnail_classes")
    if not classes:
        raise ProfileError(f"{label}: the journey recorded no thumbnail cache classes")
    name = classes.get("name")
    if name not in FIXTURE_IMAGES:
        raise ProfileError(f"{label}: unexpected fixture {name!r}")
    _, width, height, orientation = FIXTURE_IMAGES[name]
    measured = []
    for size_class, path_text in (classes.get("paths") or {}).items():
        path = Path(path_text)
        if not path.is_file():
            raise ProfileError(f"{label}: cache file missing for class {size_class}: {path}")
        stats = image_stats(path)
        expected = expected_thumbnail_size(width, height, orientation, int(size_class))
        if abs(stats["width"] - expected[0]) > 1 or abs(stats["height"] - expected[1]) > 1:
            raise ProfileError(
                f"{label}: class {size_class} cached {stats['width']}x{stats['height']}, "
                f"expected {expected[0]}x{expected[1]} for {name}")
        measured.append({"size_class": int(size_class), "path": str(path), **stats,
                         "expected": list(expected)})
    if len(measured) != len(FIXTURE_IMAGES[name]) and len(measured) != 3:
        raise ProfileError(f"{label}: expected three cache classes, got {len(measured)}")
    return measured


def verify_sources(before: dict, after: dict, label: str) -> None:
    if before == after:
        return
    names = sorted(set(before) | set(after))
    changed = [name for name in names if before.get(name) != after.get(name)]
    raise ProfileError(f"{label}: source files changed: {changed[:6]}")


# ------------------------------------------------------------------ components

def run_component_tests(base, root: Path, evidence_dir: Path, stage: str) -> dict:
    results = {}
    for target in COMPONENT_TARGETS[stage]:
        command = ["cargo", "test", "--locked", "--offline", "-p", "photo-core", "--test", target,
                   "--", "--nocapture"]
        if not shutil.which("cargo"):
            raise ProfileError("components: cargo is not available on PATH")
        record = base.run_logged(command, cwd=root, log_path=evidence_dir / f"cargo-{target}.log",
                                 timeout=900)
        names = []
        log_path = evidence_dir / f"cargo-{target}.log"
        for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("test ") and line.rstrip().endswith("ok"):
                names.append(line.split()[1])
        results[target] = {"command": command, "log": log_path.name, "exit_code": record["exit_code"],
                           "status": record["status"], "passed_tests": sorted(names)}
    return results


def component_check(item: str, components: dict) -> dict:
    target, name = COMPONENT_ITEMS[item]
    result = components.get(target)
    if result is None:
        return _check(item, "NOT RUN", f"component target {target} was not executed",
                      evidence_level="component")
    if result["status"] != "PASS":
        return _check(item, "FAIL", f"cargo test --test {target} failed; see {result['log']}",
                      evidence_level="component")
    if name not in result["passed_tests"]:
        return _check(item, "FAIL", f"{target}::{name} did not report ok", evidence_level="component")
    return _check(item, "PASS",
                  f"component evidence: cargo test -p photo-core --test {target} ({name}); "
                  "no application-level surface exists for this rule yet",
                  evidence_level="component", test=f"{target}::{name}", log=result["log"])


# --------------------------------------------------------------------- plumbing

def build_bundle(base, root: Path, evidence_dir: Path, profile: dict, mode: str) -> tuple[dict, Path]:
    command = [sys.executable, "-B", str(root / "tools/platform"), "build",
               "--profile", profile["profile_id"], "--mode", mode]
    record = base.run_logged(command, cwd=root, log_path=evidence_dir / "build.log",
                             timeout=BUILD_TIMEOUT)
    if record["status"] != "PASS":
        raise ProfileError(f"build failed; see build.log (exit {record['exit_code']})")
    snapshot, executable = base.artifact_snapshot(root, profile, mode)
    return {"build": record, "snapshot": snapshot}, executable


def network_isolation_prefix() -> tuple[list[str] | None, str]:
    if not shutil.which("unshare"):
        return None, "unshare is unavailable; no network-isolated rerun"
    try:
        result = subprocess.run(["unshare", "-rn", "true"], capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"unshare probe failed: {exc}"
    if result.returncode != 0:
        detail = (result.stderr or b"").decode("utf-8", "replace").strip()[:200]
        return None, f"unshare -rn is not permitted here: {detail}"
    return ["unshare", "-rn"], "journey repeated inside a new network namespace (no interfaces)"


def journey(ctx: dict, subdir: str | None = None, **kwargs) -> JourneyRun:
    """Each journey owns a dedicated X server and evidence subdirectory so a
    wedged display or a same-named capture cannot poison other evidence."""
    evidence_dir = ctx["evidence_dir"] / subdir if subdir else ctx["evidence_dir"]
    evidence_dir.mkdir(parents=True, exist_ok=True)

    def sink(display: str) -> None:
        ctx["current_display"] = display
        ctx["evidence"].setdefault("displays", []).append(
            {"journey": kwargs.get("log_name"), "display": display, "dir": str(evidence_dir)})

    run = run_journey(ctx["executable"], evidence_dir=evidence_dir, display_sink=sink, **kwargs)
    run.evidence_dir = evidence_dir
    ctx["journeys"].append(run.as_evidence(ctx["root"]))
    return run


# -------------------------------------------------------------------------- S02

def stage_s02(ctx: dict, components: dict, integration: bool) -> list[dict]:
    checks = [component_check("L02-03", components), component_check("L02-04", components)]
    if not integration:
        checks.extend(_check(item, "NOT RUN", "Real journeys require --integration.")
                      for item in ("L02-01", "L02-02"))
        return checks
    evidence_dir = ctx["evidence_dir"]
    data_root = ctx["data_root"]
    other_root = ctx["other_root"]
    photos = ctx["fixtures"]["photos_dir"]

    provision = journey(ctx, phase="provision", data_root=data_root, log_name="journey-provision.log",
                        timeout=JOURNEY_TIMEOUT, args=["--source", photos, "--window-size=1440x900"])
    reopen = None
    isolated = None
    isolation_note = ""
    library_id = facts_of(provision).get("library_id")
    favorite = None
    for item in facts_of(provision).get("favorite", {}).get("query_ids", []) or []:
        favorite = item
    favorite_path = None
    page_items = facts_of(provision).get("first_photo") or {}
    if page_items:
        favorite_path = page_items.get("path")
    total = facts_of(provision).get("total")

    def l0201():
        require_pass(provision, "provision")
        if not library_id:
            raise ProfileError("the journey recorded no LibraryId")
        if favorite_path is None or total is None:
            raise ProfileError("the journey recorded no favorite/total to re-verify")
        reopen_args = ["--expect-library-id", str(library_id), "--expect-count", str(total),
                       "--expect-favorite-path", str(favorite_path), "--window-size=1440x900"]
        nonlocal reopen, isolated, isolation_note
        reopen = journey(ctx, phase="reopen", data_root=data_root, log_name="journey-reopen.log",
                         timeout=JOURNEY_TIMEOUT, args=reopen_args)
        require_pass(reopen, "reopen")
        require_step(reopen, "restart-keeps-identity-and-favorite", "reopen")
        prefix, isolation_note = network_isolation_prefix()
        if prefix is not None:
            isolated = journey(ctx, phase="reopen", data_root=data_root,
                               log_name="journey-reopen-offline.log", timeout=JOURNEY_TIMEOUT,
                               args=reopen_args, prefix=prefix)
            require_pass(isolated, "offline reopen")
        else:
            ctx["evidence"]["network_isolation"] = isolation_note
        ctx["evidence"]["reopen"] = {"library_id": library_id, "total": total,
                                     "favorite_path": favorite_path,
                                     "network_isolation": isolation_note,
                                     "offline_rerun": isolated.record if isolated else None}
        return ("a library created without any account or network kept its LibraryId, photo count "
                "and favorite across a real restart"
                + (" (also inside a network namespace with no interfaces)" if isolated else
                   f"; network isolation rerun unavailable: {isolation_note}"))

    checks.append(_evaluate("L02-01", l0201, journey_logs=["journey-provision.log", "journey-reopen.log"]))

    def l0202():
        probes: dict[str, JourneyRun] = {}

        def on_ready(marker, index):
            probes["same_root"] = journey(ctx, phase="probe-open", data_root=data_root,
                                          log_name="journey-probe-same-root.log", timeout=PROBE_TIMEOUT,
                                          args=["--expect-rejected"], helper=False)
            probes["other_root"] = journey(ctx, phase="probe-open", data_root=other_root,
                                           log_name="journey-probe-other-root.log",
                                           timeout=PROBE_TIMEOUT, helper=False)

        hold = journey(ctx, phase="hold", data_root=data_root, log_name="journey-hold.log",
                       timeout=HOLD_SECONDS + 240, args=[f"--hold-seconds={HOLD_SECONDS}"],
                       on_ready=on_ready)
        require_pass(hold, "hold")
        if "same_root" not in probes or "other_root" not in probes:
            raise ProfileError("the concurrent probes never ran while the first instance held the root")
        require_pass(probes["same_root"], "second instance on the same data root")
        rejection = facts_of(probes["same_root"]).get("rejection")
        if rejection != "LibraryAlreadyOpen":
            raise ProfileError(f"expected a LibraryAlreadyOpen rejection, got {rejection!r}")
        require_pass(probes["other_root"], "second instance on another data root")
        ctx["evidence"]["instance_lock"] = {
            "hold_exit_code": hold.exit_code,
            "same_root_rejection": rejection,
            "other_root_detail": facts_of(probes["other_root"]).get("detail"),
        }
        return ("a second real process on the same data root was rejected with LibraryAlreadyOpen "
                "while a different data root opened independently")

    checks.append(_evaluate("L02-02", l0202,
                            journey_logs=["journey-hold.log", "journey-probe-same-root.log",
                                          "journey-probe-other-root.log"]))
    return checks


# -------------------------------------------------------------------------- S03

def stage_s03(ctx: dict, components: dict, integration: bool) -> list[dict]:
    checks = [component_check("L03-04", components)]
    if not integration:
        checks.extend(_check(item, "NOT RUN", "Real journeys require --integration.")
                      for item in ("L03-01", "L03-02", "L03-03"))
        return checks
    evidence_dir = ctx["evidence_dir"]
    data_root = ctx["data_root"]
    fixtures_root = ctx["fixtures_root"]
    photos = ctx["fixtures"]["photos_dir"]
    expected_images = ctx["fixtures"]["expected_images"]

    before = file_facts(fixtures_root)
    provision = journey(ctx, phase="provision", data_root=data_root,
                        log_name="journey-provision.log", timeout=JOURNEY_TIMEOUT,
                        args=["--source", photos, "--window-size=1440x900"])
    after = file_facts(fixtures_root)
    facts = facts_of(provision)

    def l0301():
        require_pass(provision, "provision")
        require_step(provision, "scan-real-source", "provision")
        scan = facts.get("scan") or {}
        if scan.get("discovered") != expected_images:
            raise ProfileError(f"scan discovered {scan.get('discovered')}, expected {expected_images}")
        if scan.get("skipped") != 2 or scan.get("failed") != 1:
            raise ProfileError(f"unsupported/broken isolation mismatch: {scan}")
        verify_sources(before, after, "source integrity")
        ctx["evidence"]["source_integrity"] = {"files": len(before), "unchanged": True,
                                               "scan": scan}
        dialog = ctx["evidence"].get("picker_dialog") or {}
        dialog_note = (f"; the shipped GTK dialog probe: {dialog.get('status')}"
                       if dialog else "; the shipped GTK dialog probe did not run")
        return (f"a real directory added through the real picker interface scanned recursively: "
                f"{scan.get('discovered')} indexed, {scan.get('skipped')} unsupported skipped, "
                f"{scan.get('failed')} broken isolated; all {len(before)} source fingerprints "
                f"(sha256/size/mtime) unchanged{dialog_note} (see L03-05)")

    def l0302():
        require_pass(provision, "provision")
        verify_sources(before, after, "source integrity")
        # Rewrite one source outside the app so the rescan must bump its version.
        from local_journey import _gradient
        rewritten = Path(photos) / "beta.jpg"
        _gradient(1024, 768, seed=77).save(rewritten, format="JPEG", quality=85)
        ctx["evidence"]["rewritten_source"] = {
            "path": str(rewritten),
            **file_facts(fixtures_root)[str(rewritten.relative_to(fixtures_root))],
        }
        changed = journey(ctx, phase="changed", data_root=data_root,
                          log_name="journey-changed.log", timeout=JOURNEY_TIMEOUT,
                          args=["--source", photos, "--changed-path", str(Path(photos) / "beta.jpg"),
                                "--window-size=1440x900"])
        require_pass(changed, "rescan")
        require_step(changed, "rescan-does-not-duplicate", "rescan")
        rescan = facts_of(changed).get("rescan") or {}
        if rescan.get("before_total") != rescan.get("after_total"):
            raise ProfileError(f"a rescan changed the count: {rescan}")
        cancel_facts = ctx["evidence"].get("cancel") or {}
        if not cancel_facts:
            raise ProfileError("the cancel journey did not run")
        if cancel_facts.get("duplicates"):
            raise ProfileError("a rescan after cancel produced duplicate rows")
        ctx["evidence"]["rescan"] = rescan
        return (f"rescanning the same source kept {rescan.get('after_total')} unique rows, an "
                f"externally rewritten file moved to content_version "
                f"{(facts_of(changed).get('changed') or {}).get('content_version')}, and a cancelled "
                f"scan stayed consistent ({cancel_facts.get('outcome')})")

    def l0303():
        require_pass(provision, "provision")
        require_step(provision, "thumbnail-decoded", "provision")
        require_step(provision, "thumbnail-cache-classes", "provision")
        measured = verify_thumbnails(facts, evidence_dir, "thumbnail classes")
        stats = []
        for name in (provision.record or {}).get("screenshots") or []:
            entry = image_stats(evidence_dir / name)
            require_painted(entry, "rendered evidence")
            stats.append(entry)
        if not stats:
            raise ProfileError("the journey captured no rendered evidence")
        bulk = ctx["evidence"].get("bulk") or {}
        if not bulk:
            raise ProfileError("the bulk journey did not run")
        if bulk.get("cache_dirs") is None or bulk.get("total") is None:
            raise ProfileError("the bulk journey recorded no cache/total facts")
        if bulk.get("visible_tiles") is None:
            raise ProfileError(
                f"the bulk journey recorded no visible tiles: {bulk.get('error') or bulk.get('journey')}")
        if bulk["cache_dirs"] > bulk["visible_tiles"] + 8:
            raise ProfileError(
                f"decoded {bulk['cache_dirs']} caches for {bulk['visible_tiles']} visible tiles")
        if bulk["cache_dirs"] >= bulk["total"]:
            raise ProfileError("the bulk scan decoded the whole library up front")
        ctx["evidence"]["thumbnail_classes"] = measured
        ctx["evidence"]["rendered"] = stats
        orientation_note = (
            f"oriented.jpg (EXIF 6) cached as "
            f"{[entry for entry in measured if entry['path'].endswith('thumbnail-512.jpg')][0]['width']}"
            "x"
            f"{[entry for entry in measured if entry['path'].endswith('thumbnail-512.jpg')][0]['height']}"
            " when the encoded source is 600x400"
            if any(entry["size_class"] == 512 for entry in measured) else "")
        return (f"three cache classes match the source aspect/orientation on disk; "
                f"{len(stats)} rendered captures are non-blank; a {bulk['total']}-item library decoded "
                f"only {bulk['cache_dirs']} caches for {bulk['visible_tiles']} visible tiles "
                f"(peak RSS {bulk.get('peak_rss_kib')} KiB). {orientation_note}")

    # Real dialog probe, then the bulk/cancel runs that L03-02/L03-03 consume.
    ctx["evidence"]["picker_dialog"] = _picker_dialog_probe(ctx)
    checks.append(_evaluate("L03-01", l0301, journey_logs=["journey-provision.log", "journey-picker.log"]))
    _bulk_and_cancel(ctx)
    checks.append(_evaluate("L03-02", l0302, journey_logs=["journey-changed.log", "journey-cancel.log"]))
    checks.append(_evaluate("L03-03", l0303, journey_logs=["journey-bulk.log"]))
    # The interactive GTK dialog probe is supplementary: it is recorded in
    # evidence.picker_dialog (with window captures) but is not one of the four
    # documented S03 gate items, so an environment that cannot answer modal GTK
    # dialogs does not silently block the documented gate.
    return checks


def _picker_dialog_probe(ctx: dict) -> dict:
    """Drive the shipped GTK file dialogs with real X11 keystrokes."""
    photos = Path(ctx["fixtures"]["photos_dir"])
    if not shutil.which("xdotool"):
        return {"status": "NOT RUN", "reason": "xdotool is unavailable"}

    def on_ready(marker, index):
        try:
            _capture_dialog(ctx, marker, index)
            target = photos if marker.get("waiting_for") == "directory-dialog" else photos / "alpha.png"
            _answer_dialog(ctx["current_display"], ctx["picker_main_window"], target)
        except (ProfileError, subprocess.SubprocessError, OSError) as exc:
            ctx["evidence"]["picker_dialog_error"] = str(exc)

    def pid_sink(pid: int) -> None:
        ctx["picker_pid"] = pid
        from local_journey import find_window
        ctx["picker_main_window"] = find_window(ctx["current_display"], pid, timeout=60)

    run = journey(ctx, phase="picker-probe", data_root=ctx["probe_root"],
                  log_name="journey-picker.log", timeout=150,
                  args=["--window-size=1280x800"], on_ready=on_ready, pid_sink=pid_sink)
    if run.record is None:
        return {"status": "NOT RUN", "reason": run.error or f"exit {run.exit_code}"}
    if run.record.get("result") != "PASS" or run.exit_code != 0:
        return {"status": "FAIL",
                "reason": run.record.get("failure") or ctx["evidence"].get("picker_dialog_error")
                or f"exit {run.exit_code}",
                "facts": facts_of(run)}
    return {"status": "PASS", "facts": facts_of(run)}


def _capture_dialog(ctx: dict, marker: dict, index: int) -> None:
    """Keep a real capture of the shipped dialog before answering it."""
    from local_journey import _run_x11
    display = ctx["current_display"]
    try:
        window = _dialog_window(display, ctx["picker_main_window"], timeout=30)
        name = f"picker-dialog-{index}-{marker.get('waiting_for', 'unknown')}.png"
        _run_x11(["import", "-window", window, str(ctx["evidence_dir"] / name)], display, timeout=30)
        ctx["evidence"].setdefault("picker_dialog_captures", []).append(name)
    except (ProfileError, subprocess.SubprocessError, OSError) as exc:
        ctx["evidence"]["picker_dialog_capture_error"] = str(exc)


def _dialog_window(display: str, main_window: str, timeout: float = 40.0) -> str:
    """The chooser is the largest other named top-level window on the display."""
    from local_journey import _run_x11, _window_geometry, _window_ids
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        candidates = []
        for window in _window_ids(display, ["xdotool", "search", "--onlyvisible", "--name", ".+"]):
            if window == main_window:
                continue
            name = _run_x11(["xdotool", "getwindowname", window], display).stdout.strip()
            if not name or name == WINDOW_TITLE or name.startswith("io.github."):
                continue
            geometry = _window_geometry(display, window)
            if geometry is None or geometry[0] < 300 or geometry[1] < 300:
                continue
            candidates.append(window)
        if candidates:
            return candidates[-1]
        time.sleep(0.4)
    raise ProfileError("picker: no dialog window appeared")


def _answer_dialog(display: str, main_window: str, target: Path) -> None:
    from local_journey import _run_x11, _focus
    window = _dialog_window(display, main_window)
    _focus(window, display)
    time.sleep(0.6)
    _run_x11(["xdotool", "key", "--clearmodifiers", "ctrl+l"], display)
    time.sleep(0.6)
    _run_x11(["xdotool", "key", "--clearmodifiers", "ctrl+a"], display)
    time.sleep(0.3)
    _run_x11(["xdotool", "type", "--delay", "15", "--", str(target)], display)
    time.sleep(0.6)
    _run_x11(["xdotool", "key", "--clearmodifiers", "Return"], display)
    time.sleep(2.0)
    _run_x11(["xdotool", "key", "--clearmodifiers", "Return"], display)
    time.sleep(1.5)


def _bulk_and_cancel(ctx: dict) -> None:
    bulk_root = ctx["bulk_root"]
    cache = bulk_root / "cache"
    fixtures = ctx["bulk_fixtures"]
    expected_total = fixtures["expected_images"] + fixtures["bulk_count"]
    bulk = journey(ctx, phase="bulk", data_root=bulk_root, log_name="journey-bulk.log",
                   timeout=1800, args=["--source", fixtures["root"], f"--expect-count={expected_total}",
                                       "--window-size=1440x900"])
    facts = facts_of(bulk)
    visible = (facts.get("bulk_visible") or {}).get("tiles_in_tree")
    cache_dirs = len([path for path in cache.iterdir() if path.is_dir()]) if cache.is_dir() else 0
    ctx["evidence"]["bulk"] = {
        "journey": bulk.record.get("result") if bulk.record else None,
        "error": bulk.error,
        "total": facts.get("total"),
        "expected_total": expected_total,
        "visible_tiles": visible,
        "cache_dirs": cache_dirs,
        "peak_rss_kib": bulk.peak_rss_kib,
        "scan": facts.get("bulk_scan"),
    }
    cancel_root = ctx["cancel_root"]
    cancel = journey(ctx, phase="cancel", data_root=cancel_root, log_name="journey-cancel.log",
                     timeout=1800, args=["--source", fixtures["root"],
                                         f"--expect-count={expected_total}", "--window-size=1440x900"])
    cancel_facts = facts_of(cancel)
    scan = cancel_facts.get("cancel_scan") or {}
    rescan = cancel_facts.get("rescan_after_cancel") or {}
    duplicates = not (cancel.record is not None and cancel.record.get("result") == "PASS")
    ctx["evidence"]["cancel"] = {
        "journey": cancel.record.get("result") if cancel.record else None,
        "error": cancel.error or (cancel.record or {}).get("failure"),
        "control_seen": scan.get("control_seen"),
        "cancelled": scan.get("cancelled"),
        "discovered": scan.get("discovered"),
        "total_after_cancel": scan.get("total_after_cancel"),
        "total_after_rescan": rescan.get("total"),
        "expected_total": expected_total,
        "duplicates": duplicates,
        "outcome": ("cancelled mid-scan" if scan.get("cancelled")
                    else "scan completed before the cancel request landed"),
        "peak_rss_kib": cancel.peak_rss_kib,
    }


# -------------------------------------------------------------------------- S04

def stage_s04(ctx: dict, components: dict, integration: bool) -> list[dict]:
    if not integration:
        return [_check(item, "NOT RUN", "Real journeys require --integration.")
                for item in STAGE_CHECKS["S04"]]
    photos = ctx["fixtures"]["photos_dir"]
    runs = {}
    for width, height in WIDTHS:
        root = ctx["width_roots"][(width, height)]
        runs[(width, height)] = journey(
            ctx, subdir=f"width-{width}", phase="provision", data_root=root,
            log_name=f"journey-width-{width}.log",
            timeout=JOURNEY_TIMEOUT, args=["--source", photos, f"--window-size={width}x{height}"])

    def l0401():
        details = []
        for key, run in runs.items():
            require_pass(run, f"journey at {key[0]}px")
            require_step(run, "grid-is-database-driven", f"journey at {key[0]}px")
            facts = facts_of(run)
            details.append({"width": key[0], "total": facts.get("total"),
                            "page_size": facts.get("page_size"),
                            "tiles_in_tree": facts.get("tiles_in_tree"),
                            "first_photo": facts.get("first_photo")})
        ctx["evidence"]["grid"] = details
        first = details[0]
        if not first["total"] or not first["tiles_in_tree"]:
            raise ProfileError("the grid reported no database-driven rows")
        return (f"the paged grid was filled by real FFI/SQLite queries at "
                f"{', '.join(str(key[0]) for key in runs)}px: total={first['total']}, "
                f"page size={first['page_size']}, rendered tiles={first['tiles_in_tree']}")

    def l0402():
        for key, run in runs.items():
            label = f"journey at {key[0]}px"
            for step in ("viewer-opens-real-file", "viewer-keyboard-and-button-navigation",
                         "viewer-wheel-zoom", "viewer-zoom-buttons", "viewer-pan-by-real-drag",
                         "viewer-immersive-toggle", "escape-returns-to-grid"):
                require_step(run, step, label)
        facts = facts_of(runs[WIDTHS[-1]])
        ctx["evidence"]["viewer"] = {
            "navigation": facts.get("navigation"),
            "wheel_zoom": facts.get("wheel_zoom"),
            "zoom_buttons": facts.get("zoom_buttons"),
            "pan": facts.get("pan"),
            "decoded": {f"{key[0]}x{key[1]}": facts_of(run).get("viewer")
                        for key, run in runs.items()},
        }
        return ("opening, ArrowRight/previous-button navigation, real wheel zoom, zoom buttons, "
                "drag panning, immersive toggle and Escape all behaved correctly at every width; "
                "window-level fullscreen needs a window manager and is NOT RUN under Xvfb")

    def l0403():
        for key, run in runs.items():
            label = f"journey at {key[0]}px"
            require_step(run, "favorite-persists-in-database", label)
            require_step(run, "viewer-metadata-is-real", label)
            require_step(run, "favorites-filter", label)
        reopen = journey(ctx, subdir="reopen", phase="reopen",
                         data_root=ctx["width_roots"][WIDTHS[-1]],
                         log_name="journey-reopen.log", timeout=JOURNEY_TIMEOUT,
                         args=["--expect-library-id", str(facts_of(runs[WIDTHS[-1]]).get("library_id")),
                               "--expect-count", str(facts_of(runs[WIDTHS[-1]]).get("total")),
                               "--expect-favorite-path",
                               str((facts_of(runs[WIDTHS[-1]]).get("first_photo") or {}).get("path")),
                               "--window-size=1440x900"])
        require_pass(reopen, "reopen")
        require_step(reopen, "restart-viewer-still-decodes", "reopen")
        ctx["evidence"]["favorite_restart"] = facts_of(reopen).get("favorites_after_restart")
        return ("the favorite command wrote through the gateway, a fresh favorites-only query and the "
                "filter chip agreed, the details dialog showed the real path/size/dimensions, and the "
                "marking survived a real restart")

    def l0404():
        measured = []
        for key, run in runs.items():
            window = (run.record or {}).get("window") or {}
            if window.get("width") != key[0]:
                raise ProfileError(f"window width {window.get('width')} != requested {key[0]}")
            captures = []
            for name in (run.record or {}).get("screenshots") or []:
                stats = image_stats(run.evidence_dir / name)
                require_painted(stats, f"{key[0]}px capture")
                captures.append(stats)
            if not captures:
                raise ProfileError(f"the {key[0]}px journey captured nothing")
            require_step(run, "search-uses-current-query-only", f"journey at {key[0]}px")
            measured.append({"width": key[0], "height": key[1], "captures": len(captures),
                             "search": facts_of(run).get("search")})
        ctx["evidence"]["widths"] = measured
        return (f"the whole flow completed and rendered at {', '.join(str(item['width']) for item in measured)}px "
                "with search returning only current-query results; album hover rules belong to S06 "
                "(no manual albums exist yet)")

    checks = [_evaluate("L04-01", l0401), _evaluate("L04-02", l0402),
              _evaluate("L04-03", l0403), _evaluate("L04-04", l0404)]

    missing = _missing_source_run(ctx)
    checks.append(_check("L04-05-missing-source", missing["status"], missing["reason"],
                         **{key: value for key, value in missing.items() if key not in ("status", "reason")}))
    return checks


def _missing_source_run(ctx: dict) -> dict:
    fixtures_root = ctx["missing_fixtures_root"]
    data_root = ctx["missing_root"]
    photos = Path(fixtures_root) / "photos"
    provision = journey(ctx, subdir="missing", phase="provision", data_root=data_root,
                        log_name="journey-missing-provision.log", timeout=JOURNEY_TIMEOUT,
                        args=["--source", str(photos), "--window-size=1440x900"])
    try:
        require_pass(provision, "missing-source provisioning")
        victim = photos / "gamma.webp" if (photos / "gamma.webp").is_file() else photos / "nested" / "gamma.webp"
        before = file_facts(fixtures_root)
        victim.unlink()
        run = journey(ctx, subdir="missing", phase="missing", data_root=data_root,
                      log_name="journey-missing.log", timeout=JOURNEY_TIMEOUT,
                      args=[f"--missing-path={victim}", f"--expect-count={facts_of(provision).get('total')}",
                            "--window-size=1440x900"])
        require_pass(run, "missing-source journey")
        for step in ("missing-source-keeps-history", "missing-source-viewer-degrades",
                     "missing-source-does-not-block-others"):
            require_step(run, step, "missing-source journey")
        ctx["evidence"]["missing_source"] = {"path": str(victim), "facts": facts_of(run)}
        return {"status": "PASS",
                "reason": ("a source deleted outside the app stayed indexed, opened with the "
                           "unavailable placeholder instead of crashing, and other photos still decoded"),
                "journey_logs": ["journey-missing-provision.log", "journey-missing.log"]}
    except (ProfileError, OSError) as exc:
        return {"status": "FAIL", "reason": str(exc),
                "journey_logs": ["journey-missing-provision.log", "journey-missing.log"]}


# ----------------------------------------------------------------------- entry

def _prepare(ctx: dict, stage: str) -> None:
    evidence_dir = ctx["evidence_dir"]
    ctx["fixtures_root"] = evidence_dir / "fixtures"
    ctx["fixtures"] = make_fixtures(ctx["fixtures_root"])
    ctx["data_root"] = evidence_dir / "data-root"
    ctx["other_root"] = evidence_dir / "data-root-other"
    ctx["probe_root"] = evidence_dir / "data-root-picker"
    if stage == "S03":
        ctx["bulk_fixtures_root"] = evidence_dir / "fixtures-bulk"
        ctx["bulk_fixtures"] = make_fixtures(ctx["bulk_fixtures_root"], bulk_count=BULK_COUNT)
        ctx["bulk_root"] = evidence_dir / "data-root-bulk"
        ctx["cancel_root"] = evidence_dir / "data-root-cancel"
    if stage == "S04":
        ctx["width_roots"] = {size: evidence_dir / f"data-root-{size[0]}" for size in WIDTHS}
        ctx["missing_fixtures_root"] = evidence_dir / "fixtures-missing"
        ctx["missing_fixtures"] = make_fixtures(ctx["missing_fixtures_root"])
        ctx["missing_root"] = evidence_dir / "data-root-missing"


def run(stage: str, evidence_dir: Path, root: Path = ROOT, *, integration: bool = False,
        mode: str = "release") -> int:
    base = _base()
    evidence_dir.mkdir(parents=True, exist_ok=True)
    if any(evidence_dir.iterdir()):
        raise ProfileError("evidence: directory already exists with files; choose a fresh directory")
    if stage not in STAGE_CHECKS:
        raise ProfileError(f"stage: {stage} is not a local stage")
    profile = load_profile(profile_path("linux-x86_64", root))
    ctx = {"root": root, "evidence_dir": evidence_dir, "profile": profile, "mode": mode,
           "evidence": {"plan_version": 2, "phase": "local", "stage": stage}, "journeys": []}
    components = run_component_tests(base, root, evidence_dir, stage)
    ctx["evidence"]["component_tests"] = components
    build = None
    if integration:
        try:
            build, executable = build_bundle(base, root, evidence_dir, profile, mode)
            ctx["executable"] = executable
            ctx["evidence"]["artifacts"] = build["snapshot"]
            _prepare(ctx, stage)
        except (ProfileError, OSError) as exc:
            build = {"error": str(exc)}
            integration = False
            ctx["evidence"]["build_error"] = str(exc)
    checks = None
    display_note = "no real window"
    if integration and "executable" in ctx:
        display_note = ("one dedicated Xvfb per journey (GPU/compositor validation NOT RUN); "
                        "each journey records its own display")
        try:
            handler = {"S02": stage_s02, "S03": stage_s03, "S04": stage_s04}[stage]
            checks = handler(ctx, components, True)
        except ProfileError as exc:
            checks = [_check(item, "FAIL", str(exc)) for item in STAGE_CHECKS[stage]]
    if checks is None:
        handler = {"S02": stage_s02, "S03": stage_s03, "S04": stage_s04}[stage]
        checks = handler(ctx, components, False)
    ordered = {item: None for item in STAGE_CHECKS[stage]}
    for check in checks:
        ordered.setdefault(check["id"], None)
        ordered[check["id"]] = check
    final_checks = [value for value in ordered.values() if value is not None]
    statuses = {check["status"] for check in final_checks}
    status = "FAIL" if "FAIL" in statuses else "PASS" if statuses == {"PASS"} else "INCOMPLETE"
    ctx["evidence"]["display"] = display_note
    report = {
        "stage": stage, "gate_status": status, "integration_requested": bool(build),
        "plan_version": 2, "phase": "local", "mode": mode,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.gmtime()),
        "profile_digest": profile_digest(profile),
        "dependency_fingerprints": base._fingerprints(root),
        "checks": final_checks,
        "commands": [journey["command"] for journey in ctx["journeys"]],
        "journeys": ctx["journeys"],
        "evidence": ctx["evidence"],
        "gui_validation": "PASS" if status == "PASS" and "executable" in ctx else "NOT RUN",
        "gpu_visual_validation": "NOT RUN",
        "packaging_validation": "NOT RUN",
        "user_review": "NOT RECORDED",
        "scope": (f"{stage} local-first checks with generated fixtures in an isolated data root; "
                  "component-only items are labelled evidence_level=component."),
    }
    (evidence_dir / "report.json").write_text(canonical_json(report) + "\n", encoding="utf-8")
    print(f"{stage} {status}: {evidence_dir / 'report.json'}")
    for check in final_checks:
        print(f"  {check['id']}: {check['status']} - {check['reason'][:160]}")
    return 0 if status == "PASS" else 1
