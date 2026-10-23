"""End-to-end cloud acceptance: real SyncServer, real library data, real window.

Every phase runs the shipped release bundle over real FFI, SQLite, files and a
real X11 window (Xvfb). The client roots are snapshots of the user's actual
library database, so the photos and metadata are real; the copies keep cloud
binding and uploads from modifying the user's working library.

Nothing here substitutes a fake gateway: the server is the real SyncServer
binary from the adjacent checkout and the journeys speak to it over HTTP.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.request

from local_journey import XvfbDisplay, run_journey
from platform_config import ROOT

SERVER_ROOT = ROOT.parent / "syncserver"
SERVER_BIN = SERVER_ROOT / "target/release/syncserver"
APP_BIN = ROOT / "app/build/linux/x64/release/bundle/photo_client"
DEFAULT_LIBRARY = (
    Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
    / "photo-client/library/library.sqlite"
)
PHASE_TIMEOUT = 900
SERVER_START_TIMEOUT = 30
SERVER_STOP_TIMEOUT = 15


class CloudJourneyError(Exception):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def b64_digest(path: Path) -> str:
    return base64.b64encode(bytes.fromhex(sha256_file(path))).decode()


def validate_evidence_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    if any(path.iterdir()):
        raise CloudJourneyError(
            "evidence: directory already exists with files; choose a fresh directory"
        )
    return path


def snapshot_library(source: Path, destination: Path) -> Path:
    """Copy one consistent library database through SQLite's backup API."""
    if not source.is_file():
        raise CloudJourneyError(f"library: {source} does not exist")
    target = destination / "library.sqlite"
    target.parent.mkdir(parents=True, exist_ok=True)
    source_uri = f"file:{source}?mode=ro"
    with sqlite3.connect(source_uri, uri=True) as origin:
        with sqlite3.connect(target) as copy:
            origin.backup(copy)
            copy.execute("PRAGMA journal_mode=DELETE")
    return target


def _active_rows(database: Path, sql: str):
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        return connection.execute(sql).fetchall()


def choose_albums(database: Path) -> dict[str, str]:
    """Pick three real one-photo albums for batch, single and offline uploads.

    The choices are data driven, not fixture names: a one-photo album proves that
    an upload never widens beyond the explicit selection.
    """
    rows = _active_rows(
        database,
        "SELECT parent_uri, source_uri, mime_type, size_bytes "
        "FROM media WHERE state='active' AND media_kind='image' "
        "AND parent_uri<>'' ORDER BY parent_uri, sort_time_ms DESC",
    )
    by_album: dict[str, list[tuple[str, str, int]]] = {}
    for parent, source, mime, size in rows:
        by_album.setdefault(parent, []).append((source, mime, size))
    candidates = []
    for parent, photos in sorted(by_album.items()):
        if len(photos) != 1:
            continue
        source, mime, size = photos[0]
        if mime not in ("image/jpeg", "image/png"):
            continue
        if size > 16 * 1024 * 1024:
            continue
        if not Path(source).is_file():
            continue
        candidates.append((parent, mime, size, source))
    jpeg = [item for item in candidates if item[1] == "image/jpeg"]
    png = [item for item in candidates if item[1] == "image/png"]
    if not jpeg or len(candidates) < 3:
        raise CloudJourneyError(
            "albums: the real library needs three single-photo JPEG/PNG albums"
        )
    batch = min(jpeg, key=lambda item: item[2])
    remainder = [item for item in candidates if item[0] != batch[0]]
    single = next((item for item in remainder if item[1] == "image/png"), remainder[0])
    extra = next(item for item in remainder if item[0] != single[0])
    return {
        "batch": batch[0],
        "single": single[0],
        "extra": extra[0],
    }


