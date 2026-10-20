//! L03-02: rescans never duplicate photos and cancelled scans keep accepted
//! batches queryable. L03-04: stale decode results cannot overwrite a newer
//! content_version.
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, UNIX_EPOCH};

use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
use photo_core::local_library::{LocalLibrary, MediaInput, PhotoFilter};
use photo_core::media::{DiscoveredMedia, prepare_thumbnail, scan_paths};
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

fn as_input(row: &DiscoveredMedia) -> MediaInput {
    MediaInput {
        path: row.path.to_str().unwrap().into(),
        name: row.display_name.clone(),
        parent: row.parent_path.to_str().unwrap().into(),
        size_bytes: row.size_bytes,
        modified_ns: row.modified_ns,
        mime_type: row.mime_type.clone(),
        width: row.width,
        height: row.height,
        orientation: row.orientation,
        capture_time_ms: row.capture_time_ms,
    }
}

fn scan_into(
    library: &LocalLibrary,
    source: &str,
    roots: &[PathBuf],
) -> photo_core::media::ScanSummary {
    scan_paths(roots, &AtomicBool::new(false), |batch| {
        library
            .upsert_batch(source.to_owned(), batch.iter().map(as_input).collect())
            .map(|_| ())
    })
    .unwrap()
}

fn all_ids(library: &LocalLibrary) -> Vec<String> {
    let mut ids = Vec::new();
    let mut cursor = None;
    loop {
        let page = library.query(PhotoFilter::default(), cursor, 100).unwrap();
        ids.extend(page.items.iter().map(|p| p.id.clone()));
        match page.next_cursor {
            Some(next) => cursor = Some(next),
            None => return ids,
        }
    }
}

fn write_png(folder: &Path, name: &str, width: u32, height: u32) -> PathBuf {
    let path = folder.join(name);
    fs::write(&path, image_bytes(ImageFormat::Png, width, height)).unwrap();
    path
}

#[test]
fn rescan_of_the_same_directory_never_duplicates_photos() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let nested = photos.path().join("子目录");
    fs::create_dir(&nested).unwrap();
    for index in 0..5 {
        write_png(photos.path(), &format!("photo-{index}.png"), 8, 4);
    }
    write_png(&nested, "deep.png", 8, 4);

    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(photos.path()).unwrap();
    // Re-linking the same directory reuses the existing source row.
    assert_eq!(library.add_source(photos.path()).unwrap(), source);

    let summary = scan_into(&library, &source, &[photos.path().to_path_buf()]);
    assert_eq!(summary.discovered, 6);
    let first = library.query(PhotoFilter::default(), None, 100).unwrap();
    assert_eq!(first.total, 6);
    assert!(first.items.iter().all(|p| p.content_version == 1));
    let ids: HashSet<String> = first.items.iter().map(|p| p.id.clone()).collect();

    // Rescanning and re-upserting the identical tree changes nothing.
    let summary = scan_into(&library, &source, &[photos.path().to_path_buf()]);
    assert_eq!(summary.discovered, 6);
    let second = library.query(PhotoFilter::default(), None, 100).unwrap();
    assert_eq!(second.total, 6);
    assert_eq!(second.revision, first.revision);
    assert_eq!(
        second
            .items
            .iter()
            .map(|p| p.id.clone())
            .collect::<HashSet<_>>(),
        ids
    );
    assert!(second.items.iter().all(|p| p.content_version == 1));
    assert_eq!(library.info().unwrap().count, 6);
}

