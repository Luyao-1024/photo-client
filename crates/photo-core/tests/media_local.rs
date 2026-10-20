use std::fs::{self, File};
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, UNIX_EPOCH};

use image::codecs::png::PngEncoder;
use image::{DynamicImage, ExtendedColorType, ImageEncoder, ImageFormat, Rgb, RgbImage};
use photo_core::media::{DiscoveredMedia, ScanSummary, prepare_thumbnail, scan_paths};
use tempfile::TempDir;

fn image_bytes(format: ImageFormat, width: u32, height: u32) -> Vec<u8> {
    let image = RgbImage::from_fn(width, height, |x, y| {
        let colors = [[240, 20, 20], [20, 240, 20], [20, 20, 240], [240, 240, 20]];
        Rgb(colors[usize::from(y >= height / 2) * 2 + usize::from(x >= width / 2)])
    });
    let mut cursor = Cursor::new(Vec::new());
    DynamicImage::ImageRgb8(image)
        .write_to(&mut cursor, format)
        .unwrap();
    cursor.into_inner()
}

fn collect(paths: &[PathBuf]) -> (ScanSummary, Vec<DiscoveredMedia>) {
    let mut found = Vec::new();
    let summary = scan_paths(paths, &AtomicBool::new(false), |batch| {
        assert!(!batch.is_empty());
        assert!(batch.len() <= 100);
        found.extend(batch);
        Ok(())
    })
    .unwrap();
    (summary, found)
}

fn one(path: &Path) -> DiscoveredMedia {
    let (summary, mut rows) = collect(&[path.to_path_buf()]);
    assert_eq!(summary.discovered, 1, "{summary:?}");
    assert_eq!(summary.failed, 0);
    rows.pop().unwrap()
}

fn thumbnail(row: &DiscoveredMedia, edge: u32, destination: &Path) -> Result<(), String> {
    prepare_thumbnail(
        &row.path,
        row.size_bytes,
        row.modified_ns,
        edge,
        destination,
    )
}

fn ifd_entry(tag: u16, kind: u16, count: u32, value: [u8; 4]) -> Vec<u8> {
    [
        tag.to_le_bytes().as_slice(),
        kind.to_le_bytes().as_slice(),
        count.to_le_bytes().as_slice(),
        &value,
    ]
    .concat()
}

fn exif_tiff(orientation: u8, capture: Option<(&str, Option<&str>)>) -> Vec<u8> {
    let mut raw = b"II\x2a\0\x08\0\0\0".to_vec();
    raw.extend_from_slice(&(if capture.is_some() { 2u16 } else { 1u16 }).to_le_bytes());
    raw.extend(ifd_entry(0x0112, 3, 1, [orientation, 0, 0, 0]));
    if let Some((date, offset)) = capture {
        let exif_ifd_offset = 8 + 2 + 2 * 12 + 4;
        raw.extend(ifd_entry(
            0x8769,
            4,
            1,
            (exif_ifd_offset as u32).to_le_bytes(),
        ));
        raw.extend_from_slice(&0u32.to_le_bytes());
        let count = if offset.is_some() { 3u16 } else { 1u16 };
        raw.extend_from_slice(&count.to_le_bytes());
        let date_data = exif_ifd_offset + 2 + count as usize * 12 + 4;
        raw.extend(ifd_entry(
            0x9003,
            2,
            (date.len() + 1) as u32,
            (date_data as u32).to_le_bytes(),
        ));
        if let Some(offset) = offset {
            raw.extend(ifd_entry(
                0x9011,
                2,
                (offset.len() + 1) as u32,
                ((date_data + date.len() + 1) as u32).to_le_bytes(),
            ));
            raw.extend(ifd_entry(0x9291, 2, 4, *b"123\0"));
        }
        raw.extend_from_slice(&0u32.to_le_bytes());
        raw.extend_from_slice(date.as_bytes());
        raw.push(0);
        if let Some(offset) = offset {
            raw.extend_from_slice(offset.as_bytes());
            raw.push(0);
        }
    } else {
        raw.extend_from_slice(&0u32.to_le_bytes());
    }
    raw
}

