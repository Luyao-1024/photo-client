"""Mechanics for real local-library acceptance: fixtures, display, input, records.

Every journey runs the shipped executable in a real window against an isolated
data root and generated fixtures. Nothing here reads the user's photo
collection, and no journey result is inferred from an exit code alone.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

from platform_config import ProfileError

JOURNEY_PREFIX = "PHOTO_CLIENT_LOCAL "
READY_PREFIX = "PHOTO_CLIENT_LOCAL_READY "
WINDOW_TITLE = "photo_client"
REQUEST_NAME = "input-request.json"
RESPONSE_NAME = "input-response.json"

FIXTURE_IMAGES = {
    # name: (format, width, height, exif_orientation)
    "alpha.png": ("PNG", 640, 480, 1),
    "beta.jpg": ("JPEG", 800, 600, 1),
    "nested/gamma.webp": ("WEBP", 320, 240, 1),
    "oriented.jpg": ("JPEG", 600, 400, 6),
    "small.png": ("PNG", 32, 32, 1),
    "large.jpg": ("JPEG", 1600, 1200, 1),
}
UNSUPPORTED_FILE = "notes.txt"
BROKEN_FILE = "broken.jpg"
SYMLINK_FILE = "link.png"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_facts(root: Path) -> dict[str, dict]:
    """Content and metadata fingerprints for every regular file under root."""
    facts = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        stat = path.stat()
        facts[str(path.relative_to(root))] = {
            "sha256": _sha256(path),
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
        }
    return facts


def _gradient(width: int, height: int, seed: int):
    from PIL import Image

    image = Image.new("RGB", (width, height))
    pixels = image.load()
    step_x = max(1, width // 64)
    step_y = max(1, height // 64)
    for y in range(0, height, step_y):
        for x in range(0, width, step_x):
            color = (
                (x * 3 + seed * 37) % 256,
                (y * 5 + seed * 91) % 256,
                ((x + y) * 2 + seed * 13) % 256,
            )
            for dy in range(step_y):
                for dx in range(step_x):
                    if y + dy < height and x + dx < width:
                        pixels[x + dx, y + dy] = color
    return image


def make_fixtures(root: Path, *, bulk_count: int = 0) -> dict:
    """Create an isolated synthetic photo tree and describe the expected scan."""
    try:
        from PIL import Image
    except ModuleNotFoundError as exc:  # pragma: no cover - environment guard
        raise ProfileError("fixtures: Pillow is required for journey fixtures") from exc
    if root.exists() and any(root.iterdir()):
        raise ProfileError(f"fixtures: {root} is not empty")
    photos = root / "photos"
    (photos / "nested").mkdir(parents=True)
    for name, (fmt, width, height, orientation) in FIXTURE_IMAGES.items():
        image = _gradient(width, height, seed=abs(hash(name)) % 97)
        target = photos / name
        if fmt == "JPEG":
            if orientation != 1:
                exif = Image.Exif()
                exif[274] = orientation
                image.save(target, format=fmt, quality=88, exif=exif)
            else:
                image.save(target, format=fmt, quality=88)
        else:
            image.save(target, format=fmt)
    (photos / UNSUPPORTED_FILE).write_text("not an image\n", encoding="utf-8")
    (photos / BROKEN_FILE).write_bytes(b"\xff\xd8\xff\xe0broken-payload")
    (photos / SYMLINK_FILE).symlink_to(photos / "alpha.png")
    if bulk_count:
        bulk = root / "bulk"
        bulk.mkdir()
        tiny = _gradient(16, 16, seed=3)
        for index in range(bulk_count):
            tiny.save(bulk / f"tiny-{index:05d}.png", format="PNG")
    return {
        "root": str(root),
        "photos_dir": str(photos),
        "expected_images": len(FIXTURE_IMAGES),
        "expected_skipped": 2,
        "expected_failed": 1,
        "bulk_count": bulk_count,
        "images": {
            name: {"format": fmt, "width": width, "height": height, "orientation": orientation}
            for name, (fmt, width, height, orientation) in FIXTURE_IMAGES.items()
        },
    }


def expected_thumbnail_size(width: int, height: int, orientation: int, size_class: int) -> tuple[int, int]:
    """Mirror the native aspect/orientation rules for cache verification."""
    longest = max(width, height)
    if longest <= size_class:
        target = (width, height)
    else:
        target = (max(1, width * size_class // longest), max(1, height * size_class // longest))
    if orientation in (5, 6, 7, 8):
        return target[1], target[0]
    return target


class XvfbDisplay:
    """A dedicated X server so injected input never reaches the user session."""

    def __init__(self, screen: str = "1440x900x24"):
        self.screen = screen
        self.display: str | None = None
        self._process: subprocess.Popen | None = None

    def __enter__(self) -> str:
        xvfb = shutil.which("Xvfb")
        if not xvfb:
            raise ProfileError("display: Xvfb is required for real input journeys")
        for number in range(99, 89, -1):
            display = f":{number}"
            if Path(f"/tmp/.X{number}-lock").exists():
                continue
            process = subprocess.Popen(
                [xvfb, display, "-screen", "0", self.screen, "-nolisten", "tcp"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
            )
            time.sleep(1.2)
            if process.poll() is not None:
                continue
            self._process = process
            self.display = display
            return display
        raise ProfileError("display: no free X display in :90..:99")

    def __exit__(self, *_exc) -> None:
        process = self._process
        if process is None:
            return
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            process.wait(timeout=5)
        except (ProcessLookupError, subprocess.TimeoutExpired, OSError):
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except (ProcessLookupError, OSError):
                pass


def _run_x11(command: list[str], display: str, timeout: int = 20) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["DISPLAY"] = display
    return subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout)


def _move_pointer(window: str, display: str, x: int, y: int) -> None:
    """Warp the pointer without `--sync`.

    `xdotool mousemove --sync` blocks until the server reports a motion; a
    repeat tap on the same point would stall for its full timeout. XTest
    requests are ordered, so a plain warp followed by a short settle keeps the
    subsequent click at the requested position.
    """
    _run_x11(["xdotool", "mousemove", "--window", window, str(x), str(y)], display)
    time.sleep(0.02)


def find_window(display: str, timeout: float = 30.0) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = _run_x11(["xdotool", "search", "--name", WINDOW_TITLE], display)
        ids = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if ids:
            return ids[0]
        time.sleep(0.25)
    raise ProfileError("input: no application window appeared on the test display")


def _focus(window: str, display: str) -> None:
    for command in (["xdotool", "windowactivate", "--sync", window],
                    ["xdotool", "windowfocus", "--sync", window]):
        try:
            _run_x11(command, display, timeout=10)
            return
        except (subprocess.SubprocessError, OSError):
            continue


class X11InputHelper:
    """Answers the app's input handshake with real XTest events."""

    def __init__(self, evidence_dir: Path, display: str):
        self.evidence_dir = evidence_dir
        self.display = display
        self.request = evidence_dir / REQUEST_NAME
        self.response = evidence_dir / RESPONSE_NAME
        self.window: str | None = None
        self.actions: list[dict] = []
        for tool in ("xdotool",):
            if not shutil.which(tool):
                raise ProfileError(f"input: {tool} is required for --input=x11 journeys")

    def _window_id(self) -> str:
        if self.window is None:
            self.window = find_window(self.display)
            _focus(self.window, self.display)
        return self.window

    def _respond(self, step: int, status: str, detail: str = "") -> None:
        staged = self.response.with_suffix(".tmp")
        staged.write_text(json.dumps({"step": step, "status": status, "detail": detail}),
                          encoding="utf-8")
        staged.replace(self.response)

    def poll_once(self) -> bool:
        """Handle at most one pending request; return whether one was handled."""
        if not self.request.exists():
            return False
        try:
            payload = json.loads(self.request.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            return False
        step = payload.get("step")
        self.request.unlink(missing_ok=True)
        try:
            detail = self._dispatch(payload)
        except (ProfileError, subprocess.SubprocessError, OSError) as exc:
            self._respond(step, "error", str(exc))
            self.actions.append({"step": step, "kind": payload.get("kind"), "status": "error",
                                 "detail": str(exc)})
            return True
        self._respond(step, "ok", detail)
        self.actions.append({"step": step, "kind": payload.get("kind"), "status": "ok",
                             "detail": detail, "payload": payload})
        return True

    def _scaled(self, payload: dict, axis: str) -> int:
        ratio = float(payload.get("device_pixel_ratio") or 1.0)
        return int(round(float(payload[axis]) * ratio))

    def _dispatch(self, payload: dict) -> str:
        kind = payload.get("kind")
        window = self._window_id()
        if kind == "tap":
            x, y = self._scaled(payload, "x"), self._scaled(payload, "y")
            _focus(window, self.display)
            _move_pointer(window, self.display, x, y)
            # A zero-duration press (down+up back-to-back) is not recognised as
            # a tap by the gesture arena under XTest; hold like a real click.
            time.sleep(0.05)
            _run_x11(["xdotool", "mousedown", "1"], self.display)
            time.sleep(0.12)
            _run_x11(["xdotool", "mouseup", "1"], self.display)
            return f"click at {x},{y}"
        if kind == "secondary-tap":
            x, y = self._scaled(payload, "x"), self._scaled(payload, "y")
            _focus(window, self.display)
            _move_pointer(window, self.display, x, y)
            time.sleep(0.05)
            _run_x11(["xdotool", "click", "3"], self.display)
            return f"right click at {x},{y}"
        if kind == "move":
            x, y = self._scaled(payload, "x"), self._scaled(payload, "y")
            _move_pointer(window, self.display, x, y)
            return f"move to {x},{y}"
        if kind == "drag":
            x1, y1 = self._scaled(payload, "x"), self._scaled(payload, "y")
            x2 = int(round(float(payload["to_x"]) * float(payload.get("device_pixel_ratio") or 1.0)))
            y2 = int(round(float(payload["to_y"]) * float(payload.get("device_pixel_ratio") or 1.0)))
            _focus(window, self.display)
            _move_pointer(window, self.display, x1, y1)
            _run_x11(["xdotool", "mousedown", "1"], self.display)
            hold_ms = int(payload.get("hold_ms") or 0)
            if hold_ms > 0:
                time.sleep(hold_ms / 1000)
            for step in range(1, 9):
                _move_pointer(window, self.display,
                              x1 + (x2 - x1) * step // 8,
                              y1 + (y2 - y1) * step // 8)
                time.sleep(0.02)
            _run_x11(["xdotool", "mouseup", "1"], self.display)
            return f"drag {x1},{y1} to {x2},{y2}"
        if kind == "scroll":
            x, y = self._scaled(payload, "x"), self._scaled(payload, "y")
            button = "4" if int(payload.get("clicks", 1)) > 0 else "5"
            _focus(window, self.display)
            _move_pointer(window, self.display, x, y)
            for _ in range(abs(int(payload.get("clicks", 1)))):
                _run_x11(["xdotool", "click", button], self.display)
                time.sleep(0.05)
            return f"scroll button {button}"
        if kind == "key":
            _focus(window, self.display)
            result = _run_x11(
                ["xdotool", "key", "--clearmodifiers", str(payload["key"])],
                self.display,
            )
            # xdotool exits 0 after ignoring an unknown keysym, which used to
            # turn a typo such as "escape" into a silent, falsely ACKed step.
            if result.returncode != 0 or "No such key name" in result.stderr:
                raise ProfileError(
                    f"input: xdotool rejected key {payload['key']!r}: "
                    f"{result.stderr.strip() or result.returncode}"
                )
            return f"key {payload['key']}"
        if kind == "text":
            _focus(window, self.display)
            _run_x11(["xdotool", "type", "--delay", "80", "--", str(payload["text"])], self.display)
            return f"typed {len(str(payload['text']))} characters"
        if kind == "screenshot":
            if not shutil.which("import"):
                raise ProfileError("screenshot: ImageMagick import is unavailable")
            target = self.evidence_dir / f"{payload['name']}-x11.png"
            _run_x11(["import", "-window", window, str(target)], self.display, timeout=30)
            if not target.is_file() or target.stat().st_size == 0:
                raise ProfileError(f"screenshot: {target.name} was not written")
            return target.name
        raise ProfileError(f"input: unsupported request kind {kind!r}")


def _unique_json_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate journey field: {key}")
        result[key] = value
    return result


def parse_record(output: str, *, prefix: str = JOURNEY_PREFIX) -> dict:
    lines = [line for line in output.splitlines() if line.startswith(prefix)]
    if len(lines) != 1:
        raise ProfileError(f"journey: expected exactly one {prefix.strip()} record, got {len(lines)}")
    try:
        record = json.loads(lines[0][len(prefix):], object_pairs_hook=_unique_json_object)
    except (ValueError, RecursionError) as exc:
        raise ProfileError("journey: invalid or ambiguous JSON record") from exc
    if type(record) is not dict:
        raise ProfileError("journey: record is not an object")
    return record


class JourneyRun:
    """One application process, its log, and the record it published."""

    def __init__(self, command: list[str], log_path: Path, exit_code: int | None,
                 timed_out: bool, elapsed: float, record: dict | None,
                 ready: dict | None, actions: list[dict], error: str | None = None):
        self.command = command
        self.log_path = log_path
        self.exit_code = exit_code
        self.timed_out = timed_out
        self.elapsed = elapsed
        self.record = record
        self.ready = ready
        self.actions = actions
        self.error = error

    def as_evidence(self, root: Path) -> dict:
        return {
            "command": [str(part) for part in self.command],
            "cwd": str(self.log_path.parent),
            "log": self.log_path.name,
            "exit_code": self.exit_code,
            "timed_out": self.timed_out,
            "elapsed_seconds": self.elapsed,
            "record": self.record,
            "ready": self.ready,
            "input_actions": len(self.actions),
            **({"error": self.error} if self.error else {}),
        }


def run_journey(executable: Path, *, display: str, phase: str, data_root: Path,
                evidence_dir: Path, log_name: str, timeout: int,
                args: list[str] | None = None, helper: bool = True,
                on_ready=None, env_extra: dict[str, str] | None = None) -> JourneyRun:
    """Run one journey phase and service its real-input handshake."""
    evidence_dir.mkdir(parents=True, exist_ok=True)
    for name in (REQUEST_NAME, RESPONSE_NAME):
        (evidence_dir / name).unlink(missing_ok=True)
    command = [str(executable), "--local-journey", f"--journey-phase={phase}",
               f"--data-root={data_root}", f"--evidence-dir={evidence_dir}",
               f"--input={'x11' if helper else 'framework'}", *(args or [])]
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    env["DISPLAY"] = display
    env["GDK_BACKEND"] = "x11"
    # A desktop input method (fcitx/ibus) treats injected keys as composition
    # and can swallow Escape/F-keys; the journey needs raw key delivery.
    env.update({
        "GTK_IM_MODULE": "gtk-im-context-simple",
        "QT_IM_MODULE": "simple",
        "SDL_IM_MODULE": "simple",
        "XMODIFIERS": "@im=none",
        "INPUT_METHOD": "simple",
    })
    # Keep the journey off the user's session bus and any network namespace.
    env.pop("DBUS_SESSION_BUS_ADDRESS", None)
    log_path = evidence_dir / log_name
    helper_driver = X11InputHelper(evidence_dir, display) if helper else None
    started = time.monotonic()
    record = None
    ready = None
    error = None
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, cwd=executable.parent, stdout=log,
                                   stderr=subprocess.STDOUT, env=env, start_new_session=True)
        deadline = started + timeout
        notified = False
        try:
            while time.monotonic() < deadline:
                if helper_driver is not None:
                    helper_driver.poll_once()
                if ready is None and log_path.exists():
                    text = log_path.read_text(encoding="utf-8", errors="replace")
                    for line in text.splitlines():
                        if line.startswith(READY_PREFIX):
                            try:
                                ready = json.loads(line[len(READY_PREFIX):])
                            except ValueError:
                                ready = {"parse_error": True}
                    if ready is not None and not notified:
                        notified = True
                        if on_ready is not None:
                            on_ready()
                if process.poll() is not None:
                    # Drain any final handshake requests before giving up.
                    for _ in range(4):
                        if helper_driver is not None and not helper_driver.poll_once():
                            break
                        time.sleep(0.1)
                    break
                time.sleep(0.05)
            else:
                error = f"journey timed out after {timeout} seconds"
            if process.poll() is None:
                try:
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                except (ProcessLookupError, OSError):
                    pass
            exit_code = process.wait(timeout=15)
        except (OSError, subprocess.SubprocessError) as exc:
            error = f"journey execution error: {exc}"
            exit_code = process.poll()
    text = log_path.read_text(encoding="utf-8", errors="replace")
    if record is None:
        try:
            record = parse_record(text)
        except ProfileError as exc:
            error = error or str(exc)
    return JourneyRun(command, log_path, exit_code, error is not None and "timed out" in error,
                      round(time.monotonic() - started, 3), record, ready,
                      helper_driver.actions if helper_driver else [], error)
