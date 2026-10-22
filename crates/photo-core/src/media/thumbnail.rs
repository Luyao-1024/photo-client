use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use image::codecs::jpeg::JpegEncoder;
use image::metadata::Orientation;
use image::{DynamicImage, ImageReader, Limits, Rgb, RgbImage};
use uuid::Uuid;

use super::{Fingerprint, check_source, format_for_path, headers, scaled};

const DECODE_BUDGET: u64 = 128 * 1024 * 1024;
const WORKSPACE_RESERVE: u64 = 16 * 1024 * 1024;
/// Quality of the published thumbnail. The pre-refactor client stored its
/// cache at quality 90, and the grid has to look the same after the rewrite.
pub(super) const THUMBNAIL_JPEG_QUALITY: u8 = 90;
/// Upper bound on the source pixel count the bounded decoders accept. Those
/// decoders keep memory proportional to the thumbnail, so this only rejects
/// pathological sources that would burn CPU without adding detail.
const MAX_SOURCE_PIXELS: u64 = 256 * 1024 * 1024;

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
/// JPEGs use the pre-rewrite client's libjpeg-turbo scaled-decode path on
/// Linux. Other formats and unsupported JPEGs retain the bounded Rust fallback.
/// Admission accounts for intermediate pixels, thumbnail transformations and a
/// codec workspace reserve. Codec heap overhead is not an OS RSS hard limit.
/// Oversized images fail without replacing an existing cache entry.
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
    let thumbnail_bytes = target_width
        .checked_mul(target_height)
        .and_then(|v| v.checked_mul(16));
    let decoded_bytes = u64::from(header.width)
        .checked_mul(u64::from(header.height))
        .and_then(|v| v.checked_mul(header.bytes_per_pixel));
    let admission = decoded_bytes
        .and_then(|v| v.checked_mul(2))
        .and_then(|v| v.checked_add(expected.size))
        .and_then(|v| v.checked_add(thumbnail_bytes?))
        .and_then(|v| v.checked_add(WORKSPACE_RESERVE));
    let within_budget = admission.is_some_and(|bytes| bytes <= DECODE_BUDGET);
    let plan = Plan {
        source,
        expected: &expected,
        format,
        header: &header,
        max_edge,
        target_width: target_width as u32,
        target_height: target_height as u32,
        thumbnail_bytes: thumbnail_bytes.unwrap_or(0),
    };
    let mut jpeg_fast = None;
    #[cfg(target_os = "linux")]
    if format == image::ImageFormat::Jpeg {
        let pixels = u64::from(header.width) * u64::from(header.height);
        // libjpeg can scale by at most 1/8. Account for the actual intermediate
        // buffer and its Rust-owned copy, even for extreme aspect ratios.
        let denominator = [8, 4, 2, 1]
            .into_iter()
            .find(|d| longest / d >= max_edge)
            .unwrap_or(1);
        let intermediate = u64::from(header.width.div_ceil(denominator))
            * u64::from(header.height.div_ceil(denominator))
            * 6;
        if pixels <= MAX_SOURCE_PIXELS && intermediate + WORKSPACE_RESERVE <= DECODE_BUDGET {
            if let Ok(decoded) = scaled::decode_jpeg_turbo(&mut file, max_edge, expected.size) {
                jpeg_fast = Some(DynamicImage::ImageRgb8(image::imageops::thumbnail(
                    &decoded,
                    plan.target_width,
                    plan.target_height,
                )));
            }
            check_source(source, &file, &expected)?;
            file.seek(SeekFrom::Start(0))
                .map_err(|e| format!("SourceRead: {e}"))?;
        }
    }
    let mut small = if let Some(decoded) = jpeg_fast {
        decoded
    } else if within_budget {
        decode_full(&plan, &mut file)?
    } else {
        decode_scaled(&plan, &mut file)?
    };
    // Rotate only after reducing the image, avoiding a second full original buffer.
    small.apply_orientation(
        Orientation::from_exif(header.orientation).unwrap_or(Orientation::NoTransforms),
    );
    let rgb = flatten_on_white(small);
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
        JpegEncoder::new_with_quality(&mut writer, THUMBNAIL_JPEG_QUALITY)
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

/// Everything one thumbnail needs: the captured source, its fingerprint and
/// the header the target size was derived from.
struct Plan<'a> {
    source: &'a Path,
    expected: &'a Fingerprint,
    format: image::ImageFormat,
    header: &'a headers::Header,
    max_edge: u32,
    target_width: u32,
    target_height: u32,
    thumbnail_bytes: u64,
}