fn jpeg_with_exif(orientation: u8, capture: Option<(&str, Option<&str>)>) -> Vec<u8> {
    let jpeg = image_bytes(ImageFormat::Jpeg, 96, 64);
    let metadata = [b"Exif\0\0".as_slice(), &exif_tiff(orientation, capture)].concat();
    let mut output = jpeg[..2].to_vec();
    output.extend_from_slice(&[0xff, 0xe1]);
    output.extend_from_slice(&((metadata.len() + 2) as u16).to_be_bytes());
    output.extend(metadata);
    output.extend_from_slice(&jpeg[2..]);
    output
}

fn assert_no_temporaries(parent: &Path) {
    if !parent.exists() {
        return;
    }
    for path in fs::read_dir(parent).unwrap() {
        assert!(
            !path
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".photo-thumb-")
        );
    }
}

#[test]
fn scan_unicode_and_spaces_preserves_paths_and_isolates_bad_or_unsupported_files() {
    let temp = TempDir::new().unwrap();
    let folder = temp.path().join("旅行 相册");
    fs::create_dir(&folder).unwrap();
    for (name, format, mime) in [
        ("照片 一.JPEG", ImageFormat::Jpeg, "image/jpeg"),
        ("照片 二.PNG", ImageFormat::Png, "image/png"),
        ("照片 三.WeBp", ImageFormat::WebP, "image/webp"),
    ] {
        let path = folder.join(name);
        let original = image_bytes(format, 40, 20);
        fs::write(&path, &original).unwrap();
        let row = one(&path);
        assert_eq!(row.path, path);
        assert_eq!(row.display_name, name);
        assert_eq!(row.parent_path, folder);
        assert_eq!(row.mime_type, mime);
        assert_eq!((row.width, row.height), (Some(40), Some(20)));
        assert_eq!(row.orientation, 1);
        assert_eq!(row.size_bytes, original.len() as u64);
        assert_eq!(
            row.modified_ns,
            fs::metadata(&path)
                .unwrap()
                .modified()
                .unwrap()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos() as i64
        );
        assert_eq!(fs::read(path).unwrap(), original);
    }
    fs::write(folder.join("坏图.jpg"), b"not JPEG").unwrap();
    fs::write(
        folder.join("ignored.gif"),
        image_bytes(ImageFormat::Png, 2, 2),
    )
    .unwrap();
    fs::write(folder.join("no-extension"), b"skip").unwrap();
    let (summary, rows) = collect(&[folder]);
    assert_eq!(
        (summary.discovered, summary.failed, summary.skipped),
        (3, 1, 2)
    );
    assert_eq!(rows.len(), 3);
}

#[test]
fn recursive_discovery_streams_batches_before_finishing_the_root() {
    let temp = TempDir::new().unwrap();
    let data = image_bytes(ImageFormat::Png, 2, 2);
    for index in 0..205 {
        fs::write(temp.path().join(format!("{index}.png")), &data).unwrap();
    }
    let mut sizes = Vec::new();
    let summary = scan_paths(
        &[temp.path().to_path_buf()],
        &AtomicBool::new(false),
        |batch| {
            sizes.push(batch.len());
            Ok(())
        },
    )
    .unwrap();
    assert_eq!(sizes, [100, 100, 5]);
    assert_eq!(summary.discovered, 205);
    assert_eq!(
        (summary.failed, summary.skipped, summary.cancelled),
        (0, 0, false)
    );
}

