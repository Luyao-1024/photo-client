//! Android adapter: JNI access to the platform media extractors and the
//! standard media directories. Catalog, thumbnails and sync stay in the shared
//! `photo-core`; only the codec and storage entry points are platform-specific.

use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VideoProbe {
    pub width: u32,
    pub height: u32,
    pub duration_ms: i64,
    pub rotation: u32,
    pub capture_time_ms: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImageProbe {
    pub width: u32,
    pub height: u32,
    pub orientation: u8,
    pub capture_time_ms: Option<i64>,
}

#[cfg(target_os = "android")]
mod android;
#[cfg(target_os = "android")]
pub use android::{
    image_thumbnail, media_directories, probe_image, probe_video, retain_jni_entrypoints,
    video_thumbnail,
};

#[cfg(not(target_os = "android"))]
mod unsupported;
#[cfg(not(target_os = "android"))]
pub use unsupported::{
    image_thumbnail, media_directories, probe_image, probe_video, retain_jni_entrypoints,
    video_thumbnail,
};

pub(crate) fn utf8(path: &Path) -> Result<&str, String> {
    path.to_str().ok_or_else(|| "UnsupportedPathEncoding".into())
}
