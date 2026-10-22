//! Compile-time stubs so the workspace still builds on a development host.

use super::{ImageProbe, VideoProbe};
use std::path::{Path, PathBuf};

fn unavailable<T>() -> Result<T, String> {
    Err("PlatformUnavailable".into())
}

pub fn probe_video(_path: &Path) -> Result<VideoProbe, String> {
    unavailable()
}

pub fn video_thumbnail(_path: &Path, _destination: &Path, _max_edge: u32) -> Result<(), String> {
    unavailable()
}

pub fn probe_image(_path: &Path) -> Result<ImageProbe, String> {
    unavailable()
}

pub fn image_thumbnail(_path: &Path, _destination: &Path, _max_edge: u32) -> Result<(), String> {
    unavailable()
}

pub fn media_directories() -> Vec<PathBuf> {
    Vec::new()
}

pub fn retain_jni_entrypoints() -> [usize; 2] {
    [0, 0]
}