/// Decode the original at full resolution and reduce it afterwards. This is
/// the sharpest path and stays the default while the admission budget allows
/// it.
fn decode_full(plan: &Plan<'_>, file: &mut File) -> Result<DynamicImage, String> {
    let header = plan.header;
    let longest = header.width.max(header.height);
    check_source_path(file)?;
    let extent = SourceExtent {
        file: file.try_clone().map_err(|e| format!("SourceRead: {e}"))?,
        position: 0,
        limit: plan.expected.size,
    };
    let mut reader = ImageReader::with_format(BufReader::new(extent), plan.format);
    let mut limits = Limits::default();
    limits.max_image_width = Some(header.width);
    limits.max_image_height = Some(header.height);
    limits.max_alloc = Some(
        DECODE_BUDGET
            .saturating_sub(plan.expected.size)
            .saturating_sub(plan.thumbnail_bytes)
            .saturating_sub(WORKSPACE_RESERVE),
    );
    reader.limits(limits);
    let decoded = reader.decode();
    check_source(plan.source, file, plan.expected)?;
    let decoded = decoded.map_err(|e| format!("ThumbnailDecodeFailed: {e}"))?;
    if decoded.width() != header.width || decoded.height() != header.height {
        return Err("SourceChanged: decoded dimensions disagree with captured header".into());
    }
    let reduced = if longest <= plan.max_edge {
        decoded
    } else {
        decoded.thumbnail(plan.target_width, plan.target_height)
    };
    Ok(reduced)
}

/// Derive the thumbnail without materialising the original.
///
/// JPEG frames are decoded with IDCT scaling and PNG rows are streamed, so the
/// peak allocation follows the thumbnail size. Sources beyond
/// [`MAX_SOURCE_PIXELS`], and formats without a bounded decoder, still fail
/// with DecodeBudgetExceeded.
fn decode_scaled(plan: &Plan<'_>, file: &mut File) -> Result<DynamicImage, String> {
    let header = plan.header;
    let pixels = u64::from(header.width).saturating_mul(u64::from(header.height));
    if pixels > MAX_SOURCE_PIXELS {
        return Err(
            "DecodeBudgetExceeded: image exceeds the 256 Mpx thumbnail source limit".into(),
        );
    }
    check_source_path(file)?;
    let extent = SourceExtent {
        file: file.try_clone().map_err(|e| format!("SourceRead: {e}"))?,
        position: 0,
        limit: plan.expected.size,
    };
    let decoded = match plan.format {
        image::ImageFormat::Jpeg => {
            // The JPEG decoder holds the compressed frame in memory.
            let scaled_bytes = u64::from(plan.target_width)
                .checked_mul(u64::from(plan.target_height))
                .and_then(|v| v.checked_mul(3 * 8))
                .unwrap_or(u64::MAX);
            let admission = plan
                .expected
                .size
                .checked_add(scaled_bytes)
                .and_then(|v| v.checked_add(WORKSPACE_RESERVE));
            if admission.is_none_or(|bytes| bytes > DECODE_BUDGET) {
                return Err(
                    "DecodeBudgetExceeded: image exceeds the 128 MiB thumbnail decode budget"
                        .into(),
                );
            }
            scaled::decode_jpeg(
                extent,
                header.width,
                header.height,
                plan.target_width,
                plan.target_height,
            )
        }
        image::ImageFormat::Png => scaled::decode_png(
            extent,
            header.width,
            header.height,
            plan.target_width,
            plan.target_height,
        ),
        _ => {
            return Err(
                "DecodeBudgetExceeded: image exceeds the 128 MiB thumbnail decode budget".into(),
            );
        }
    };
    check_source(plan.source, file, plan.expected)?;
    let decoded = decoded?;
    Ok(DynamicImage::ImageRgb8(decoded))
}

/// Rewind the source before a decoder reads it from the beginning.
fn check_source_path(file: &mut File) -> Result<(), String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|e| format!("SourceRead: {e}"))?;
    Ok(())
}

