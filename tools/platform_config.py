"""Strict, declarative platform profiles shared by generation and build tooling."""
from __future__ import annotations

import hashlib
import json
import platform as host_platform
from pathlib import Path
import tempfile
from typing import Any

import yaml
from yaml.events import AliasEvent

BRIDGE_PROTOCOL_VERSION = "1"
U32_MAX = (1 << 32) - 1
ROOT = Path(__file__).resolve().parent.parent
PROFILE_KEYS = {
    "schema_version", "profile_id", "platform", "status", "flutter_target",
    "rust_target", "adapters", "limits", "ui", "packaging",
}
LIMIT_KEYS = {
    "transfer_parallelism", "original_parallelism", "decoder_parallelism",
    "decoder_total_mib", "decoder_single_mib", "image_cache_mib",
    "viewer_cache_mib", "browse_index_mib", "gallery_rows_limit", "disk_cache_mib",
}
# The registry describes accepted platform contracts. Only Linux is activated.
TARGETS = {
    "linux": {
        "profile_id": "linux-x86_64", "flutter_target": "linux",
        "rust_target": "x86_64-unknown-linux-gnu", "format": "linux_bundle",
        "adapters": {
            "storage": "linux_xdg", "source": "linux_file_picker",
            "secrets": "linux_secret_service", "scheduler": "while_app_running",
            "codec": "portable_image", "instance_lock": "linux_process_lock",
        },
    },
    "android": {
        "profile_id": "android-universal", "flutter_target": "android",
        # One profile and one digest for every packaged ABI; the emulator runs
        # the x86_64 artifact and devices run the ARM artifacts.
        "rust_target": "aarch64-linux-android,armv7-linux-androideabi,x86_64-linux-android",
        "format": "apk_aab",
        "adapters": {
            "storage": "android_private", "source": "android_content_uri",
            "secrets": "android_protected_session", "scheduler": "android_system_budget",
            "codec": "android_media_codec", "instance_lock": "android_process_lock",
        },
    },
    "windows": {
        "profile_id": "windows-x86_64", "flutter_target": "windows",
        "rust_target": "x86_64-pc-windows-msvc", "format": "windows_installer",
        "adapters": {
            "storage": "windows_app_data", "source": "windows_file_picker",
            "secrets": "windows_credentials", "scheduler": "while_app_running",
            "codec": "portable_image", "instance_lock": "windows_process_lock",
        },
    },
}


class ProfileError(ValueError):
    """A profile failed before opening any application data."""


class StrictLoader(yaml.SafeLoader):
    def compose_node(self, parent: Any, index: Any) -> Any:
        if self.check_event(AliasEvent):
            raise ProfileError("YAML aliases are not allowed in platform profiles")
        return super().compose_node(parent, index)


def _mapping(loader: StrictLoader, node: yaml.MappingNode) -> dict[str, Any]:
    if not isinstance(node, yaml.MappingNode):
        raise ProfileError("YAML mapping tag requires a mapping value")
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=True)
        if type(key) is not str:
            raise ProfileError(f"YAML field names must be strings (line {key_node.start_mark.line + 1})")
        if key in mapping:
            raise ProfileError(f"duplicate YAML field {key!r} (line {key_node.start_mark.line + 1})")
        mapping[key] = loader.construct_object(value_node, deep=True)
    return mapping


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)


def _fields(value: Any, expected: set[str], path: str) -> dict[str, Any]:
    if type(value) is not dict:
        raise ProfileError(f"{path}: expected a mapping")
    if any(type(key) is not str for key in value):
        raise ProfileError(f"{path}: all field names must be strings")
    unknown, missing = value.keys() - expected, expected - value.keys()
    if unknown:
        raise ProfileError(f"{path}: unknown fields: {', '.join(sorted(unknown))}")
    if missing:
        raise ProfileError(f"{path}: missing fields: {', '.join(sorted(missing))}")
    return value


def _string(value: Any, path: str) -> str:
    if type(value) is not str:
        raise ProfileError(f"{path}: expected a string")
    return value


