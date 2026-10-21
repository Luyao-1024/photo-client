//! Animated image frames for the viewer.
//!
//! The pre-refactor client decoded every frame of an animated image and
//! played them back in the viewer. The frames are written into the thumbnail
//! cache as JPEG files here, so the UI can stream them one by one instead of
//! holding the whole animation in memory.

use std::fs::{self, File};
use std::io::{BufReader, BufWriter, Write};
use std::path::Path;

use image::codecs::jpeg::JpegEncoder;
use image::{AnimationDecoder, DynamicImage, Rgba, RgbaImage};

use super::thumbnail::THUMBNAIL_JPEG_QUALITY;

/// Frame limits carried over from the pre-refactor client: an endless
/// animation has to stop somewhere, and the decoded pixels stay bounded.
const MAX_FRAMES: usize = 300;
const MAX_DECODED_PIXELS: u64 = 64 * 1024 * 1024;
/// Frames faster than this play at the default cadence instead.
const MIN_FRAME_DELAY_MS: u32 = 20;
const DEFAULT_FRAME_DELAY_MS: u32 = 100;

/// A decoded animation frame kept in the cache.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct AnimatedFrame {
    pub path: String,
    pub delay_ms: u32,
}

/// Decode an animated image into JPEG frames inside `directory`.
///
/// The frames keep the animation's own timing, and transparency is flattened
/// onto white like every other published image. An animation that was decoded
/// before is reused, so opening it again does not decode it twice.
pub fn frames_or_extract(
    source: &Path,
    directory: &Path,
    max_edge: u32,
) -> Result<Vec<AnimatedFrame>, String> {
    if let Some(frames) = cached_frames(directory) {
        return Ok(frames);
    }
    let frames = extract_frames(source, directory, max_edge)?;
    write_manifest(directory, &frames)?;
    Ok(frames)
}

/// Read the frame list of an animation that was decoded before.
fn cached_frames(directory: &Path) -> Option<Vec<AnimatedFrame>> {
    let raw = fs::read_to_string(directory.join("manifest.json")).ok()?;
    let frames: Vec<AnimatedFrame> = serde_json::from_str(&raw).ok()?;
    if frames.is_empty() {
        return None;
    }
    for frame in &frames {
        if !Path::new(&frame.path).is_file() {
            return None;
        }
    }
    Some(frames)
}

fn write_manifest(directory: &Path, frames: &[AnimatedFrame]) -> Result<(), String> {
    let raw = serde_json::to_string(frames).map_err(|_| "LocalMappingFailed".to_owned())?;
    fs::write(directory.join("manifest.json"), raw).map_err(|_| "CacheUnavailable".to_owned())
}

/// Decode an animated image into JPEG frames inside `directory`.
pub fn extract_frames(
    source: &Path,
    directory: &Path,
    max_edge: u32,
) -> Result<Vec<AnimatedFrame>, String> {
    let file = File::open(source).map_err(|error| format!("AnimatedReadFailed: {error}"))?;
    let decoder = image::codecs::gif::GifDecoder::new(BufReader::new(file))
        .map_err(|error| format!("AnimatedDecodeFailed: {error}"))?;
    fs::create_dir_all(directory).map_err(|_| "CacheUnavailable".to_owned())?;
    let mut frames = Vec::new();
    let mut decoded_pixels = 0u64;
    for (index, frame) in decoder.into_frames().enumerate() {
        if index >= MAX_FRAMES {
            return Err(format!(
                "AnimatedBudgetExceeded: the animation exceeds the {MAX_FRAMES} frame limit"
            ));
        }
        let frame = frame.map_err(|error| format!("AnimatedDecodeFailed: {error}"))?;
        let delay = frame_delay(frame.delay());
        let buffer = frame.into_buffer();
        decoded_pixels =
            decoded_pixels.saturating_add(u64::from(buffer.width()) * u64::from(buffer.height()));
        if decoded_pixels > MAX_DECODED_PIXELS {
            return Err(
                "AnimatedBudgetExceeded: the animation exceeds the 64 Mpx decode budget".into(),
            );
        }
        let mut canvas =
            RgbaImage::from_pixel(buffer.width(), buffer.height(), Rgba([255, 255, 255, 255]));
        image::imageops::overlay(&mut canvas, &buffer, 0, 0);
        let mut image = DynamicImage::ImageRgba8(canvas).to_rgb8();
        if max_edge > 0 && image.width().max(image.height()) > max_edge {
            image = image::imageops::thumbnail(&image, max_edge, max_edge);
        }
        let path = directory.join(format!("frame-{index:04}.jpg"));
        write_frame(&path, &image)?;
        frames.push(AnimatedFrame {
            path: path.to_string_lossy().into_owned(),
            delay_ms: delay,
        });
    }
    if frames.is_empty() {
        return Err("AnimatedDecodeFailed: the animation has no frame".into());
    }
    Ok(frames)
}

/// Frame cadence of the pre-refactor client: the animation's own delay, with
/// a floor that keeps a zero-delay frame from spinning.
fn frame_delay(delay: image::Delay) -> u32 {
    let (numerator, denominator) = delay.numer_denom_ms();
    if denominator == 0 || numerator == 0 {
        return DEFAULT_FRAME_DELAY_MS;
    }
    let milliseconds = (u64::from(numerator)).div_ceil(u64::from(denominator)) as u32;
    if milliseconds < MIN_FRAME_DELAY_MS {
        DEFAULT_FRAME_DELAY_MS
    } else {
        milliseconds
    }
}

fn write_frame(path: &Path, image: &image::RgbImage) -> Result<(), String> {
    let file = File::create(path).map_err(|_| "CacheUnavailable".to_owned())?;
    let mut writer = BufWriter::new(file);
    JpegEncoder::new_with_quality(&mut writer, THUMBNAIL_JPEG_QUALITY)
        .encode_image(image)
        .map_err(|error| format!("AnimatedEncodeFailed: {error}"))?;
    writer.flush().map_err(|_| "CacheUnavailable".to_owned())
}
