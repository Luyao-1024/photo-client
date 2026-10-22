// Resolve the HEIF link name on hosts that ship only the runtime library.
//
// `src/media/heif.rs` declares `#[link(name = "heif")]`, so the linker looks
// for `libheif.so`. Some distributions install only `libheif.so.1` and leave
// the development name to a separate `-dev` package; every link step then
// fails with "unable to find library -lheif" even though the decoder works.
//
// When the development name is missing, link a local alias of the runtime
// library instead. The alias lives in OUT_DIR: no system file is touched and
// the application bundle stays free of build-only names.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CC");
    println!("cargo:rerun-if-env-changed=LIBRARY_PATH");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("linux") {
        return;
    }

    println!("cargo:rerun-if-changed=src/media/jpeg_scale_shim.c");
    cc::Build::new()
        .file("src/media/jpeg_scale_shim.c")
        .warnings(true)
        .compile("photo_jpeg_scale");
    println!("cargo:rustc-link-lib=jpeg");

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let alias = out_dir.join("libheif.so");
    if compiler_finds("libheif.so") {
        // The development library is already reachable through the compiler.
        // Drop a stale alias so the output directory matches this decision.
        let _ = std::fs::remove_file(&alias);
        return;
    }

    let Some(runtime) = find_runtime_library() else {
        println!(
            "cargo:warning=libheif.so is unavailable and no libheif.so.1 was found; \
             install the libheif development package"
        );
        return;
    };

    let _ = std::fs::remove_file(&alias);
    std::os::unix::fs::symlink(&runtime, &alias)
        .unwrap_or_else(|error| panic!("cannot link {}: {error}", alias.display()));
    println!("cargo:rustc-link-search=native={}", out_dir.display());
}
/// Ask the host compiler where a library lives.
///
/// GCC prints the bare file name when it cannot find the library, so an
/// absolute answer is the only reliable "found" signal.
fn compiler_finds(library: &str) -> bool {
    let compiler = env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let mut command = Command::new(compiler.split_whitespace().next().unwrap_or("cc"));
    command.arg(format!("-print-file-name={library}"));
    let Ok(output) = command.output() else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let answer = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let path = Path::new(&answer);
    path.is_absolute() && path.is_file()
}

/// Locate the runtime library that the alias points at.
///
/// The system library comes first: it is also in the default loader path, so
/// the linked test and application binaries start without extra environment.
/// The bundled decoder prepared by `tools/prepare_linux_media.py` is the last
/// resort because it needs an explicit runtime search path.
fn find_runtime_library() -> Option<PathBuf> {
    if compiler_finds("libheif.so.1") {
        return Some(compiler_path("libheif.so.1"));
    }

    let mut directories: Vec<PathBuf> = env::var("LIBRARY_PATH")
        .unwrap_or_default()
        .split(':')
        .filter(|entry| !entry.is_empty())
        .map(PathBuf::from)
        .collect();
    directories.extend(
        [
            "/usr/lib64",
            "/usr/lib/x86_64-linux-gnu",
            "/usr/lib",
            "/usr/local/lib",
            "/lib64",
        ]
        .into_iter()
        .map(PathBuf::from),
    );
    // The bundled decoder lives next to the workspace, not in the package.
    if let Ok(manifest) = env::var("CARGO_MANIFEST_DIR") {
        let root = Path::new(&manifest)
            .ancestors()
            .nth(2)
            .map(Path::to_path_buf);
        if let Some(root) = root {
            directories.push(root.join(".tooling/media-runtime/usr/lib64"));
        }
    }

    for directory in directories {
        let candidate = directory.join("libheif.so.1");
        if candidate.is_file() {
            return Some(candidate.canonicalize().unwrap_or(candidate));
        }
    }
    None
}

/// The absolute path the compiler reports for a library.
fn compiler_path(library: &str) -> PathBuf {
    let compiler = env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let mut command = Command::new(compiler.split_whitespace().next().unwrap_or("cc"));
    command.arg(format!("-print-file-name={library}"));
    let answer = command
        .output()
        .ok()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .unwrap_or_default();
    PathBuf::from(answer)
}
