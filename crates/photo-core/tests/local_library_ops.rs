//! Trash/restore/purge, album copy-move, rename, and editor save for the
//! account-free local library.
use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
use photo_core::edit::EditAdjustments;
use photo_core::local_library::{LocalLibrary, MediaInput, PhotoFilter};
use std::fs;
use std::path::Path;
use tempfile::TempDir;

fn png_bytes(width: u32, height: u32) -> Vec<u8> {
    let image = RgbImage::from_fn(width, height, |x, y| {
        Rgb([(x % 255) as u8, (y % 255) as u8, 128])
    });
    let mut cursor = std::io::Cursor::new(Vec::new());
    DynamicImage::ImageRgb8(image)
        .write_to(&mut cursor, ImageFormat::Png)
        .unwrap();
    cursor.into_inner()
}

fn write_photo(folder: &Path, name: &str, width: u32, height: u32) -> MediaInput {
    let path = folder.join(name);
    let bytes = png_bytes(width, height);
    fs::write(&path, &bytes).unwrap();
    MediaInput {
        path: path.to_str().unwrap().into(),
        name: name.into(),
        parent: folder.to_str().unwrap().into(),
        size_bytes: bytes.len() as u64,
        modified_ns: fs::metadata(&path)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as i64,
        mime_type: "image/png".into(),
        width: Some(width),
        height: Some(height),
        orientation: 1,
        capture_time_ms: Some(1_700_000_000_000),
    }
}

fn open_with_photos(folder: &Path, names: &[&str]) -> (TempDir, LocalLibrary) {
    let root = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(folder).unwrap();
    let inputs = names
        .iter()
        .map(|name| write_photo(folder, name, 8, 4))
        .collect();
    library.upsert_batch(source, inputs).unwrap();
    (root, library)
}

fn active_names(library: &LocalLibrary) -> Vec<String> {
    let mut names: Vec<String> = library
        .query(PhotoFilter::default(), None, 100)
        .unwrap()
        .items
        .into_iter()
        .map(|photo| photo.name)
        .collect();
    names.sort();
    names
}

fn input(folder: &Path, name: &str, ns: i64) -> MediaInput {
    let path = folder.join(name);
    fs::write(&path, b"catalog fixture").unwrap();
    MediaInput {
        path: path.to_str().unwrap().into(),
        name: name.into(),
        parent: folder.to_str().unwrap().into(),
        size_bytes: 15,
        modified_ns: ns,
        mime_type: "image/jpeg".into(),
        width: None,
        height: None,
        orientation: 1,
        capture_time_ms: None,
    }
}

#[test]
fn trash_hides_media_and_restore_returns_it_to_the_original_path() {
    let photos = TempDir::new().unwrap();
    let (_root, library) = open_with_photos(photos.path(), &["a.png", "b.png"]);
    let id = library
        .query(
            PhotoFilter {
                search: "a.png".into(),
                ..Default::default()
            },
            None,
            10,
        )
        .unwrap()
        .items[0]
        .id
        .clone();
    let original = photos.path().join("a.png");

    assert_eq!(library.trash_media(vec![id.clone()]).unwrap(), 1);
    assert!(
        !original.exists(),
        "source is moved out of the scanned tree"
    );
    assert_eq!(library.info().unwrap().count, 1);
    assert_eq!(
        library
            .query(
                PhotoFilter {
                    trashed: true,
                    ..Default::default()
                },
                None,
                10,
            )
            .unwrap()
            .items
            .len(),
        1
    );
    assert_eq!(active_names(&library), vec!["b.png".to_owned()]);

    assert_eq!(library.restore_media(vec![id]).unwrap(), 1);
    assert!(original.exists(), "restore puts the file back where it was");
    assert_eq!(
        active_names(&library),
        vec!["a.png".to_owned(), "b.png".to_owned()]
    );
    assert_eq!(library.info().unwrap().count, 2);
}