#[test]
fn cancellation_before_start_and_at_first_batch_stops_discovery() {
    let temp = TempDir::new().unwrap();
    let cancel = AtomicBool::new(true);
    let summary = scan_paths(&[temp.path().join("does not exist")], &cancel, |_| {
        panic!("cancelled scan cannot publish")
    })
    .unwrap();
    assert_eq!(
        summary,
        ScanSummary {
            cancelled: true,
            ..ScanSummary::default()
        }
    );
    let data = image_bytes(ImageFormat::Jpeg, 2, 2);
    for index in 0..205 {
        fs::write(temp.path().join(format!("{index}.jpg")), &data).unwrap();
    }
    cancel.store(false, Ordering::Relaxed);
    let mut calls = 0;
    let summary = scan_paths(&[temp.path().to_path_buf()], &cancel, |batch| {
        assert_eq!(batch.len(), 100);
        calls += 1;
        cancel.store(true, Ordering::Relaxed);
        Ok(())
    })
    .unwrap();
    assert_eq!(calls, 1);
    assert_eq!(summary.discovered, 100);
    assert!(summary.cancelled);
}

#[test]
fn callback_failures_propagate_and_missing_roots_do_not_hide_valid_files() {
    let temp = TempDir::new().unwrap();
    let path = temp.path().join("valid.png");
    fs::write(&path, image_bytes(ImageFormat::Png, 3, 2)).unwrap();
    let (summary, _) = collect(&[temp.path().join("missing"), path.clone()]);
    assert_eq!((summary.discovered, summary.failed), (1, 1));
    let error = scan_paths(&[path], &AtomicBool::new(false), |_| {
        Err("writer unavailable".into())
    })
    .unwrap_err();
    assert_eq!(error, "writer unavailable");
}

#[test]
#[cfg(unix)]
fn scanning_skips_leaf_and_directory_symlinks_including_explicit_roots() {
    use std::os::unix::fs::symlink;
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source");
    let external = temp.path().join("external");
    fs::create_dir(&source).unwrap();
    fs::create_dir(&external).unwrap();
    let valid = source.join("valid.png");
    fs::write(&valid, image_bytes(ImageFormat::Png, 2, 2)).unwrap();
    fs::write(
        external.join("must not follow.png"),
        image_bytes(ImageFormat::Png, 2, 2),
    )
    .unwrap();
    symlink(&valid, source.join("linked.png")).unwrap();
    symlink(&external, source.join("linked directory")).unwrap();
    let (summary, _) = collect(&[source.clone(), source.join("linked.png")]);
    assert_eq!(
        (summary.discovered, summary.skipped, summary.failed),
        (1, 3, 0)
    );
}

#[test]
fn thumbnails_are_jpeg_aspect_preserving_and_leave_read_only_originals_unchanged() {
    let temp = TempDir::new().unwrap();
    let path = temp.path().join("源 图像.png");
    let original = image_bytes(ImageFormat::Png, 400, 200);
    fs::write(&path, &original).unwrap();
    let row = one(&path);
    let mut permissions = fs::metadata(&path).unwrap().permissions();
    permissions.set_readonly(true);
    fs::set_permissions(&path, permissions).unwrap();
    let destination = temp.path().join("cache/thumb.jpg");
    thumbnail(&row, 128, &destination).unwrap();
    assert!(fs::read(&destination).unwrap().starts_with(b"\xff\xd8"));
    let output = image::open(&destination).unwrap();
    assert_eq!((output.width(), output.height()), (128, 64));
    assert_eq!(fs::read(&path).unwrap(), original);
    assert_eq!(one(&path).modified_ns, row.modified_ns);
    assert_no_temporaries(destination.parent().unwrap());
}

#[test]
fn small_webp_images_are_not_upscaled() {
    let temp = TempDir::new().unwrap();
    let path = temp.path().join("small.webp");
    fs::write(&path, image_bytes(ImageFormat::WebP, 12, 6)).unwrap();
    let destination = temp.path().join("cache/small.jpg");
    thumbnail(&one(&path), 256, &destination).unwrap();
    let output = image::open(destination).unwrap();
    assert_eq!((output.width(), output.height()), (12, 6));
}