def ensure_library_is_fresh(database: Path) -> int:
    count, = _active_rows(database, "SELECT COUNT(*) FROM media WHERE state='active'")[0]
    cloud = _active_rows(database, "SELECT COUNT(*) FROM cloud_accounts")[0][0]
    if cloud:
        raise CloudJourneyError(
            "library: the real library is already signed in to a cloud account; "
            "the snapshot must start signed out"
        )
    return count


def build_app() -> dict:
    env = os.environ.copy()
    if not env.get("PHOTO_FLUTTER_ROOT"):
        default = Path.home() / ".local/share/photo-client/flutter"
        if (default / "bin/flutter").is_file():
            env["PHOTO_FLUTTER_ROOT"] = str(default)
    command = [sys.executable, "-B", str(ROOT / "tools/platform"), "build",
               "--profile", "linux-x86_64", "--mode", "release"]
    started = time.monotonic()
    process = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
    return {
        "command": command,
        "exit_code": process.returncode,
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "stdout": process.stdout[-8000:],
        "stderr": process.stderr[-8000:],
    }


def build_server() -> dict:
    command = ["cargo", "build", "--release", "--locked"]
    started = time.monotonic()
    process = subprocess.run(command, cwd=SERVER_ROOT, capture_output=True, text=True)
    if process.returncode != 0:
        raise CloudJourneyError(f"server build failed: {process.stderr[-2000:]}")
    return {
        "command": command,
        "exit_code": process.returncode,
        "elapsed_seconds": round(time.monotonic() - started, 3),
    }


class SyncServer:
    def __init__(self, root: Path, port: int, password: str, user: str = "e2e"):
        self.root = root
        self.port = port
        self.user = user
        self.password = password
        self.process: subprocess.Popen | None = None
        self.log_path = root / "server.log"
        self.base_url = f"http://127.0.0.1:{port}"

    def prepare(self) -> dict:
        self.root.mkdir(parents=True, exist_ok=True)
        data = self.root / "data"
        data.mkdir(mode=0o700, exist_ok=True)
        key = self.root / "signing.key"
        if not key.exists():
            key.write_text(base64.b64encode(secrets.token_bytes(32)).decode() + "\n")
            key.chmod(0o600)
        env = self.env()
        create = subprocess.run(
            [str(SERVER_BIN), "users", "create", self.user, "--password-stdin"],
            env=env, input=self.password + "\n", text=True, capture_output=True,
        )
        if create.returncode != 0 and "already exists" not in (create.stdout + create.stderr):
            raise CloudJourneyError(f"server user creation failed: {create.stderr[-2000:]}")
        return {"user": self.user, "user_output": create.stdout.strip()}

    def env(self) -> dict:
        env = os.environ.copy()
        env["SYNC_DATA_DIR"] = str(self.root / "data")
        env["SYNC_SIGNING_KEY_FILE"] = str(self.root / "signing.key")
        env["SYNC_BIND"] = f"127.0.0.1:{self.port}"
        # Capabilities and asset URLs must mention the port the client actually
        # dialed; the server default stays 8790 whatever SYNC_BIND says.
        env["SYNC_PUBLIC_BASE_URL"] = self.base_url
        env["SYNC_LOG_LEVEL"] = "debug"
        env["SYNC_LOG_PAYLOAD"] = "off"
        return env

    def start(self) -> None:
        if self.process is not None:
            return
        log = self.log_path.open("a", encoding="utf-8")
        self.process = subprocess.Popen(
            [str(SERVER_BIN)], cwd=SERVER_ROOT, env=self.env(),
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
        )
        deadline = time.monotonic() + SERVER_START_TIMEOUT
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise CloudJourneyError(
                    f"server exited during startup; see {self.log_path}"
                )
            try:
                with urllib.request.urlopen(f"{self.base_url}/readyz", timeout=1) as reply:
                    if reply.status == 200:
                        return
            except (urllib.error.URLError, TimeoutError, OSError):
                pass
            time.sleep(0.2)
        raise CloudJourneyError("server did not become ready")

    def stop(self) -> None:
        if self.process is None:
            return
        process, self.process = self.process, None
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except (ProcessLookupError, OSError):
            return
        try:
            process.wait(timeout=SERVER_STOP_TIMEOUT)
        except subprocess.TimeoutExpired:
            os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            process.wait(timeout=5)

    def api(self, path: str, token: str | None = None, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base_url + path, data=data)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        if body is not None:
            request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=10) as reply:
            payload = reply.read()
            return json.loads(payload) if payload else {}

    def login(self) -> str:
        session = self.api("/v1/auth/login", body={
            "username": self.user,
            "password": self.password,
        })
        return session["accessToken"]


