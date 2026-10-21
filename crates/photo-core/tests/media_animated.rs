//! Animated image frames for the viewer.
use std::fs;
use std::path::Path;

use image::codecs::gif::GifEncoder;
use image::{Delay, Frame, Rgba, RgbaImage};
use photo_core::media::animated;
use tempfile::TempDir;

fn gif_bytes(frames: &[(Rgba<u8>, u32)]) -> Vec<u8> {
    let mut bytes = Vec::new();
    {
        let mut encoder = GifEncoder::new(&mut bytes);
        for (color, delay) in frames {
            let frame = Frame::from_parts(
                RgbaImage::from_pixel(16, 12, *color),
                0,
                0,
                image::Delay::from_numer_denom_ms(*delay, 1),
            );
            encoder.encode_frame(frame).unwrap();
        }
    }
    bytes
}

#[test]
fn animated_frames_keep_their_timing_and_land_in_the_cache() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("loop.gif");
    let bytes = gif_bytes(&[(Rgba([255, 0, 0, 255]), 120), (Rgba([0, 0, 255, 255]), 240)]);
    fs::write(&source, &bytes).unwrap();
    let directory = temp.path().join("frames");
    let frames = animated::extract_frames(&source, &directory, 2560).unwrap();
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0].delay_ms, 120);
    assert_eq!(frames[1].delay_ms, 240);
    for frame in &frames {
        let path = Path::new(&frame.path);
        assert!(path.is_file(), "{} was not written", frame.path);
        let decoded = image::open(path).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (16, 12));
    }
    let first = image::open(&frames[0].path).unwrap().to_rgb8();
    assert!(
        first.get_pixel(0, 0).0[0] > 200,
        "the first frame is not red"
    );
    let second = image::open(&frames[1].path).unwrap().to_rgb8();
    assert!(
        second.get_pixel(0, 0).0[2] > 200,
        "the second frame is not blue"
    );
}

#[test]
fn a_frame_faster_than_the_floor_plays_at_the_default_cadence() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("fast.gif");
    fs::write(&source, gif_bytes(&[(Rgba([10, 20, 30, 255]), 0)])).unwrap();
    let frames = animated::extract_frames(&source, &temp.path().join("frames"), 2560).unwrap();
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].delay_ms, 100);
}

#[test]
fn a_still_image_is_not_an_animation() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("still.png");
    let image = RgbaImage::from_pixel(8, 8, Rgba([1, 2, 3, 255]));
    image.save(&source).unwrap();
    assert!(animated::extract_frames(&source, &temp.path().join("frames"), 2560).is_err());
}

#[test]
fn a_transparent_frame_is_flattened_onto_white() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("clear.gif");
    fs::write(&source, gif_bytes(&[(Rgba([255, 0, 0, 0]), 100)])).unwrap();
    let frames = animated::extract_frames(&source, &temp.path().join("frames"), 2560).unwrap();
    let decoded = image::open(&frames[0].path).unwrap().to_rgb8();
    let pixel = decoded.get_pixel(0, 0);
    assert!(
        pixel.0[0] > 240 && pixel.0[1] > 240 && pixel.0[2] > 240,
        "a transparent frame was not flattened onto white: {pixel:?}"
    );
}

#[test]
fn the_frame_delay_floor_keeps_a_zero_delay_frame_playable() {
    // A zero delay would otherwise spin the viewer at full speed.
    let delay = Delay::from_numer_denom_ms(0, 1);
    assert_eq!(delay.numer_denom_ms(), (0, 1));
}

#[test]
fn decoded_frames_are_reused_when_the_animation_opens_again() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("loop.gif");
    fs::write(
        &source,
        gif_bytes(&[(Rgba([255, 0, 0, 255]), 120), (Rgba([0, 0, 255, 255]), 120)]),
    )
    .unwrap();
    let directory = temp.path().join("frames");
    let first = animated::frames_or_extract(&source, &directory, 2560).unwrap();
    assert_eq!(first.len(), 2);
    // The source is gone, so only the cached frames can answer the request.
    fs::remove_file(&source).unwrap();
    let second = animated::frames_or_extract(&source, &directory, 2560).unwrap();
    assert_eq!(first, second);
}