def validate_profile(profile: Any, *, host: tuple[str, str] | None = None) -> dict[str, Any]:
    p = _fields(profile, PROFILE_KEYS, "profile")
    if type(p["schema_version"]) is not int or p["schema_version"] != 1:
        raise ProfileError("schema_version: expected integer 1")
    for key in ("profile_id", "platform", "status", "flutter_target", "rust_target"):
        _string(p[key], key)
    if p["platform"] not in TARGETS:
        raise ProfileError("platform: allowed values: linux, android, windows")
    target = TARGETS[p["platform"]]
    for key in ("profile_id", "flutter_target", "rust_target"):
        if p[key] != target[key]:
            raise ProfileError(f"{key}: expected {target[key]!r} for {p['platform']}")
    if p["status"] not in ("active", "planned"):
        raise ProfileError("status: allowed values: active, planned")
    if p["platform"] == "windows" and p["status"] != "planned":
        raise ProfileError(f"status: {p['platform']} is not activated; must remain planned")
    adapters = _fields(p["adapters"], set(target["adapters"]), "adapters")
    for key, expected in target["adapters"].items():
        if _string(adapters[key], f"adapters.{key}") != expected:
            raise ProfileError(f"adapters.{key}: expected registered adapter {expected!r}")
    limits = _fields(p["limits"], LIMIT_KEYS, "limits")
    for key, value in limits.items():
        if type(value) is not int or not 1 <= value <= U32_MAX:
            raise ProfileError(f"limits.{key}: expected a positive u32 integer (1..{U32_MAX})")
    if limits["gallery_rows_limit"] > 2000:
        raise ProfileError("limits.gallery_rows_limit: must be <= 2000")
    if limits["original_parallelism"] > limits["transfer_parallelism"]:
        raise ProfileError("limits.original_parallelism: must be <= transfer_parallelism")
    if limits["decoder_single_mib"] > limits["decoder_total_mib"]:
        raise ProfileError("limits.decoder_single_mib: must be <= decoder_total_mib")
    ui = _fields(p["ui"], {"layout", "keyboard_mouse", "touch"}, "ui")
    if _string(ui["layout"], "ui.layout") != "adaptive":
        raise ProfileError("ui.layout: expected 'adaptive'")
    for key in ("keyboard_mouse", "touch"):
        if type(ui[key]) is not bool:
            raise ProfileError(f"ui.{key}: expected a boolean")
    packaging = _fields(p["packaging"], {"format"}, "packaging")
    if _string(packaging["format"], "packaging.format") != target["format"]:
        raise ProfileError(f"packaging.format: expected {target['format']!r}")
    if p["status"] == "active":
        system, machine = host or (host_platform.system(), host_platform.machine())
        if (system.lower(), machine.lower()) not in {("linux", "x86_64"), ("linux", "amd64")}:
            raise ProfileError(f"host: {p['profile_id']} requires a Linux x86_64 build host; got {system}/{machine}")
    return p


def require_active(profile: dict[str, Any]) -> None:
    if profile["status"] != "active":
        raise ProfileError(f"status: {profile['profile_id']} is planned; build/run NOT IMPLEMENTED")


def profile_path(profile_id: str, root: Path = ROOT) -> Path:
    if profile_id not in {target["profile_id"] for target in TARGETS.values()}:
        raise ProfileError("profile_id: unknown profile; allowed: linux-x86_64, android-universal, windows-x86_64")
    return root / "config" / "platforms" / f"{profile_id}.yaml"


def load_profile(path: Path, *, host: tuple[str, str] | None = None) -> dict[str, Any]:
    try:
        # Bound parser input and reject aliases to prevent recursive resource expansion.
        with path.open("rb") as source:
            raw = source.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise ProfileError("profile: YAML exceeds 256 KiB")
        parsed = yaml.load(raw.decode("utf-8"), Loader=StrictLoader)
        return validate_profile(parsed, host=host)
    except (OSError, UnicodeError, yaml.YAMLError, RecursionError) as exc:
        raise ProfileError(f"profile: cannot read valid YAML from {path}: {exc}") from exc


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True, allow_nan=False)


def profile_digest(profile: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_json(profile).encode("utf-8")).hexdigest()


def dart_defines(profile: dict[str, Any]) -> dict[str, str]:
    return {
        "PHOTO_PROFILE_JSON": canonical_json(profile),
        "PHOTO_PROFILE_DIGEST": profile_digest(profile),
        "PHOTO_BRIDGE_PROTOCOL_VERSION": BRIDGE_PROTOCOL_VERSION,
    }


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as out:
        temporary = Path(out.name)
        try:
            out.write(content)
            out.flush()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def generate(profile: dict[str, Any], root: Path = ROOT) -> dict[str, Path]:
    validate_profile(profile)
    output = root / ".build" / profile["profile_id"]
    paths = {"profile_json": output / "profile.json", "dart_defines": output / "dart-defines.json"}
    _atomic_write(paths["profile_json"], canonical_json(profile))
    _atomic_write(paths["dart_defines"], canonical_json(dart_defines(profile)))
    return paths