def phase_args(endpoint: str, user: str, albums: dict[str, str], expected: int) -> list[str]:
    return [
        f"--cloud-endpoint={endpoint}",
        f"--cloud-username={user}",
        f"--cloud-batch-album={albums['batch']}",
        f"--cloud-single-album={albums['single']}",
        f"--cloud-extra-album={albums['extra']}",
        f"--cloud-expected-photos={expected}",
    ]


def run_phase(name: str, display: str, evidence: Path, data_root: Path,
              args: list[str], password: str) -> dict:
    target = evidence / "runs" / name
    run = run_journey(
        APP_BIN, display=display, phase=name, data_root=data_root,
        evidence_dir=target, log_name=f"{name}.log", timeout=PHASE_TIMEOUT,
        args=args, env_extra={
            "PHOTO_CLOUD_PASSWORD": password,
            "LIBGL_ALWAYS_SOFTWARE": "1",
        },
    )
    record = run.record
    passed = (
        run.exit_code == 0 and not run.timed_out and run.error is None
        and isinstance(record, dict) and record.get("result") == "PASS"
        and isinstance(record.get("steps"), list) and record["steps"]
        and all(step.get("status") == "PASS" for step in record["steps"])
    )
    return {
        **run.as_evidence(target),
        "passed": passed,
        "screenshots": (record or {}).get("screenshots", []),
        "facts": (record or {}).get("facts", {}),
    }


def parse_bindings(database: Path) -> list[dict]:
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        rows = connection.execute(
            "SELECT b.photo_id, b.content_generation, b.media_id, b.relative_path, "
            "b.cloud_favorite, COALESCE(s.dirty,0) AS sync_dirty, "
            "COALESCE(s.path_dirty,0) AS path_dirty, "
            "b.thumbnail_path, b.thumbnail_sha256, "
            "m.source_uri, m.favorite AS local_favorite, m.state AS media_state "
            "FROM cloud_bindings b JOIN media m "
            "ON m.library_id=b.library_id AND m.media_id=b.media_id "
            "LEFT JOIN media_sync_state s "
            "ON s.library_id=b.library_id AND s.media_id=b.media_id "
            "ORDER BY b.relative_path"
        ).fetchall()
        return [dict(row) for row in rows]


def downloaded_asset(root: Path, binding: dict, role: str) -> Path:
    # Downloads are real files: the original sits at its media row's path in
    # the account's download directory, the thumbnail in the private cache.
    field = "source_uri" if role == "original" else "thumbnail_path"
    path = binding.get(field)
    if not path:
        raise CloudJourneyError(f"binding has no {role} path")
    result = Path(path)
    if not result.is_file():
        raise CloudJourneyError(f"expected one {role} at {result}")
    return result


def _cloud_accounts(root: Path) -> list[str]:
    cloud = root / "cloud"
    if not cloud.is_dir():
        return []
    return [entry.name for entry in cloud.iterdir() if entry.is_dir()]


