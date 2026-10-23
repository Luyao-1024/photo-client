//! Bounded-memory decoding for thumbnail generation.
//!
//! The pre-refactor client decoded JPEG originals through libjpeg's IDCT
//! scaling, so a 48 MP photo never materialised at full size. These helpers
//! keep that property inside the Rust core: JPEG decodes through
//! `jpeg-decoder`'s IDCT-scaled path and PNG decodes row by row, so the peak
//! allocation follows the thumbnail size instead of the original.

use std::io::{BufReader, Read, Seek};

use image::RgbImage;

/// Decode a JPEG into an RGB image bounded by the requested size.
///
/// The frame is decoded with libjpeg-compatible IDCT scaling (1/8, 1/4, 1/2),
/// the same trick the pre-refactor client used, and then reduced to the
/// requested bounds. The original pixels are never allocated.
pub(super) fn decode_jpeg(
    reader: impl Read,
    expected_width: u32,
    expected_height: u32,
    target_width: u32,
    target_height: u32,
) -> Result<RgbImage, String> {
    // The entropy parser requests individual bytes. Without a buffer each
    // byte reaches File::read (especially costly through Android shared storage).
    let mut decoder = jpeg_decoder::Decoder::new(BufReader::with_capacity(64 * 1024, reader));
    decoder
        .read_info()
        .map_err(|error| format!("ThumbnailDecodeFailed: {error}"))?;
    let info = decoder
        .info()
        .ok_or("ThumbnailDecodeFailed: missing JPEG frame")?;
    if u32::from(info.width) != expected_width || u32::from(info.height) != expected_height {
        return Err("SourceChanged: decoded dimensions disagree with captured header".into());
    }
    let (scaled_width, scaled_height) = decoder
        .scale(
            target_width.clamp(1, u16::MAX as u32) as u16,
            target_height.clamp(1, u16::MAX as u32) as u16,
        )
        .map_err(|error| format!("ThumbnailDecodeFailed: {error}"))?;
    let pixels = decoder
        .decode()
        .map_err(|error| format!("ThumbnailDecodeFailed: {error}"))?;
    let width = u32::from(scaled_width);
    let height = u32::from(scaled_height);
    let decoded = match decoder.info().map(|info| info.pixel_format) {
        Some(jpeg_decoder::PixelFormat::RGB24) => RgbImage::from_raw(width, height, pixels)
            .ok_or_else(|| "ThumbnailDecodeFailed: unexpected JPEG payload length".to_owned())?,
        Some(jpeg_decoder::PixelFormat::L8) => {
            let mut image = RgbImage::new(width, height);
            for (target, source) in image.pixels_mut().zip(pixels.iter()) {
                *target = image::Rgb([*source, *source, *source]);
            }
            image
        }
        _ => return Err("ThumbnailDecodeFailed: unsupported JPEG pixel format".into()),
    };
    Ok(image::imageops::thumbnail(
        &decoded,
        target_width,
        target_height,
    ))
}