#[test]
fn cancelled_scan_keeps_accepted_batches_queryable() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let data = image_bytes(ImageFormat::Jpeg, 2, 2);
    for index in 0..205 {
        fs::write(photos.path().join(format!("{index}.jpg")), &data).unwrap();
    }
    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(photos.path()).unwrap();

    let cancel = AtomicBool::new(false);
    let writer = library.clone();
    let sink = source.clone();
    let summary = scan_paths(&[photos.path().to_path_buf()], &cancel, |batch| {
        writer
            .upsert_batch(sink.clone(), batch.iter().map(as_input).collect())
            .map(|_| ())?;
        cancel.store(true, Ordering::Relaxed);
        Ok(())
    })
    .unwrap();
    assert!(summary.cancelled);
    assert_eq!(summary.discovered, 100);

    // The accepted batch survives the cancellation and is fully queryable.
    let page = library.query(PhotoFilter::default(), None, 100).unwrap();
    assert_eq!(page.total, 100);
    assert_eq!(page.items.len(), 100);
    let accepted: HashSet<String> = page.items.iter().map(|p| p.id.clone()).collect();

    // A later full rescan completes the remainder without duplicating anything.
    let summary = scan_into(&library, &source, &[photos.path().to_path_buf()]);
    assert_eq!(summary.discovered, 205);
    assert_eq!(
        library
            .query(PhotoFilter::default(), None, 100)
            .unwrap()
            .total,
        205
    );
    let ids = all_ids(&library);
    assert_eq!(ids.len(), 205);
    let unique: HashSet<&String> = ids.iter().collect();
    assert_eq!(unique.len(), 205);
    assert!(accepted.iter().all(|id| unique.contains(id)));
}

#[test]
fn stale_thumbnail_results_cannot_overwrite_a_newer_content_version() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let cache = TempDir::new().unwrap();
    let path = write_png(photos.path(), "source.png", 40, 20);

    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(photos.path()).unwrap();
    scan_into(&library, &source, std::slice::from_ref(&path));
    let stale = one(&path);
    let page = library.query(PhotoFilter::default(), None, 10).unwrap();
    let media_id = page.items[0].id.clone();
    assert_eq!(page.items[0].content_version, 1);

    let v1 = cache.path().join("v1.jpg");
    prepare_thumbnail(&stale.path, stale.size_bytes, stale.modified_ns, 16, &v1).unwrap();
    let v1_bytes = fs::read(&v1).unwrap();

    // The source is modified behind the running pipeline and the library
    // advances content_version once the change is ingested.
    fs::write(&path, image_bytes(ImageFormat::Png, 40, 30)).unwrap();
    File::open(&path)
        .unwrap()
        .set_modified(UNIX_EPOCH + Duration::from_secs(2_000_000))
        .unwrap();
    scan_into(&library, &source, std::slice::from_ref(&path));
    let fresh = library.photo(media_id.clone()).unwrap();
    assert_eq!(fresh.content_version, 2);
    let current = one(&path);

    // A decode/cache commit still carrying the version-1 fingerprint is
    // rejected at the version recheck and must not touch published results.
    let error = prepare_thumbnail(&path, stale.size_bytes, stale.modified_ns, 16, &v1).unwrap_err();
    assert!(error.starts_with("SourceChanged"), "{error}");
    assert_eq!(fs::read(&v1).unwrap(), v1_bytes);
    let error =
        prepare_thumbnail(&path, current.size_bytes, stale.modified_ns, 16, &v1).unwrap_err();
    assert!(error.starts_with("SourceChanged"), "{error}");
    assert_eq!(fs::read(&v1).unwrap(), v1_bytes);

    // The current fingerprint publishes into the version-2 cache slot.
    let v2 = cache.path().join("v2.jpg");
    prepare_thumbnail(
        &current.path,
        current.size_bytes,
        current.modified_ns,
        16,
        &v2,
    )
    .unwrap();
    assert!(fs::read(&v2).unwrap().starts_with(b"\xff\xd8"));
    assert_eq!(fs::read(&v1).unwrap(), v1_bytes);
    assert_eq!(library.photo(media_id).unwrap().content_version, 2);
}

fn one(path: &Path) -> DiscoveredMedia {
    let mut rows = Vec::new();
    scan_paths(&[path.to_path_buf()], &AtomicBool::new(false), |batch| {
        rows.extend(batch);
        Ok(())
    })
    .unwrap();
    assert_eq!(rows.len(), 1);
    rows.pop().unwrap()
}