def verify_client_files(root: Path, bindings: list[dict],
                        sources: dict[str, str] | None = None) -> dict:
    account = _cloud_accounts(root)
    if len(account) != 1:
        raise CloudJourneyError(f"expected one cloud account under {root}, found {account}")
    checks = []
    for binding in bindings:
        # Upload bindings point at the local source and carry no downloaded
        # thumbnail; downloaded originals sit in the real download root and
        # their thumbnails in the private cache.
        if not binding["thumbnail_sha256"]:
            continue
        original = downloaded_asset(root, binding, "original")
        thumbnail = downloaded_asset(root, binding, "thumbnail")
        source_path = (sources or {}).get(binding["photo_id"], binding["source_uri"])
        source = Path(source_path)
        if not source.is_file():
            raise CloudJourneyError(f"source file disappeared: {source}")
        if thumbnail.stat().st_size > 2 * 1024 * 1024:
            raise CloudJourneyError(f"thumbnail exceeds 2 MiB: {thumbnail}")
        if sha256_file(original) != sha256_file(source):
            raise CloudJourneyError(f"downloaded original differs from its source: {original}")
        if sha256_file(thumbnail) != binding["thumbnail_sha256"]:
            raise CloudJourneyError(f"thumbnail digest disagrees with the database: {thumbnail}")
        checks.append({
            "photo_id": binding["photo_id"],
            "media_id": binding["media_id"],
            "relative_path": binding["relative_path"],
            "source": str(source),
            "original": str(original),
            "thumbnail": str(thumbnail),
            "original_bytes": original.stat().st_size,
            "thumbnail_bytes": thumbnail.stat().st_size,
            "thumbnail_sha256": binding["thumbnail_sha256"],
        })
    return {"account": account[0], "bindings": checks, "downloaded": len(checks)}