#[test]
fn all_eight_exif_orientations_have_correct_dimensions_and_quadrants() {
    let temp = TempDir::new().unwrap();
    let colors = [
        [240i16, 20, 20],
        [20, 240, 20],
        [20, 20, 240],
        [240, 240, 20],
    ];
    let expected = [
        [0, 1, 2, 3],
        [1, 0, 3, 2],
        [3, 2, 1, 0],
        [2, 3, 0, 1],
        [0, 2, 1, 3],
        [2, 0, 3, 1],
        [3, 1, 2, 0],
        [1, 3, 0, 2],
    ];
    for orientation in 1..=8u8 {
        let path = temp.path().join(format!("orientation-{orientation}.jpg"));
        fs::write(&path, jpeg_with_exif(orientation, None)).unwrap();
        let row = one(&path);
        assert_eq!(row.orientation, orientation);
        assert_eq!((row.width, row.height), (Some(96), Some(64)));
        let destination = temp.path().join(format!("cache/{orientation}.jpg"));
        thumbnail(&row, 192, &destination).unwrap();
        let output = image::open(destination).unwrap().into_rgb8();
        let (w, h) = output.dimensions();
        assert_eq!((w, h), if orientation < 5 { (96, 64) } else { (64, 96) });
        for (position, (x, y)) in [
            (w / 4, h / 4),
            (3 * w / 4, h / 4),
            (w / 4, 3 * h / 4),
            (3 * w / 4, 3 * h / 4),
        ]
        .into_iter()
        .enumerate()
        {
            let actual = output.get_pixel(x, y).0;
            let color = colors[expected[orientation as usize - 1][position]];
            assert!(
                actual
                    .into_iter()
                    .zip(color)
                    .all(|(a, b)| (i16::from(a) - b).abs() < 45),
                "orientation {orientation}, quadrant {position}: {actual:?}"
            );
        }
    }
}

#[test]
fn png_exif_orientation_is_applied_after_resizing() {
    let temp = TempDir::new().unwrap();
    let source = RgbImage::from_pixel(80, 40, Rgb([20, 120, 200]));
    let mut png = Vec::new();
    let mut encoder = PngEncoder::new(&mut png);
    encoder.set_exif_metadata(exif_tiff(6, None)).unwrap();
    encoder
        .write_image(source.as_raw(), 80, 40, ExtendedColorType::Rgb8)
        .unwrap();
    let path = temp.path().join("oriented.png");
    fs::write(&path, png).unwrap();
    let row = one(&path);
    assert_eq!(row.orientation, 6);
    let destination = temp.path().join("cache/oriented.jpg");
    thumbnail(&row, 40, &destination).unwrap();
    let image = image::open(destination).unwrap();
    assert_eq!((image.width(), image.height()), (20, 40));
}

#[test]
fn exif_capture_time_requires_an_explicit_valid_offset_and_calendar() {
    let temp = TempDir::new().unwrap();
    for (index, (date, offset, expected)) in [
        ("1970:01:01 08:00:00", Some("+08:00"), Some(123)),
        ("1970:01:01 08:00:00", None, None),
        ("2023:02:29 08:00:00", Some("+00:00"), None),
        ("1970:01:01 00:00:00", Some("+00:99"), None),
    ]
    .into_iter()
    .enumerate()
    {
        let path = temp.path().join(format!("time-{index}.jpg"));
        fs::write(&path, jpeg_with_exif(1, Some((date, offset)))).unwrap();
        assert_eq!(one(&path).capture_time_ms, expected);
    }
}

#[test]
fn source_size_or_mtime_changes_reject_stale_work_and_preserve_existing_cache() {
    let temp = TempDir::new().unwrap();
    let path = temp.path().join("source.png");
    let original = image_bytes(ImageFormat::Png, 40, 20);
    fs::write(&path, &original).unwrap();
    let row = one(&path);
    let destination = temp.path().join("cache.jpg");
    fs::write(&destination, b"previous complete thumbnail").unwrap();
    fs::write(&path, b"source changed length").unwrap();
    assert!(
        thumbnail(&row, 128, &destination)
            .unwrap_err()
            .starts_with("SourceChanged")
    );
    assert_eq!(
        fs::read(&destination).unwrap(),
        b"previous complete thumbnail"
    );
    fs::write(&path, &original).unwrap();
    let row = one(&path);
    File::open(&path)
        .unwrap()
        .set_modified(UNIX_EPOCH + Duration::from_secs(1_000_000))
        .unwrap();
    assert!(
        thumbnail(&row, 128, &destination)
            .unwrap_err()
            .starts_with("SourceChanged")
    );
    assert_eq!(
        fs::read(destination).unwrap(),
        b"previous complete thumbnail"
    );
}

