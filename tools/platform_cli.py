"""Fixed-command Linux build/run orchestration; no shell or profile commands."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import zipfile

from platform_config import (
    ROOT, ProfileError, canonical_json, dart_defines, generate, load_profile,
    profile_digest, profile_path, require_active,
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Validate, generate and build declarative Photo platform profiles.")
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("validate", "describe", "generate", "build", "run"):
        command = commands.add_parser(name)
        command.add_argument("--profile", default="linux-x86_64")
        command.add_argument("--profile-file", type=Path, help="Use this YAML instead of the named profile (also useful for rejection tests)")
        command.add_argument("--mode", choices=("release", "debug"), default="debug")
        if name == "run":
            command.add_argument("app_args", nargs=argparse.REMAINDER, help="Arguments forwarded after --")
    return result


def discover_flutter() -> str:
    configured = os.environ.get("PHOTO_FLUTTER_ROOT")
    if configured:
        candidate = Path(configured).expanduser().resolve() / "bin" / "flutter"
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            raise ProfileError("toolchain: PHOTO_FLUTTER_ROOT/bin/flutter is not executable")
        return str(candidate)
    found = shutil.which("flutter")
    if not found:
        raise ProfileError("toolchain: Flutter not found; set PHOTO_FLUTTER_ROOT or add flutter to PATH")
    return found


def execute(args: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> None:
    # Print only command arguments, never environment values or credentials.
    print(f"+ {shlex.join(args)}", flush=True)
    subprocess.run(args, cwd=cwd, env=env, check=True)


ANDROID_ABIS = {
    "armeabi-v7a": "android-arm",
    "arm64-v8a": "android-arm64",
    "x86_64": "android-x64",
}


def android_sdk(root: Path) -> Path:
    for key in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        value = os.environ.get(key)
        if value:
            return Path(value).expanduser()
    properties = root / "app" / "android" / "local.properties"
    if properties.is_file():
        for line in properties.read_text(encoding="utf-8").splitlines():
            if line.startswith("sdk.dir="):
                return Path(line.split("=", 1)[1]).expanduser()
    return Path.home() / "Android" / "Sdk"


def discover_ndk(root: Path) -> Path:
    for key in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT"):
        value = os.environ.get(key)
        if value and (Path(value) / "source.properties").is_file():
            return Path(value)
    ndk_root = android_sdk(root) / "ndk"
    if ndk_root.is_dir():
        versions = sorted(
            (entry for entry in ndk_root.iterdir() if (entry / "source.properties").is_file()),
            key=lambda entry: tuple(int(part) for part in entry.name.split(".") if part.isdigit()),
        )
        if versions:
            return versions[-1]
    raise ProfileError("toolchain: Android NDK not found; install it or set ANDROID_NDK_HOME")


def find_adb(root: Path) -> str:
    configured = os.environ.get("ADB")
    if configured:
        return configured
    found = shutil.which("adb")
    if found:
        return found
    candidate = android_sdk(root) / "platform-tools" / "adb"
    if candidate.is_file():
        return str(candidate)
    raise ProfileError("toolchain: adb not found; install Android platform-tools or set ADB")


def cargo_ndk_available() -> bool:
    if shutil.which("cargo-ndk"):
        return True
    probe = subprocess.run(
        ["cargo", "ndk", "--version"],
        capture_output=True,
        text=True,
        check=False,
    )
    return probe.returncode == 0


def build_android(profile: dict, mode: str, root: Path) -> Path:
    flutter = discover_flutter()
    cargo = shutil.which("cargo")
    if not cargo:
        raise ProfileError("toolchain: cargo not found on PATH")
    if not cargo_ndk_available():
        raise ProfileError("toolchain: cargo-ndk not found; run `cargo install cargo-ndk`")
    ndk = discover_ndk(root)
    paths = generate(profile, root)
    jni = root / "app" / "android" / "app" / "src" / "main" / "jniLibs"
    for abi in ANDROID_ABIS:
        stale = jni / abi / "libphoto_bridge.so"
        if stale.exists():
            stale.unlink()
    env = os.environ.copy()
    env.update(dart_defines(profile))
    env["CARGO_TARGET_DIR"] = str(root / "target")
    env["ANDROID_NDK_HOME"] = str(ndk)
    env["ANDROID_NDK_ROOT"] = str(ndk)
    cargo_args = [cargo, "ndk", "-P", "30"]
    for abi in ANDROID_ABIS:
        cargo_args.extend(["-t", abi])
    cargo_args.extend(["-o", str(jni), "build", "--locked", "-p", "photo-bridge"])
    if mode == "release":
        cargo_args.append("--release")
    execute(cargo_args, cwd=root, env=env)
    native = {}
    for abi in ANDROID_ABIS:
        library = jni / abi / "libphoto_bridge.so"
        if not library.is_file():
            raise ProfileError(f"build: expected native library missing: {library}")
        native[abi] = str(library)
    targets = ",".join(ANDROID_ABIS.values())
    execute([
        flutter, "--no-version-check", "build", "apk", f"--{mode}",
        "--target-platform", targets,
        f"--dart-define-from-file={paths['dart_defines']}",
    ], cwd=root / "app", env=env)
    apk = root / "app" / "build" / "app" / "outputs" / "flutter-apk" / f"app-{mode}.apk"
    if not apk.is_file():
        raise ProfileError(f"build: Flutter did not produce expected APK: {apk}")
    with zipfile.ZipFile(apk) as archive:
        entries = set(archive.namelist())
    for abi in ANDROID_ABIS:
        if f"lib/{abi}/libphoto_bridge.so" not in entries:
            raise ProfileError(f"build: APK is missing libphoto_bridge.so for {abi}")
    print(canonical_json({
        "profile_id": profile["profile_id"], "profile_digest": profile_digest(profile),
        "mode": mode, "native_libraries": native, "apk": str(apk),
        "abis": list(ANDROID_ABIS), "packaging_acceptance": "NOT RUN",
    }), flush=True)
    return apk


def build(profile: dict, mode: str, root: Path = ROOT) -> Path:
    require_active(profile)
    if not (root / "Cargo.toml").is_file() or not (root / "app" / "pubspec.yaml").is_file():
        raise ProfileError("build: Rust workspace and app/pubspec.yaml are required")
    if not (root / "Cargo.lock").is_file():
        raise ProfileError("build: Cargo.lock is required for --locked builds")
    if profile["platform"] == "android":
        return build_android(profile, mode, root)
    if profile["platform"] != "linux":
        raise ProfileError(f"build: {profile['platform']} packaging is not implemented")
    flutter = discover_flutter()
    cargo = shutil.which("cargo")
    if not cargo:
        raise ProfileError("toolchain: cargo not found on PATH")
    paths = generate(profile, root)
    from prepare_linux_media import environment, bundle_runtime
    env, media_runtime = environment()
    env.update(dart_defines(profile))
    # Keep the native artifact location deterministic even with a caller override.
    env["CARGO_TARGET_DIR"] = str(root / "target")
    env["PHOTO_NATIVE_LIB_DIR"] = str(root / "target" / mode)
    cargo_args = [cargo, "build", "--locked", "-p", "photo-bridge"]
    if mode == "release":
        cargo_args.append("--release")
    execute(cargo_args, cwd=root, env=env)
    native = root / "target" / mode / "libphoto_bridge.so"
    if not native.is_file():
        raise ProfileError(f"build: expected native library missing: {native}")
    execute([
        flutter, "--no-version-check", "build", "linux", f"--{mode}",
        f"--dart-define-from-file={paths['dart_defines']}",
    ], cwd=root / "app", env=env)
    bundle = root / "app" / "build" / "linux" / "x64" / mode / "bundle"
    if not bundle.is_dir():
        raise ProfileError(f"build: Flutter did not produce expected bundle: {bundle}")
    bundle_runtime(bundle, media_runtime)
    print(canonical_json({
        "profile_id": profile["profile_id"], "profile_digest": profile_digest(profile),
        "mode": mode, "native_library": str(native), "bundle": str(bundle),
        "packaging_acceptance": "NOT RUN",
    }), flush=True)
    return bundle


def launch(bundle: Path, app_args: list[str]) -> None:
    executables = sorted(p for p in bundle.iterdir() if p.is_file() and os.access(p, os.X_OK))
    if len(executables) != 1:
        raise ProfileError(f"run: expected exactly one executable in bundle; found {len(executables)}")
    args = app_args[1:] if app_args[:1] == ["--"] else app_args
    execute([str(executables[0]), *args], cwd=bundle)


def main(argv: list[str] | None = None) -> int:
    options = parser().parse_args(argv)
    try:
        path = options.profile_file or profile_path(options.profile)
        profile = load_profile(path)
        if options.profile_file is None and profile["profile_id"] != options.profile:
            raise ProfileError("profile_id: YAML identity does not match selected profile")
        if options.command in ("build", "run"):
            bundle = build(profile, options.mode)
            if options.command == "run":
                launch(bundle, options.app_args)
        elif options.command == "generate":
            paths = generate(profile)
            print(canonical_json({"profile_digest": profile_digest(profile), **{k: str(v) for k, v in paths.items()}}))
        else:
            description = {
                "profile_id": profile["profile_id"], "profile_digest": profile_digest(profile),
                "bridge_protocol_version": "1", "valid": True,
            }
            if options.command == "describe":
                description["profile"] = profile
                description["build_supported"] = profile["status"] == "active"
            print(canonical_json(description))
        return 0
    except ProfileError as exc:
        print(f"platform: {exc}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        print(f"platform: command failed with exit status {exc.returncode}", file=sys.stderr)
        return exc.returncode if 0 < exc.returncode < 126 else 1
    except OSError as exc:
        print(f"platform: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