def verify_server(server: SyncServer, root_a: Path, root_b: Path) -> dict:
    token = server.login()
    summary = server.api("/v1/console/summary", token)
    listing = server.api("/v1/console/photos?limit=200", token)
    photos = listing.get("photos", listing if isinstance(listing, list) else [])
    storage = server.api("/v1/storage", token)
    bindings_a = parse_bindings(root_a / "library.sqlite")
    bindings_b = parse_bindings(root_b / "library.sqlite")
    real_sources = {
        binding["photo_id"]: binding["source_uri"]
        for binding in bindings_a + bindings_b
        if not binding["thumbnail_sha256"]
    }
    client_files_a = verify_client_files(root_a, bindings_a, real_sources)
    client_files_b = verify_client_files(root_b, bindings_b, real_sources)
    uploaded_a = len(bindings_a) - client_files_a["downloaded"]
    uploaded_b = len(bindings_b) - client_files_b["downloaded"]
    if (uploaded_a, client_files_a["downloaded"],
            uploaded_b, client_files_b["downloaded"]) != (2, 1, 1, 2):
        raise CloudJourneyError(
            "upload/download split is "
            f"{uploaded_a}/{client_files_a['downloaded']} and "
            f"{uploaded_b}/{client_files_b['downloaded']}, expected 2/1 and 1/2"
        )
    by_photo_a = {binding["photo_id"]: binding for binding in bindings_a}
    by_photo_b = {binding["photo_id"]: binding for binding in bindings_b}
    verified = []
    for photo in photos:
        detail = server.api(f"/v1/console/photos/{photo['photoId']}", token)["photo"]
        photo_id = photo["photoId"]
        if photo_id not in by_photo_a:
            raise CloudJourneyError(f"upload root has no binding for {photo_id}")
        binding_a = by_photo_a[photo_id]
        binding_b = by_photo_b.get(photo_id)
        if binding_a["thumbnail_sha256"]:
            original = downloaded_asset(root_a, binding_a, "original")
            thumbnail = downloaded_asset(root_a, binding_a, "thumbnail")
        elif binding_b is not None and binding_b["thumbnail_sha256"]:
            original = downloaded_asset(root_b, binding_b, "original")
            thumbnail = downloaded_asset(root_b, binding_b, "thumbnail")
        else:
            raise CloudJourneyError(f"no downloaded copy exists for {photo_id}")
        expected_original = detail["original"]["fileChecksum"]
        expected_thumbnail = detail["thumbnail"]["fileChecksum"]
        if b64_digest(original) != expected_original:
            raise CloudJourneyError(f"server original digest differs for {photo_id}")
        if b64_digest(thumbnail) != expected_thumbnail:
            raise CloudJourneyError(f"server thumbnail digest differs for {photo_id}")
        if detail["original"]["size"] != original.stat().st_size:
            raise CloudJourneyError(f"server original size differs for {photo_id}")
        if detail["thumbnail"]["size"] != thumbnail.stat().st_size:
            raise CloudJourneyError(f"server thumbnail size differs for {photo_id}")
        verified.append({
            "photo_id": photo_id,
            "relative_path": detail["relativePath"],
            "favorite": detail["favorite"],
            "original_bytes": detail["original"]["size"],
            "thumbnail_bytes": detail["thumbnail"]["size"],
        })
    if len(verified) != len(bindings_a) or len(verified) != len(bindings_b):
        raise CloudJourneyError("server, upload root and download root disagree on photo count")
    favorites = [photo for photo in verified if photo["favorite"]]
    if len(favorites) != 2:
        raise CloudJourneyError(f"expected two favorites on the server, found {len(favorites)}")
    if any(not photo["relative_path"].startswith("Uploads/") for photo in verified):
        raise CloudJourneyError("server photo paths are outside Uploads/")
    if storage.get("usedBytes", 0) <= 0:
        raise CloudJourneyError("server storage usage was not accounted")
    local_favorite = [
        binding for binding in bindings_a
        if binding["local_favorite"] and binding["media_state"] == "active"
    ]
    if len(local_favorite) != 2:
        raise CloudJourneyError("the upload root did not apply the remote favorites")
    if any(binding["sync_dirty"] or binding["path_dirty"]
           for binding in bindings_a + bindings_b):
        raise CloudJourneyError("a sync obligation is still dirty after the final sync")
    return {
        "summary": summary,
        "storage": storage,
        "photos": verified,
        "favorites": [photo["relative_path"] for photo in favorites],
        "bindings": {"upload_root": len(bindings_a), "download_root": len(bindings_b)},
        "upload_download_split": {
            "upload_root": {"uploaded": uploaded_a,
                            "downloaded": client_files_a["downloaded"]},
            "download_root": {"uploaded": uploaded_b,
                              "downloaded": client_files_b["downloaded"]},
        },
        "client_files": {"upload_root": client_files_a, "download_root": client_files_b},
        "favorite_applied_locally": True,
    }


def verify_token(root: Path) -> dict:
    accounts = _cloud_accounts(root)
    if len(accounts) != 1:
        raise CloudJourneyError(f"expected one cloud account, found {accounts}")
    account = root / "cloud" / accounts[0]
    token = account / "session.token"
    if not token.is_file():
        raise CloudJourneyError("the reconnect phase left no session token")
    mode = token.stat().st_mode & 0o777
    directory_mode = account.stat().st_mode & 0o777
    if mode != 0o600:
        raise CloudJourneyError(f"session token mode is {mode:o}, expected 600")
    if directory_mode != 0o700:
        raise CloudJourneyError(f"account directory mode is {directory_mode:o}, expected 700")
    return {"token_mode": f"{mode:o}", "directory_mode": f"{directory_mode:o}"}