/// Decode a PNG into an RGB image of the requested size.
///
/// Rows are streamed and reduced with a box filter, so the decoder never holds
/// more than one source row plus the target buffer. Interlaced PNGs keep the
/// general decoder because their rows are not delivered in display order.
pub(super) fn decode_png(
    reader: impl Read + Seek,
    expected_width: u32,
    expected_height: u32,
    target_width: u32,
    target_height: u32,
) -> Result<RgbImage, String> {
    let mut decoder = png::Decoder::new(BufReader::new(reader));
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder
        .read_info()
        .map_err(|error| format!("ThumbnailDecodeFailed: {error}"))?;
    let (width, height, interlaced, channels) = {
        let info = reader.info();
        (
            info.width,
            info.height,
            info.interlaced,
            png_row_channels(info),
        )
    };
    if width != expected_width || height != expected_height {
        return Err("SourceChanged: decoded dimensions disagree with captured header".into());
    }
    if interlaced {
        return Err("ThumbnailDecodeFailed: interlaced PNG needs the general decoder".into());
    }
    let channels = channels.ok_or("ThumbnailDecodeFailed: unsupported PNG layout")?;
    let columns: Vec<u32> = (0..width).map(|x| x * target_width / width).collect();
    let mut sums = vec![0u32; target_width as usize * target_height as usize * 3];
    let mut counts = vec![0u32; target_width as usize * target_height as usize];
    let mut row_index = 0u32;
    while let Some(row) = reader
        .next_row()
        .map_err(|error| format!("ThumbnailDecodeFailed: {error}"))?
    {
        if row.data().len() != width as usize * channels {
            return Err("ThumbnailDecodeFailed: unexpected PNG row length".into());
        }
        let target_row = row_index * target_height / height;
        let base = target_row as usize * target_width as usize;
        for (x, pixel) in row.data().chunks_exact(channels).enumerate() {
            let index = base + columns[x] as usize;
            let (red, green, blue) = match channels {
                1 => (pixel[0], pixel[0], pixel[0]),
                2 => {
                    let value = blend_on_white(pixel[0], pixel[1]);
                    (value, value, value)
                }
                3 => (pixel[0], pixel[1], pixel[2]),
                _ => (
                    blend_on_white(pixel[0], pixel[3]),
                    blend_on_white(pixel[1], pixel[3]),
                    blend_on_white(pixel[2], pixel[3]),
                ),
            };
            let offset = index * 3;
            sums[offset] += u32::from(red);
            sums[offset + 1] += u32::from(green);
            sums[offset + 2] += u32::from(blue);
            counts[index] += 1;
        }
        row_index += 1;
    }
    if row_index != height {
        return Err("ThumbnailDecodeFailed: truncated PNG rows".into());
    }
    let mut image = RgbImage::new(target_width, target_height);
    for (index, target) in image.pixels_mut().enumerate() {
        let count = counts[index];
        if count == 0 {
            continue;
        }
        let offset = index * 3;
        *target = image::Rgb([
            (sums[offset] / count) as u8,
            (sums[offset + 1] / count) as u8,
            (sums[offset + 2] / count) as u8,
        ]);
    }
    Ok(image)
}

/// Number of bytes per pixel the PNG decoder produces for the requested
/// transformations. Mirrors the decoder's own expansion rules: palettes and
/// `tRNS` chunks gain channels, grayscale stays single channel.
fn png_row_channels(info: &png::Info<'_>) -> Option<usize> {
    let transparency = info.trns.is_some();
    match info.color_type {
        png::ColorType::Indexed => Some(if transparency { 4 } else { 3 }),
        png::ColorType::Grayscale => Some(if transparency { 2 } else { 1 }),
        png::ColorType::GrayscaleAlpha => Some(2),
        png::ColorType::Rgb => Some(if transparency { 4 } else { 3 }),
        png::ColorType::Rgba => Some(4),
    }
}

/// Composite one channel over an opaque white background, the same result the
/// pre-refactor client produced before it flattened transparency.
fn blend_on_white(channel: u8, alpha: u8) -> u8 {
    let alpha = u16::from(alpha);
    ((u16::from(channel) * alpha + 255 * (255 - alpha)) / 255) as u8
}