#[test]
fn bad_pixel_data_is_deferred_by_header_scan_and_isolated_during_thumbnail_creation() {
    let temp = TempDir::new().unwrap();
    let mut broken = image_bytes(ImageFormat::Jpeg, 32, 16);
    let sos = broken.windows(2).position(|v| v == [0xff, 0xda]).unwrap();
    broken.truncate(sos + 2);
    let bad = temp.path().join("broken pixels.jpg");
    let good = temp.path().join("good.png");
    fs::write(&bad, &broken).unwrap();
    fs::write(&good, image_bytes(ImageFormat::Png, 32, 16)).unwrap();
    let bad_row = one(&bad); // Dimensions alone do not certify pixel decodability.
    let cache = temp.path().join("cache");
    fs::create_dir(&cache).unwrap();
    let destination = cache.join("bad.jpg");
    fs::write(&destination, b"old complete thumbnail").unwrap();
    assert!(thumbnail(&bad_row, 16, &destination).is_err());
    assert_eq!(fs::read(&destination).unwrap(), b"old complete thumbnail");
    thumbnail(&one(&good), 16, &cache.join("good.jpg")).unwrap();
    assert_eq!(fs::read(&bad).unwrap(), broken);
    assert_no_temporaries(&cache);
}

#[test]
fn oversized_header_is_rejected_before_decode_without_allocating_original_pixels() {
    let temp = TempDir::new().unwrap();
    let mut png = image_bytes(ImageFormat::Png, 1, 1);
    png[16..20].copy_from_slice(&20000u32.to_be_bytes());
    png[20..24].copy_from_slice(&20000u32.to_be_bytes());
    let source = temp.path().join("oversized.png");
    fs::write(&source, &png).unwrap();
    let row = one(&source);
    let destination = temp.path().join("cache.jpg");
    fs::write(&destination, b"old thumbnail").unwrap();
    let error = thumbnail(&row, 256, &destination).unwrap_err();
    assert!(error.starts_with("DecodeBudgetExceeded"), "{error}");
    assert_eq!(fs::read(destination).unwrap(), b"old thumbnail");
    assert_eq!(fs::read(source).unwrap(), png);
}

#[test]
fn zero_edge_and_source_alias_destination_are_rejected() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.png");
    let original = image_bytes(ImageFormat::Png, 32, 16);
    fs::write(&source, &original).unwrap();
    let row = one(&source);
    assert!(
        thumbnail(&row, 0, &temp.path().join("cache.jpg"))
            .unwrap_err()
            .starts_with("InvalidThumbnailBounds")
    );
    assert!(
        thumbnail(&row, 16, &source)
            .unwrap_err()
            .starts_with("UnsafeThumbnailDestination")
    );
    assert_eq!(fs::read(source).unwrap(), original);
}

#[test]
#[cfg(unix)]
fn source_and_destination_symlinks_and_source_hardlink_alias_are_rejected() {
    use std::os::unix::fs::symlink;
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.png");
    fs::write(&source, image_bytes(ImageFormat::Png, 32, 16)).unwrap();
    let row = one(&source);
    let link = temp.path().join("link.png");
    symlink(&source, &link).unwrap();
    assert!(
        prepare_thumbnail(
            &link,
            row.size_bytes,
            row.modified_ns,
            16,
            &temp.path().join("cache.jpg")
        )
        .is_err()
    );
    assert!(
        thumbnail(&row, 16, &link)
            .unwrap_err()
            .starts_with("UnsafeThumbnailDestination")
    );
    let hardlink = temp.path().join("hardlink.png");
    fs::hard_link(&source, &hardlink).unwrap();
    assert!(
        thumbnail(&row, 16, &hardlink)
            .unwrap_err()
            .starts_with("UnsafeThumbnailDestination")
    );
}

