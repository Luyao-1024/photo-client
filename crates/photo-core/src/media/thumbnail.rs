use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use image::codecs::jpeg::JpegEncoder;
use image::metadata::Orientation;
use image::{DynamicImage, ImageReader, Limits};
use uuid::Uuid;

use super::{Fingerprint, check_source, format_for_path, headers};

const DECODE_BUDGET: u64 = 128 * 1024 * 1024;
const WORKSPACE_RESERVE: u64 = 16 * 1024 * 1024;

/// Limit compressed input to the captured file extent even if the file grows
/// during a decoder read_to_end. Seeking cannot escape that original extent.
struct SourceExtent {
    file: File,
    position: u64,
    limit: u64,
}
impl Read for SourceExtent {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        let count = (self.limit.saturating_sub(self.position)).min(output.len() as u64) as usize;
        let read = self.file.read(&mut output[..count])?;
        self.position += read as u64;
        Ok(read)
    }
}
impl Seek for SourceExtent {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        let desired = match position {
            SeekFrom::Start(value) => i128::from(value),
            SeekFrom::Current(value) => i128::from(self.position) + i128::from(value),
            SeekFrom::End(value) => i128::from(self.limit) + i128::from(value),
        };
        if desired < 0 || desired > i128::from(self.limit) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "seek exceeds captured source extent",
            ));
        }
        self.position = self.file.seek(SeekFrom::Start(desired as u64))?;
        Ok(self.position)
    }
}

struct PendingThumbnail(PathBuf);
impl Drop for PendingThumbnail {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

/// Generate a JPEG in a same-directory temporary file and publish with rename.
/// The supplied cache path must be managed by the caller. Source paths, file
/// identities and size/mtime fingerprints are checked before reading, after
/// decoding and immediately before publication. No original is opened for write.
///
/// The 128 MiB admission budget includes compressed input, conservative decoded
/// buffers, thumbnail transformations and a codec workspace reserve. Codec heap
/// overhead is not an operating-system RSS hard limit. Oversized images fail
/// with DecodeBudgetExceeded, without replacing a previous cache entry.
pub fn prepare_thumbnail(
    source: &Path,
    expected_size: u64,
    expected_modified_ns: i64,
    max_edge: u32,
    destination: &Path,
) -> Result<(), String> {
    if max_edge == 0 {
        return Err("InvalidThumbnailBounds: max_edge must be positive".into());
    }
    let (format, _) = format_for_path(source).ok_or("UnsupportedSource: image extension")?;
    let metadata = fs::symlink_metadata(source).map_err(|e| format!("SourceMetadata: {e}"))?;
    let expected = Fingerprint::from_metadata(&metadata)?;
    if expected.size != expected_size || expected.modified_ns != expected_modified_ns {
        return Err("SourceChanged: expected size or modification time differs".into());
    }
    let canonical_source = fs::canonicalize(source).map_err(|e| format!("SourceRead: {e}"))?;
    if let Ok(destination_metadata) = fs::symlink_metadata(destination) {
        #[cfg(unix)]
        let same_identity = Fingerprint::from_metadata(&destination_metadata)
            .ok()
            .as_ref()
            == Some(&expected);
        #[cfg(not(unix))]
        let same_identity = false;
        if destination_metadata.file_type().is_symlink()
            || fs::canonicalize(destination).ok().as_ref() == Some(&canonical_source)
            || same_identity
        {
            return Err(
                "UnsafeThumbnailDestination: destination aliases the source or is a symlink".into(),
            );
        }
    }
    let mut file = File::open(source).map_err(|e| format!("SourceRead: {e}"))?;
    check_source(source, &file, &expected)?;
    let header = headers::read(&mut file, format, expected.size)?;
    let longest = header.width.max(header.height);
    let target_width =
        ((u64::from(header.width) * u64::from(max_edge.min(longest))) / u64::from(longest)).max(1);
    let target_height =
        ((u64::from(header.height) * u64::from(max_edge.min(longest))) / u64::from(longest)).max(1);
    let decoded_bytes = u64::from(header.width)
        .checked_mul(u64::from(header.height))
        .and_then(|v| v.checked_mul(header.bytes_per_pixel));
    let thumbnail_bytes = target_width
        .checked_mul(target_height)
        .and_then(|v| v.checked_mul(16));
    let admission = decoded_bytes
        .and_then(|v| v.checked_mul(2))
        .and_then(|v| v.checked_add(expected.size))
        .and_then(|v| v.checked_add(thumbnail_bytes?))
        .and_then(|v| v.checked_add(WORKSPACE_RESERVE));
    if admission.is_none_or(|bytes| bytes > DECODE_BUDGET) {
        return Err(
            "DecodeBudgetExceeded: image exceeds the 128 MiB thumbnail decode budget".into(),
        );
    }
    check_source(source, &file, &expected)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|e| format!("SourceRead: {e}"))?;
    let extent = SourceExtent {
        file: file.try_clone().map_err(|e| format!("SourceRead: {e}"))?,
        position: 0,
        limit: expected.size,
    };
    let mut reader = ImageReader::with_format(BufReader::new(extent), format);
    let mut limits = Limits::default();
    limits.max_image_width = Some(header.width);
    limits.max_image_height = Some(header.height);
    limits.max_alloc =
        Some(DECODE_BUDGET - expected.size - thumbnail_bytes.unwrap() - WORKSPACE_RESERVE);
    reader.limits(limits);
    let decoded = reader.decode();
    check_source(source, &file, &expected)?;
    let decoded = decoded.map_err(|e| format!("ThumbnailDecodeFailed: {e}"))?;
    if decoded.width() != header.width || decoded.height() != header.height {
        return Err("SourceChanged: decoded dimensions disagree with captured header".into());
    }
    let mut small = if longest <= max_edge {
        decoded
    } else {
        let reduced = decoded.thumbnail(target_width as u32, target_height as u32);
        drop(decoded);
        reduced
    };
    // Rotate only after reducing the image, avoiding a second full original buffer.
    small.apply_orientation(
        Orientation::from_exif(header.orientation).unwrap_or(Orientation::NoTransforms),
    );
    let rgb = DynamicImage::ImageRgb8(small.into_rgb8());
    let parent = destination
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|e| format!("ThumbnailWriteFailed: {e}"))?;
    let pending = PendingThumbnail(parent.join(format!(".photo-thumb-{}.tmp", Uuid::new_v4())));
    let output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&pending.0)
        .map_err(|e| format!("ThumbnailWriteFailed: {e}"))?;
    {
        let mut writer = BufWriter::new(&output);
        JpegEncoder::new_with_quality(&mut writer, 85)
            .encode_image(&rgb)
            .map_err(|e| format!("ThumbnailEncodeFailed: {e}"))?;
        writer
            .flush()
            .map_err(|e| format!("ThumbnailWriteFailed: {e}"))?;
    }
    output
        .sync_all()
        .map_err(|e| format!("ThumbnailWriteFailed: {e}"))?;
    drop(output);
    check_source(source, &file, &expected)?;
    fs::rename(&pending.0, destination).map_err(|e| format!("ThumbnailPublishFailed: {e}"))?;
    Ok(())
}
