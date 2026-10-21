//! Incremental scanning: a repeated scan only re-reads the files that changed.
//!
//! The scan compares the on-disk fingerprint with the indexed one before it
//! reads any metadata, so an unchanged library costs one stat per file.
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
use photo_core::local_library::{LocalLibrary, MediaInput, PhotoFilter};
use photo_core::media::{DiscoveredMedia, ScanSummary, scan_paths_excluding_known};
use tempfile::TempDir;

fn image_bytes(format: ImageFormat, width: u32, height: u32) -> Vec<u8> {
    let image = RgbImage::from_fn(width, height, |x, y| {
        let colors = [[240, 20, 20], [20, 240, 20], [20, 20, 240], [240, 240, 20]];
        Rgb(colors[usize::from(y >= height / 2) * 2 + usize::from(x >= width / 2)])
    });
    let mut cursor = std::io::Cursor::new(Vec::new());
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

fn write_png(folder: &Path, name: &str, width: u32, height: u32) -> PathBuf {
    let path = folder.join(name);
    fs::write(&path, image_bytes(ImageFormat::Png, width, height)).unwrap();
    path
}

/// Scans a root the way the library does: known fingerprints in, indexed
/// batches out.
fn scan(library: &LocalLibrary, source: &str, root: &Path) -> ScanSummary {
    let known = library.indexed_fingerprints(source).unwrap();
    scan_paths_excluding_known(
        &[root.to_path_buf()],
        &[],
        &AtomicBool::new(false),
        &known,
        |batch| {
            library
                .upsert_batch(source.to_owned(), batch.iter().map(as_input).collect())
                .map(|_| ())
        },
    )
    .unwrap()
}

#[test]
fn a_repeated_scan_only_reads_the_files_that_changed() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(photos.path()).unwrap();
    write_png(photos.path(), "one.png", 4, 4);
    write_png(photos.path(), "two.png", 6, 6);

    let first = scan(&library, &source, photos.path());
    assert_eq!(first.discovered, 2);
    assert_eq!(first.skipped, 0);

    // Nothing changed: the second scan reads no metadata at all.
    let second = scan(&library, &source, photos.path());
    assert_eq!(second.discovered, 0);
    assert_eq!(second.skipped, 2);

    // A new file is picked up while the unchanged ones stay skipped.
    write_png(photos.path(), "three.png", 5, 5);
    let third = scan(&library, &source, photos.path());
    assert_eq!(third.discovered, 1);
    assert_eq!(third.skipped, 2);

    // A rewritten file is read again even though its name is known.
    write_png(photos.path(), "one.png", 9, 9);
    let fourth = scan(&library, &source, photos.path());
    assert_eq!(fourth.discovered, 1);
    assert_eq!(fourth.skipped, 2);

    // The index itself never duplicated a row along the way.
    let page = library.query(PhotoFilter::default(), None, 10).unwrap();
    assert_eq!(page.items.len(), 3);
}

#[test]
fn files_that_left_the_active_index_are_read_again() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(photos.path()).unwrap();
    write_png(photos.path(), "one.png", 4, 4);

    let first = scan(&library, &source, photos.path());
    assert_eq!(first.discovered, 1);
    assert!(library.indexed_fingerprints(&source).unwrap().len() == 1);

    // Removing the source keeps the files but drops them out of the active
    // index, so the next scan has to read them again.
    library.remove_source(source.clone()).unwrap();
    assert!(library.indexed_fingerprints(&source).unwrap().is_empty());

    let second = scan(&library, &source, photos.path());
    assert_eq!(second.discovered, 1);
    assert_eq!(second.skipped, 0);
}
