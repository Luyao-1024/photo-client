use photo_core::local_library::{LocalLibrary, MediaInput, PhotoFilter};
use std::fs;
use tempfile::TempDir;

fn input(folder: &std::path::Path, name: &str, ns: i64) -> MediaInput {
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
fn account_free_catalog_persists_identity_and_favorite_without_touching_source() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let id = library.library_id.clone();
    let source = library.add_source(photos.path()).unwrap();
    let photo = input(photos.path(), "中文 空格.jpg", 10_000_000);
    library.upsert_batch(source, vec![photo.clone()]).unwrap();
    let page = library.query(PhotoFilter::default(), None, 100).unwrap();
    assert_eq!(page.total, 1);
    assert_eq!(page.items[0].name, "中文 空格.jpg");
    let media_id = page.items[0].id.clone();
    assert!(library.set_favorite(media_id.clone(), true).unwrap());
    assert!(!library.set_favorite(media_id.clone(), true).unwrap());
    assert_eq!(fs::read(&photo.path).unwrap(), b"catalog fixture");
    drop(library);
    let reopened = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(reopened.library_id, id);
    assert!(reopened.photo(media_id).unwrap().favorite);
    assert_eq!(
        reopened
            .query(
                PhotoFilter {
                    favorites_only: true,
                    ..Default::default()
                },
                None,
                100
            )
            .unwrap()
            .total,
        1
    );
}

#[test]
fn one_writer_per_data_root_and_future_schema_is_not_reset() {
    let root = TempDir::new().unwrap();
    let first = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(
        LocalLibrary::open(root.path()).err().unwrap(),
        "LibraryAlreadyOpen"
    );
    drop(first);
    let c = rusqlite::Connection::open(root.path().join("library.sqlite")).unwrap();
    c.pragma_update(None, "user_version", 999).unwrap();
    drop(c);
    assert_eq!(
        LocalLibrary::open(root.path()).err().unwrap(),
        "SchemaTooNew"
    );
    let c = rusqlite::Connection::open(root.path().join("library.sqlite")).unwrap();
    assert_eq!(
        c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        999
    );
}

#[test]
fn keyset_paging_search_and_metadata_replacement_preserve_identity() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let l = LocalLibrary::open(root.path()).unwrap();
    let s = l.add_source(photos.path()).unwrap();
    let inputs = (0..5)
        .map(|i| input(photos.path(), &format!("photo-{i}.jpg"), i * 1_000_000))
        .collect::<Vec<_>>();
    l.upsert_batch(s.clone(), inputs.clone()).unwrap();
    let a = l.query(PhotoFilter::default(), None, 2).unwrap();
    let b = l
        .query(PhotoFilter::default(), a.next_cursor.clone(), 2)
        .unwrap();
    let c = l
        .query(PhotoFilter::default(), b.next_cursor.clone(), 2)
        .unwrap();
    let ids = a
        .items
        .iter()
        .chain(&b.items)
        .chain(&c.items)
        .map(|p| p.id.clone())
        .collect::<std::collections::HashSet<_>>();
    assert_eq!(ids.len(), 5);
    assert!(c.next_cursor.is_none());
    assert!(
        l.query(
            PhotoFilter {
                favorites_only: true,
                ..Default::default()
            },
            a.next_cursor,
            2
        )
        .is_err()
    );
    let mut replacement = inputs[4].clone();
    let before = l
        .query(
            PhotoFilter {
                search: "photo-4".into(),
                ..Default::default()
            },
            None,
            100,
        )
        .unwrap()
        .items
        .remove(0);
    l.set_favorite(before.id.clone(), true).unwrap();
    replacement.modified_ns += 1;
    l.upsert_batch(s.clone(), vec![replacement]).unwrap();
    let after = l.photo(before.id.clone()).unwrap();
    assert!(after.favorite);
    assert_eq!(after.content_version, before.content_version + 1);
    assert_eq!(l.info().unwrap().count, 5);
    assert_eq!(l.upsert_batch(s, inputs[..1].to_vec()).unwrap(), 0);
}

#[test]
fn foreign_source_and_invalid_batch_roll_back_counts() {
    let a = TempDir::new().unwrap();
    let b = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let a = LocalLibrary::open(a.path()).unwrap();
    let b = LocalLibrary::open(b.path()).unwrap();
    let foreign = b.add_source(photos.path()).unwrap();
    assert!(
        a.upsert_batch(foreign, vec![input(photos.path(), "a.jpg", 1)])
            .unwrap_err()
            .contains("FOREIGN KEY constraint failed")
    );
    assert_eq!(a.info().unwrap().count, 0);
    assert!(a.query(PhotoFilter::default(), None, 0).is_err());
    assert!(a.set_favorite("absent".into(), true).is_err());
}
