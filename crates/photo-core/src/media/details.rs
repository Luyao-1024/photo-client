use exif::{In, Tag};
use serde::{Deserialize, Serialize};
use std::{
    fs::File,
    io::{BufReader, Read},
    path::Path,
};
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct MediaDetails {
    pub duration_ms: Option<i64>,
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub lens: Option<String>,
    pub exposure: Option<String>,
    pub aperture: Option<String>,
    pub iso: Option<String>,
    pub focal_length: Option<String>,
    pub motion_offset: Option<i64>,
    pub animated: bool,
    pub hdr: bool,
}
pub fn read(path: &Path) -> MediaDetails {
    let mime = super::mime_from_extension(path).unwrap_or("");
    if mime.starts_with("video/") {
        return super::external::probe(path)
            .map(|value| from_video_probe(&value))
            .unwrap_or_default();
    }
    let mut head = Vec::new();
    let mut size = 0;
    if let Ok(file) = File::open(path) {
        size = file.metadata().map(|m| m.len()).unwrap_or(0);
        let _ = file.take(256 * 1024).read_to_end(&mut head);
    }
    read_with_head(path, &head, size)
}
pub(super) fn from_video_probe(value: &serde_json::Value) -> MediaDetails {
    MediaDetails {
        duration_ms: value["format"]["duration"]
            .as_str()
            .and_then(|s| s.parse::<f64>().ok())
            .map(|v| (v * 1000.) as i64),
        ..MediaDetails::default()
    }
}
pub(super) fn read_with_head(path: &Path, head: &[u8], file_len: u64) -> MediaDetails {
    let mime = super::mime_from_extension(path).unwrap_or("");
    let mut details = MediaDetails {
        animated: mime == "image/gif",
        ..MediaDetails::default()
    };
    details.hdr = [
        b"hdrgm:Version".as_slice(),
        b"HDRGainMap".as_slice(),
        b"hdr_capacity_max".as_slice(),
    ]
    .iter()
    .any(|marker| head.windows(marker.len()).any(|w| w == *marker));
    details.animated |= (mime == "image/webp"
        && head.get(12..16) == Some(b"VP8X")
        && head.get(20).is_some_and(|b| b & 2 != 0))
        || (mime == "image/png" && head.windows(4).any(|w| w == b"acTL"));
    let exif = if mime == "image/heic" {
        super::heif::exif(path).and_then(|raw| exif::Reader::new().read_raw(raw).ok())
    } else {
        let from_head = exif::Reader::new()
            .read_from_container(&mut std::io::Cursor::new(head))
            .ok();
        // PNG/WebP can carry EXIF after compressed pixels. Preserve that rare
        // slow path without rereading ordinary JPEG sources during scans.
        from_head.or_else(|| {
            if file_len > head.len() as u64 && matches!(mime, "image/png" | "image/webp") {
                File::open(path).ok().and_then(|file| {
                    exif::Reader::new()
                        .read_from_container(&mut BufReader::new(file))
                        .ok()
                })
            } else {
                None
            }
        })
    };
    if let Some(exif) = exif {
        let text = |tag| {
            exif.get_field(tag, In::PRIMARY).map(|f| {
                f.display_value()
                    .with_unit(&exif)
                    .to_string()
                    .trim_matches('"')
                    .to_string()
            })
        };
        details.camera_make = text(Tag::Make);
        details.camera_model = text(Tag::Model);
        details.lens = text(Tag::LensModel);
        details.exposure = text(Tag::ExposureTime);
        details.aperture = text(Tag::FNumber);
        details.iso = text(Tag::PhotographicSensitivity);
        details.focal_length = text(Tag::FocalLength);
    }
    details.motion_offset = super::motion_photo::detect_with_head(path, head, file_len)
        .map(|info| info.video_offset as i64);
    details
}
