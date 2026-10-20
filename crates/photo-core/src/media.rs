//! Read-only local discovery and fingerprint-checked thumbnail publication.
//!
//! Run these blocking operations on the application's bounded media workers.
//! Scanning reads container headers/EXIF, never decodes pixels or hashes originals.
mod headers;
mod thumbnail;

pub use thumbnail::prepare_thumbnail;

use std::fs::{self, File, Metadata};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::UNIX_EPOCH;

use image::ImageFormat;
use walkdir::WalkDir;

/// Encoded dimensions are separate from EXIF orientation; 5–8 swap display axes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredMedia {
    pub path: PathBuf,
    pub display_name: String,
    pub parent_path: PathBuf,
    pub size_bytes: u64,
    pub modified_ns: i64,
    pub mime_type: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub orientation: u8,
    pub capture_time_ms: Option<i64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScanSummary {
    /// Rows successfully handed to the callback, excluding a cancelled partial batch.
    pub discovered: u64,
    pub skipped: u64,
    pub failed: u64,
    pub cancelled: bool,
}

pub(super) fn format_for_path(path: &Path) -> Option<(ImageFormat, &'static str)> {
    let extension = path.extension()?.to_str()?;
    if extension.eq_ignore_ascii_case("jpg") || extension.eq_ignore_ascii_case("jpeg") {
        Some((ImageFormat::Jpeg, "image/jpeg"))
    } else if extension.eq_ignore_ascii_case("png") {
        Some((ImageFormat::Png, "image/png"))
    } else if extension.eq_ignore_ascii_case("webp") {
        Some((ImageFormat::WebP, "image/webp"))
    } else {
        None
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Fingerprint {
    pub size: u64,
    pub modified_ns: i64,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
}

impl Fingerprint {
    pub fn from_metadata(metadata: &Metadata) -> Result<Self, String> {
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err("UnsupportedSource: expected a regular file, not a symlink".into());
        }
        let modified = metadata
            .modified()
            .map_err(|e| format!("SourceMetadata: {e}"))?;
        let ns = match modified.duration_since(UNIX_EPOCH) {
            Ok(duration) => i128::try_from(duration.as_nanos()).ok(),
            Err(error) => i128::try_from(error.duration().as_nanos()).ok().map(|v| -v),
        }
        .and_then(|v| i64::try_from(v).ok())
        .ok_or("SourceMetadata: modification time is outside signed nanosecond range")?;
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        Ok(Self {
            size: metadata.len(),
            modified_ns: ns,
            #[cfg(unix)]
            device: metadata.dev(),
            #[cfg(unix)]
            inode: metadata.ino(),
        })
    }
}

pub(super) fn check_source(
    source: &Path,
    file: &File,
    expected: &Fingerprint,
) -> Result<(), String> {
    let path_metadata =
        fs::symlink_metadata(source).map_err(|_| "SourceChanged: source unavailable")?;
    let path_fingerprint = Fingerprint::from_metadata(&path_metadata)?;
    let handle_fingerprint = Fingerprint::from_metadata(
        &file
            .metadata()
            .map_err(|e| format!("SourceMetadata: {e}"))?,
    )?;
    if &path_fingerprint != expected || &handle_fingerprint != expected {
        return Err("SourceChanged: size, modification time or file identity changed".into());
    }
    Ok(())
}

fn inspect(path: &Path) -> Result<DiscoveredMedia, String> {
    let (format, mime) = format_for_path(path).ok_or("UnsupportedSource: extension")?;
    let initial = Fingerprint::from_metadata(
        &fs::symlink_metadata(path).map_err(|e| format!("SourceMetadata: {e}"))?,
    )?;
    let mut file = File::open(path).map_err(|e| format!("SourceRead: {e}"))?;
    check_source(path, &file, &initial)?;
    let header = headers::read(&mut file, format, initial.size)?;
    check_source(path, &file, &initial)?;
    Ok(DiscoveredMedia {
        path: path.to_path_buf(),
        display_name: path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        parent_path: path.parent().unwrap_or_else(|| Path::new("")).to_path_buf(),
        size_bytes: initial.size,
        modified_ns: initial.modified_ns,
        mime_type: mime.into(),
        width: Some(header.width),
        height: Some(header.height),
        orientation: header.orientation,
        capture_time_ms: header.capture_time_ms,
    })
}

/// Stream batches of at most 100. Item failures are counted and isolated; callback
/// errors abort immediately. Cancellation discards only the unpublished partial
/// batch. Already accepted batches remain accepted. Directories aren't counted as
/// skipped; unsupported files, links and special files are. Repeated/overlapping
/// roots may emit the same source again; the library writer owns URI deduplication.
pub fn scan_paths(
    paths: &[PathBuf],
    cancel: &AtomicBool,
    mut on_batch: impl FnMut(Vec<DiscoveredMedia>) -> Result<(), String>,
) -> Result<ScanSummary, String> {
    let mut summary = ScanSummary::default();
    let mut pending = Vec::with_capacity(100);
    'roots: for root in paths {
        if cancel.load(Ordering::Relaxed) {
            summary.cancelled = true;
            break;
        }
        let metadata = match fs::symlink_metadata(root) {
            Ok(metadata) => metadata,
            Err(_) => {
                summary.failed += 1;
                continue;
            }
        };
        if metadata.file_type().is_symlink() || !(metadata.is_file() || metadata.is_dir()) {
            summary.skipped += 1;
            continue;
        }
        let root = match fs::canonicalize(root) {
            Ok(root) => root,
            Err(_) => {
                summary.failed += 1;
                continue;
            }
        };
        let mut entries = WalkDir::new(&root)
            .follow_links(false)
            .follow_root_links(false)
            .max_open(16)
            .into_iter();
        loop {
            if cancel.load(Ordering::Relaxed) {
                summary.cancelled = true;
                break 'roots;
            }
            let Some(entry) = entries.next() else {
                break;
            };
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => {
                    summary.failed += 1;
                    continue;
                }
            };
            let kind = entry.file_type();
            if kind.is_dir() {
                continue;
            }
            if kind.is_symlink() || !kind.is_file() || format_for_path(entry.path()).is_none() {
                summary.skipped += 1;
                continue;
            }
            match inspect(entry.path()) {
                Ok(media) => pending.push(media),
                Err(_) => {
                    summary.failed += 1;
                    continue;
                }
            }
            if cancel.load(Ordering::Relaxed) {
                summary.cancelled = true;
                break 'roots;
            }
            if pending.len() == 100 {
                on_batch(std::mem::replace(&mut pending, Vec::with_capacity(100)))?;
                summary.discovered += 100;
            }
        }
    }
    if cancel.load(Ordering::Relaxed) {
        summary.cancelled = true;
    }
    if !summary.cancelled && !pending.is_empty() {
        let count = pending.len() as u64;
        on_batch(pending)?;
        summary.discovered += count;
        if cancel.load(Ordering::Relaxed) {
            summary.cancelled = true;
        }
    }
    Ok(summary)
}