def free_loopback_port() -> int:
    """Reserve an ephemeral port, then let the real server bind it."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def write_report(path: Path, report: dict) -> None:
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run(evidence: Path, library: Path, port: int, skip_build: bool) -> int:
    report: dict = {"result": "FAIL", "evidence": str(evidence), "phases": {}}
    server: SyncServer | None = None
    display = None
    display_context = None
    try:
        report["library"] = {"source": str(library), "active": ensure_library_is_fresh(library)}
        albums = choose_albums(library)
        report["albums"] = albums
        if not skip_build:
            report["build"] = build_app()
            if report["build"]["exit_code"] != 0:
                raise CloudJourneyError("release build failed; see report.build")
        else:
            report["build"] = {"skipped": True}
        if not APP_BIN.is_file():
            raise CloudJourneyError(f"release bundle is missing: {APP_BIN}")
        if not skip_build:
            report["server_build"] = build_server()
        else:
            report["server_build"] = {"skipped": True}
        password = "E2e-" + secrets.token_urlsafe(18)
        if port == 0:
            port = free_loopback_port()
        report["server_port"] = port
        server = SyncServer(evidence / "server", port, password)
        report["server"] = server.prepare()
        server.start()
        roots = {}
        for name in ("upload", "download"):
            root = evidence / f"client-{name}"
            snapshot_library(library, root)
            roots[name] = root
        report["client_roots"] = {name: str(root) for name, root in roots.items()}
        display_context = XvfbDisplay()
        display = display_context.__enter__()
        report["display"] = display
        sequence = [
            ("cloud-upload", roots["upload"], 0),
            ("cloud-download", roots["download"], 2),
        ]
        for name, root, expected in sequence:
            args = phase_args(server.base_url, server.user, albums, expected)
            phase = run_phase(name, display, evidence, root, args, password)
            report["phases"][name] = phase
            if not phase["passed"]:
                raise CloudJourneyError(f"phase {name} failed")
        server.stop()
        phase = run_phase("cloud-offline", display, evidence, roots["download"],
                          phase_args(server.base_url, server.user, albums, 2), password)
        report["phases"]["cloud-offline"] = phase
        if not phase["passed"]:
            raise CloudJourneyError("phase cloud-offline failed")
        server.start()
        phase = run_phase("cloud-reconnect", display, evidence, roots["download"],
                          phase_args(server.base_url, server.user, albums, 3), password)
        report["phases"]["cloud-reconnect"] = phase
        if not phase["passed"]:
            raise CloudJourneyError("phase cloud-reconnect failed")
        phase = run_phase("cloud-reconcile", display, evidence, roots["upload"],
                          phase_args(server.base_url, server.user, albums, 3), password)
        report["phases"]["cloud-reconcile"] = phase
        if not phase["passed"]:
            raise CloudJourneyError("phase cloud-reconcile failed")
        report["token"] = verify_token(roots["download"])
        report["server_state"] = verify_server(server, roots["upload"], roots["download"])
        report["result"] = "PASS"
        return 0
    except CloudJourneyError as error:
        report["error"] = str(error)
        return 1
    except Exception as error:  # noqa: BLE001 - evidence must survive any failure
        report["error"] = f"{type(error).__name__}: {error}"
        return 1
    finally:
        if server is not None:
            server.stop()
        if display is not None:
            try:
                display_context.__exit__(None, None, None)
            except Exception:  # noqa: BLE001
                pass
        write_report(evidence / "report.json", report)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--library", type=Path, default=DEFAULT_LIBRARY,
                        help="real library database snapshotted for both client roots")
    parser.add_argument("--port", type=int, default=0,
                        help="loopback port; 0 chooses a free ephemeral port")
    parser.add_argument("--skip-build", action="store_true",
                        help="use the existing release bundle and server binary")
    options = parser.parse_args(argv)
    try:
        evidence = validate_evidence_dir(options.evidence_dir.expanduser().absolute())
    except CloudJourneyError as error:
        print(f"cloud_e2e: {error}", file=sys.stderr)
        return 2
    if not SERVER_BIN.is_file() and options.skip_build:
        print(f"cloud_e2e: missing server binary {SERVER_BIN}", file=sys.stderr)
        return 2
    return run(evidence, options.library.expanduser().absolute(), options.port,
               options.skip_build)


if __name__ == "__main__":
    raise SystemExit(main())