#[test]
fn purge_and_empty_trash_delete_files_and_rows() {
    let photos = TempDir::new().unwrap();
    let (_root, library) = open_with_photos(photos.path(), &["a.png", "b.png", "c.png"]);
    let id_of = |name: &str| {
        library
            .query(
                PhotoFilter {
                    search: name.into(),
                    ..Default::default()
                },
                None,
                10,
            )
            .unwrap()
            .items[0]
            .id
            .clone()
    };
    let (a, b, c) = (id_of("a.png"), id_of("b.png"), id_of("c.png"));
    library.trash_media(vec![a.clone(), b]).unwrap();

    assert_eq!(library.purge_media(vec![a]).unwrap(), 1);
    // Purging an active (non-trashed) photo is refused rather than silently
    // deleting a live original.
    assert_eq!(library.purge_media(vec![c]).unwrap_err(), "PhotoNotTrashed");
    assert_eq!(
        library
            .query(
                PhotoFilter {
                    trashed: true,
                    ..Default::default()
                },
                None,
                10,
            )
            .unwrap()
            .total,
        1
    );

    assert_eq!(library.empty_trash().unwrap(), 1);
    assert_eq!(
        library.info().unwrap().count,
        1,
        "the active photo survives"
    );
    assert_eq!(active_names(&library), vec!["c.png".to_owned()]);
    assert_eq!(
        fs::read_dir(&photos.path()).unwrap().count(),
        1,
        "trashed files are gone from disk; the live photo remains"
    );
}

#[test]
fn add_to_album_copies_or_moves_and_keeps_sources_valid() {
    let photos = TempDir::new().unwrap();
    let album = photos.path().join("album");
    fs::create_dir_all(&album).unwrap();
    let (_root, library) = open_with_photos(photos.path(), &["a.png"]);
    let id = library
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items[0]
        .id
        .clone();

    let target = album.to_str().unwrap().to_owned();
    assert_eq!(
        library
            .add_to_album(vec![id.clone()], target.clone(), false)
            .unwrap(),
        1
    );
    assert_eq!(
        active_names(&library),
        vec!["a.png".to_owned(), "a.png".to_owned()]
    );
    assert!(photos.path().join("a.png").exists());
    assert!(album.join("a.png").exists());

    assert_eq!(library.add_to_album(vec![id], target, true).unwrap(), 1);
    assert!(
        !photos.path().join("a.png").exists(),
        "move removes the original"
    );
    let albums = library.list_albums().unwrap();
    assert!(
        albums
            .iter()
            .any(|entry| entry.path.ends_with("album") && entry.count == 2),
        "both copies are linked to the destination folder: {albums:?}"
    );
}

#[test]
fn rename_media_moves_the_file_and_updates_the_catalog() {
    let photos = TempDir::new().unwrap();
    let (_root, library) = open_with_photos(photos.path(), &["a.png"]);
    let id = library
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items[0]
        .id
        .clone();

    let renamed = library.rename_media(id, "sunset.png".into()).unwrap();
    assert_eq!(renamed.name, "sunset.png");
    assert!(photos.path().join("sunset.png").exists());
    assert!(!photos.path().join("a.png").exists());
    assert_eq!(active_names(&library), vec!["sunset.png".to_owned()]);
    assert_eq!(
        library
            .rename_media(renamed.id, "bad/name.png".into())
            .unwrap_err(),
        "InvalidFileName"
    );
}

#[test]
fn save_edited_copy_adds_a_new_row_and_overwrite_keeps_one() {
    let photos = TempDir::new().unwrap();
    let (_root, library) = open_with_photos(photos.path(), &["a.png"]);
    let original = library
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items[0]
        .clone();
    let adjustments = EditAdjustments {
        rotation_degrees: 90,
        ..Default::default()
    };

    let copy = library
        .save_edited(original.id.clone(), adjustments, true)
        .unwrap();
    assert_ne!(copy.id, original.id);
    assert!(copy.name.contains("edited"));
    assert_eq!((copy.width, copy.height), (Some(4), Some(8)));
    assert_eq!(library.info().unwrap().count, 2);

    let overshot = library
        .save_edited(original.id.clone(), adjustments, false)
        .unwrap();
    assert_eq!(overshot.id, original.id);
    assert_eq!(overshot.content_version, original.content_version + 1);
    assert_eq!((overshot.width, overshot.height), (Some(4), Some(8)));
    assert_eq!(
        library.info().unwrap().count,
        2,
        "overwrite does not add a row"
    );
}

#[test]
fn save_edited_rejects_a_no_op_request() {
    let photos = TempDir::new().unwrap();
    let (_root, library) = open_with_photos(photos.path(), &["a.png"]);
    let id = library
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items[0]
        .id
        .clone();
    assert_eq!(
        library
            .save_edited(id, EditAdjustments::default(), false)
            .unwrap_err(),
        "NoEdits"
    );
}