/// Linux uses the same libjpeg-turbo backend as the pre-rewrite client. It
/// reads a duplicate of the already fingerprint-checked descriptor; it never
/// reopens a path that could have been replaced between validation and decode.
#[cfg(target_os = "linux")]
pub(super) fn decode_jpeg_turbo(
    file: &mut std::fs::File,
    max_edge: u32,
    source_size: u64,
) -> Result<RgbImage, String> {
    use std::ffi::{c_char, c_int, c_void};
    use std::io::{Seek, SeekFrom};
    use std::os::fd::AsRawFd;
    unsafe extern "C" {
        fn photo_jpeg_create() -> *mut c_void;
        fn photo_jpeg_destroy(ptr: *mut c_void);
        fn photo_jpeg_decode_scaled(
            ptr: *mut c_void,
            fd: c_int,
            source_size: u64,
            edge: c_int,
            width: *mut c_int,
            height: *mut c_int,
            error: *mut c_char,
            error_size: c_int,
        ) -> c_int;
        fn photo_jpeg_take_buffer(ptr: *mut c_void, length: *mut usize) -> *mut u8;
        fn photo_jpeg_free_buffer(ptr: *mut c_void);
    }
    file.seek(SeekFrom::Start(0))
        .map_err(|e| format!("SourceRead: {e}"))?;
    // The C shim contains every libjpeg call within its setjmp error boundary.
    unsafe {
        let shim = photo_jpeg_create();
        if shim.is_null() {
            return Err("ThumbnailDecodeFailed: JPEG allocation".into());
        }
        let (mut width, mut height) = (0, 0);
        let mut error = [0_i8; 256];
        let result = photo_jpeg_decode_scaled(
            shim,
            file.as_raw_fd(),
            source_size,
            max_edge.min(c_int::MAX as u32) as c_int,
            &mut width,
            &mut height,
            error.as_mut_ptr(),
            error.len() as c_int,
        );
        if result != 0 {
            photo_jpeg_destroy(shim);
            return Err("ThumbnailDecodeFailed: libjpeg rejected source".into());
        }
        let mut length = 0;
        let buffer = photo_jpeg_take_buffer(shim, &mut length);
        photo_jpeg_destroy(shim);
        if buffer.is_null()
            || width <= 0
            || height <= 0
            || length != width as usize * height as usize * 3
        {
            if !buffer.is_null() {
                photo_jpeg_free_buffer(buffer.cast());
            }
            return Err("ThumbnailDecodeFailed: invalid JPEG output".into());
        }
        let pixels = std::slice::from_raw_parts(buffer, length).to_vec();
        photo_jpeg_free_buffer(buffer.cast());
        RgbImage::from_raw(width as u32, height as u32, pixels)
            .ok_or_else(|| "ThumbnailDecodeFailed: invalid JPEG output".into())
    }
}

#[cfg(test)]
mod io_tests {
    use super::*;
    use std::{
        io::Cursor,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
    };

    struct CountingReader {
        input: Cursor<Vec<u8>>,
        calls: Arc<AtomicUsize>,
        small: Arc<AtomicUsize>,
    }
    impl Read for CountingReader {
        fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            if output.len() < 1024 {
                self.small.fetch_add(1, Ordering::Relaxed);
            }
            self.input.read(output)
        }
    }

    #[test]
    fn jpeg_scaled_decode_batches_compressed_source_reads() {
        let source = RgbImage::from_fn(1024, 768, |x, y| {
            let hash = x.wrapping_mul(2654435761) ^ y.wrapping_mul(2246822519);
            image::Rgb([hash as u8, (hash >> 8) as u8, (hash >> 16) as u8])
        });
        let mut bytes = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut bytes, 90)
            .encode_image(&source)
            .unwrap();
        let length = bytes.len();
        let calls = Arc::new(AtomicUsize::new(0));
        let small = Arc::new(AtomicUsize::new(0));
        let decoded = decode_jpeg(
            CountingReader {
                input: Cursor::new(bytes),
                calls: calls.clone(),
                small: small.clone(),
            },
            1024,
            768,
            128,
            96,
        )
        .unwrap();
        let calls = calls.load(Ordering::Relaxed);
        let small = small.load(Ordering::Relaxed);
        eprintln!("jpeg_scaled_io encoded_bytes={length} source_reads={calls} small_reads={small}");
        assert_eq!(decoded.dimensions(), (128, 96));
        assert!(
            calls <= length.div_ceil(64 * 1024) + 4,
            "compressed JPEG input must be buffered: {calls} reads for {length} bytes"
        );
        assert_eq!(small, 0, "decoder byte reads must not reach the source");
    }
}