/// Flatten transparency onto white, the same opaque result the pre-refactor
/// client produced before it published a thumbnail.
fn flatten_on_white(image: DynamicImage) -> RgbImage {
    match image {
        DynamicImage::ImageRgba8(rgba) => {
            let mut rgb = RgbImage::new(rgba.width(), rgba.height());
            for (target, source) in rgb.pixels_mut().zip(rgba.pixels()) {
                *target = Rgb([
                    blend_on_white(source.0[0], source.0[3]),
                    blend_on_white(source.0[1], source.0[3]),
                    blend_on_white(source.0[2], source.0[3]),
                ]);
            }
            rgb
        }
        DynamicImage::ImageLumaA8(luma) => {
            let mut rgb = RgbImage::new(luma.width(), luma.height());
            for (target, source) in rgb.pixels_mut().zip(luma.pixels()) {
                *target = Rgb([
                    blend_on_white(source.0[0], source.0[1]),
                    blend_on_white(source.0[0], source.0[1]),
                    blend_on_white(source.0[0], source.0[1]),
                ]);
            }
            rgb
        }
        other => other.into_rgb8(),
    }
}

fn blend_on_white(channel: u8, alpha: u8) -> u8 {
    let alpha = u16::from(alpha);
    ((u16::from(channel) * alpha + 255 * (255 - alpha)) / 255) as u8
}

/// Extract only the bounded EXIF IFD1 JPEG, never the original pixels. A missing
/// or malformed EXIF thumbnail is normal and leaves no placeholder cache file.
pub fn prepare_embedded_thumbnail(
    source: &Path,
    size: u64,
    modified_ns: i64,
    destination: &Path,
) -> Result<bool, String> {
    if super::mime_from_extension(source) != Some("image/jpeg") {
        return Ok(false);
    }
    let mut file = File::open(source).map_err(|_| "SourceUnavailable")?;
    let expected = Fingerprint::from_metadata(&file.metadata().map_err(|_| "SourceUnavailable")?)?;
    if expected.size != size || expected.modified_ns != modified_ns {
        return Err("SourceChanged".into());
    }
    check_source(source, &file, &expected)?;
    let mut head = Vec::new();
    Read::by_ref(&mut file)
        .take(256 * 1024)
        .read_to_end(&mut head)
        .map_err(|_| "SourceRead")?;
    let Some((bytes, orientation)) = (|| {
        let tiff = exif::get_exif_attr_from_jpeg(&mut std::io::Cursor::new(head)).ok()?;
        let fields = exif::Reader::new()
            .continue_on_error(true)
            .read_raw(tiff.clone())
            .or_else(|e| e.distill_partial_result(|_| {}))
            .ok()?;
        let offset = fields
            .get_field(exif::Tag::JPEGInterchangeFormat, exif::In::THUMBNAIL)?
            .value
            .get_uint(0)? as usize;
        let length = fields
            .get_field(exif::Tag::JPEGInterchangeFormatLength, exif::In::THUMBNAIL)?
            .value
            .get_uint(0)? as usize;
        let bytes = tiff.get(offset..offset.checked_add(length)?)?;
        if bytes.is_empty() {
            return None;
        }
        let orientation = fields
            .get_field(exif::Tag::Orientation, exif::In::PRIMARY)
            .and_then(|f| f.value.get_uint(0))
            .unwrap_or(1) as u8;
        Some((bytes.to_vec(), orientation))
    })() else {
        return Ok(false);
    };
    let mut reader =
        ImageReader::with_format(std::io::Cursor::new(bytes), image::ImageFormat::Jpeg);
    let mut limits = Limits::default();
    limits.max_image_width = Some(1024);
    limits.max_image_height = Some(1024);
    limits.max_alloc = Some(8 * 1024 * 1024);
    reader.limits(limits);
    let Ok(mut image) = reader.decode() else {
        return Ok(false);
    };
    image.apply_orientation(
        Orientation::from_exif(orientation).unwrap_or(Orientation::NoTransforms),
    );
    fs::create_dir_all(destination.parent().ok_or("CacheUnavailable")?)
        .map_err(|_| "CacheUnavailable")?;
    let mut stage = tempfile::Builder::new()
        .suffix(".jpg")
        .tempfile_in(destination.parent().unwrap())
        .map_err(|_| "CacheUnavailable")?;
    JpegEncoder::new_with_quality(stage.as_file_mut(), 90)
        .encode_image(&image)
        .map_err(|_| "ThumbnailEncodeFailed")?;
    check_source(source, &file, &expected)?;
    stage.persist(destination).map_err(|_| "CacheUnavailable")?;
    Ok(true)
}