#[test]
fn albums_are_derived_from_folders_and_exclude_trashed_media() {
    let photos = TempDir::new().unwrap();
    let (_root, library) = open_with_photos(photos.path(), &["a.png", "b.png"]);
    let albums = library.list_albums().unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].count, 2);
    assert!(albums[0].cover_media_id.is_some());

    let ids: Vec<String> = library
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items
        .into_iter()
        .map(|photo| photo.id)
        .collect();
    library.trash_media(ids).unwrap();
    // Trashing every member removes the folder from the album list entirely.
    assert!(library.list_albums().unwrap().is_empty());
}

#[test]
fn reordered_empty_album_keeps_its_sidebar_position() {
    let first = TempDir::new().unwrap();
    let second = TempDir::new().unwrap();
    let root = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    for folder in [first.path(), second.path()] {
        let source = library.add_source(folder).unwrap();
        library
            .upsert_batch(source, vec![write_photo(folder, "one.png", 4, 4)])
            .unwrap();
    }
    let ordered: Vec<String> = library
        .list_albums()
        .unwrap()
        .into_iter()
        .map(|album| album.path)
        .collect();
    assert_eq!(ordered.len(), 2);
    let parent = TempDir::new().unwrap();
    let empty = library
        .create_album(parent.path().to_path_buf(), "Empty".into())
        .unwrap();
    let mut reordered = vec![empty.clone()];
    reordered.extend(ordered);
    library.reorder_albums(reordered).unwrap();
    let albums = library.list_albums().unwrap();
    assert_eq!(albums.len(), 3);
    assert_eq!(albums[0].path, empty);
    assert_eq!(albums[0].count, 0);
}

#[test]
fn create_album_reclaims_a_preference_left_by_a_deleted_folder() {
    let parent = TempDir::new().unwrap();
    let root = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let folder = library
        .create_album(parent.path().to_path_buf(), "Album".into())
        .unwrap();
    fs::remove_dir_all(&folder).unwrap();
    let folder = library
        .create_album(parent.path().to_path_buf(), "Album".into())
        .unwrap();
    assert!(Path::new(&folder).is_dir());
    let albums = library.list_albums().unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].path, folder);
}

#[test]
fn rename_album_folds_in_a_source_left_by_a_removed_album() {
    let parent = TempDir::new().unwrap();
    let root = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let first = library
        .create_album(parent.path().to_path_buf(), "First".into())
        .unwrap();
    let second = library
        .create_album(parent.path().to_path_buf(), "Second".into())
        .unwrap();
    let source = library.add_source(Path::new(&first)).unwrap();
    library
        .upsert_batch(source, vec![write_photo(Path::new(&first), "one.png", 4, 4)])
        .unwrap();
    library.remove_album(second.clone()).unwrap();
    fs::remove_dir_all(&second).unwrap();
    library
        .rename_album(first.clone(), "Second".into())
        .unwrap();
    let renamed = parent.path().join("Second");
    assert!(renamed.is_dir());
    let albums = library.list_albums().unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].path, renamed.to_str().unwrap());
    assert_eq!(albums[0].count, 1);
}

#[test]
fn rename_album_moves_the_folder_and_keeps_media_visible() {
    let parent = TempDir::new().unwrap();
    let root = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let folder = parent.path().join("Album");
    fs::create_dir(&folder).unwrap();
    let source = library.add_source(&folder).unwrap();
    library
        .upsert_batch(source, vec![write_photo(&folder, "one.png", 4, 4)])
        .unwrap();
    library
        .rename_album(folder.to_string_lossy().into_owned(), "Renamed".into())
        .unwrap();
    assert!(!folder.exists());
    let renamed = parent.path().join("Renamed");
    assert!(renamed.is_dir());
    let albums = library.list_albums().unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].path, renamed.canonicalize().unwrap().to_string_lossy());
    assert_eq!(albums[0].count, 1);
}

#[test]
fn batch_upsert_keeps_trashed_media_trashed() {
    let photos = TempDir::new().unwrap();
    let root = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(photos.path()).unwrap();
    library
        .upsert_batch(source.clone(), vec![input(photos.path(), "keep.jpg", 5)])
        .unwrap();
    let id = library
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items[0]
        .id
        .clone();
    library.trash_media(vec![id.clone()]).unwrap();

    // Re-linking the same source must not silently resurrect a trashed photo.
    library
        .upsert_batch(source, vec![input(photos.path(), "other.jpg", 6)])
        .unwrap();
    assert_eq!(library.info().unwrap().count, 1);
    assert_eq!(
        library.photo(id).unwrap().state,
        "trashed",
        "upsert must not revive a photo the user removed"
    );
}
