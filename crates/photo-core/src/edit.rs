//! Pure image edits used by the editor. All functions are CPU-bound and must
//! run on the bounded media workers; they never touch the filesystem.
use image::{DynamicImage, ImageFormat};

/// Pixel crop rectangle in the *oriented* image's coordinate space.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CropRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

/// A full editor adjustment set. Values are the same ranges the UI exposes.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EditAdjustments {
    /// 0 / 90 / 180 / 270, clockwise.
    pub rotation_degrees: i32,
    pub flip_horizontal: bool,
    pub flip_vertical: bool,
    /// -100..=100, 0 keeps the original exposure.
    pub brightness: i32,
    /// -100..=100.
    pub contrast: i32,
    /// -100..=100.
    pub saturation: i32,
    pub crop: Option<CropRect>,
}

impl EditAdjustments {
    pub fn is_identity(&self) -> bool {
        self.rotation_degrees.rem_euclid(360) == 0
            && !self.flip_horizontal
            && !self.flip_vertical
            && self.brightness == 0
            && self.contrast == 0
            && self.saturation == 0
            && self.crop.is_none()
    }
}

/// Apply rotation, then crop, then colour adjustments. Order matters: cropping
/// uses the rotated geometry the user saw.
pub fn render(image: &DynamicImage, adjustments: EditAdjustments) -> DynamicImage {
    let mut out = match adjustments.rotation_degrees.rem_euclid(360) {
        90 => image.rotate90(),
        180 => image.rotate180(),
        270 => image.rotate270(),
        _ => image.clone(),
    };
    if adjustments.flip_horizontal {
        out = out.fliph();
    }
    if adjustments.flip_vertical {
        out = out.flipv();
    }
    if let Some(crop) = adjustments.crop {
        out = apply_crop(&out, crop);
    }
    apply_color(&out, adjustments)
}

fn apply_crop(image: &DynamicImage, crop: CropRect) -> DynamicImage {
    let max_width = image.width().saturating_sub(crop.x.min(image.width()));
    let max_height = image.height().saturating_sub(crop.y.min(image.height()));
    let width = crop.width.min(max_width).max(1);
    let height = crop.height.min(max_height).max(1);
    image.crop_imm(
        crop.x.min(image.width()),
        crop.y.min(image.height()),
        width,
        height,
    )
}

fn apply_color(image: &DynamicImage, adjustments: EditAdjustments) -> DynamicImage {
    let mut out = image.clone();
    if adjustments.brightness != 0 {
        let amount = (adjustments.brightness.clamp(-100, 100) as f32 / 100.0 * 255.0) as i32;
        out = out.brighten(amount);
    }
    if adjustments.contrast != 0 {
        out = out.adjust_contrast(adjustments.contrast.clamp(-100, 100) as f32);
    }
    if adjustments.saturation != 0 {
        out = adjust_saturation(&out, adjustments.saturation.clamp(-100, 100));
    }
    out
}

/// Rec.601 luma-preserving saturation, matching the original GTK editor.
fn adjust_saturation(image: &DynamicImage, saturation: i32) -> DynamicImage {
    let factor = 1.0 + (saturation as f32 / 100.0);
    let mut rgba = image.to_rgba8();
    for pixel in rgba.pixels_mut() {
        let [r, g, b, a] = pixel.0;
        let (rf, gf, bf) = (r as f32, g as f32, b as f32);
        let luma = 0.299 * rf + 0.587 * gf + 0.114 * bf;
        pixel.0 = [
            scale_from_luma(rf, luma, factor),
            scale_from_luma(gf, luma, factor),
            scale_from_luma(bf, luma, factor),
            a,
        ];
    }
    DynamicImage::ImageRgba8(rgba)
}

fn scale_from_luma(channel: f32, luma: f32, factor: f32) -> u8 {
    (luma + (channel - luma) * factor).round().clamp(0.0, 255.0) as u8
}

/// Encode with the source container's format at a high, visually lossless
/// quality. Only formats the scanner can index are accepted.
pub fn encode(image: &DynamicImage, format: ImageFormat) -> Result<Vec<u8>, String> {
    let mut buffer = Vec::new();
    match format {
        ImageFormat::Jpeg => {
            let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buffer, 92);
            encoder
                .encode_image(&image.to_rgb8())
                .map_err(|_| "EncodeFailed".to_owned())?;
        }
        ImageFormat::Png | ImageFormat::WebP => {
            image
                .write_to(&mut std::io::Cursor::new(&mut buffer), format)
                .map_err(|_| "EncodeFailed".to_owned())?;
        }
        _ => return Err("UnsupportedFormat".into()),
    }
    Ok(buffer)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgba, RgbaImage};

    fn sample() -> DynamicImage {
        let mut image = RgbaImage::new(4, 2);
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            *pixel = Rgba([(x * 60) as u8, (y * 120) as u8, 90, 255]);
        }
        DynamicImage::ImageRgba8(image)
    }

    #[test]
    fn rotations_swap_dimensions() {
        let rotated = render(
            &sample(),
            EditAdjustments {
                rotation_degrees: 90,
                ..Default::default()
            },
        );
        assert_eq!((rotated.width(), rotated.height()), (2, 4));
    }

    #[test]
    fn crop_is_clamped_to_bounds() {
        let cropped = render(
            &sample(),
            EditAdjustments {
                crop: Some(CropRect {
                    x: 2,
                    y: 1,
                    width: 99,
                    height: 99,
                }),
                ..Default::default()
            },
        );
        assert_eq!((cropped.width(), cropped.height()), (2, 1));
    }

    #[test]
    fn identity_detection() {
        assert!(EditAdjustments::default().is_identity());
        // A full turn is still a no-op.
        assert!(
            EditAdjustments {
                rotation_degrees: 360,
                ..Default::default()
            }
            .is_identity()
        );
        assert!(
            !EditAdjustments {
                rotation_degrees: 90,
                ..Default::default()
            }
            .is_identity()
        );
    }

    #[test]
    fn saturation_zero_is_a_no_op() {
        let out = render(&sample(), EditAdjustments::default());
        assert_eq!(out.to_rgba8().into_raw(), sample().to_rgba8().into_raw());
    }
}