#[test]
fn failed_atomic_publish_removes_its_temporary_and_preserves_prior_destination() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source.png");
    fs::write(&source, image_bytes(ImageFormat::Png, 40, 20)).unwrap();
    let destination = temp.path().join("cache/existing-directory.jpg");
    fs::create_dir_all(&destination).unwrap();
    fs::write(destination.join("keep"), b"untouched").unwrap();
    let error = thumbnail(&one(&source), 16, &destination).unwrap_err();
    assert!(error.starts_with("ThumbnailPublishFailed"), "{error}");
    assert_eq!(fs::read(destination.join("keep")).unwrap(), b"untouched");
    assert_no_temporaries(destination.parent().unwrap());
}

#[test]
fn webp_extended_container_exif_is_read_and_oriented() {
    let temp = TempDir::new().unwrap();
    let original = image_bytes(ImageFormat::WebP, 96, 64);
    let mut body = b"WEBP".to_vec();
    body.extend_from_slice(b"VP8X\x0a\0\0\0");
    body.extend_from_slice(&[0x08, 0, 0, 0, 95, 0, 0, 63, 0, 0]);
    body.extend_from_slice(&original[12..]);
    let metadata = exif_tiff(8, None);
    body.extend_from_slice(b"EXIF");
    body.extend_from_slice(&(metadata.len() as u32).to_le_bytes());
    body.extend_from_slice(&metadata);
    if !metadata.len().is_multiple_of(2) {
        body.push(0);
    }
    let mut webp = b"RIFF".to_vec();
    webp.extend_from_slice(&(body.len() as u32).to_le_bytes());
    webp.extend(body);
    let path = temp.path().join("oriented.webp");
    fs::write(&path, webp).unwrap();
    let row = one(&path);
    assert_eq!(row.orientation, 8);
    assert_eq!((row.width, row.height), (Some(96), Some(64)));
    let destination = temp.path().join("cache/webp.jpg");
    thumbnail(&row, 48, &destination).unwrap();
    let image = image::open(destination).unwrap();
    assert_eq!((image.width(), image.height()), (32, 48));
}

#[test]
fn png_exif_after_pixel_chunks_is_found_without_decoding_them_during_scan() {
    let temp = TempDir::new().unwrap();
    let source = RgbImage::from_pixel(80, 40, Rgb([20, 120, 200]));
    let mut png = Vec::new();
    let mut encoder = PngEncoder::new(&mut png);
    encoder.set_exif_metadata(exif_tiff(6, None)).unwrap();
    encoder
        .write_image(source.as_raw(), 80, 40, ExtendedColorType::Rgb8)
        .unwrap();
    let mut exif_chunk = None;
    let mut position = 8;
    while position < png.len() {
        let size = u32::from_be_bytes(png[position..position + 4].try_into().unwrap()) as usize;
        if &png[position + 4..position + 8] == b"eXIf" {
            exif_chunk = Some(
                png.drain(position..position + size + 12)
                    .collect::<Vec<_>>(),
            );
            break;
        }
        position += size + 12;
    }
    // Move the complete chunk including its unchanged CRC immediately before IEND.
    png.splice(png.len() - 12..png.len() - 12, exif_chunk.unwrap());
    let path = temp.path().join("late exif.png");
    fs::write(&path, png).unwrap();
    let row = one(&path);
    assert_eq!(row.orientation, 6);
    let destination = temp.path().join("cache/late.jpg");
    thumbnail(&row, 40, &destination).unwrap();
    let image = image::open(destination).unwrap();
    assert_eq!((image.width(), image.height()), (20, 40));
}
