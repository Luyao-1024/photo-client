//! L02-03: cross-LibraryId writes and associations must be rejected by
//! foreign keys and by command scoping.
use photo_core::local_library::{LocalLibrary, MediaInput, PhotoFilter};
use rusqlite::Connection;
use std::fs;
use tempfile::TempDir;

const SCHEMA: &str = include_str!("../src/storage/local-schema.sql");

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
fn commands_are_scoped_to_their_own_library_id() {
    let root_a = TempDir::new().unwrap();
    let root_b = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let a = LocalLibrary::open(root_a.path()).unwrap();
    let b = LocalLibrary::open(root_b.path()).unwrap();
    assert_ne!(a.library_id, b.library_id);

    let source_a = a.add_source(photos.path()).unwrap();
    let source_b = b.add_source(photos.path()).unwrap();
    a.upsert_batch(source_a, vec![input(photos.path(), "a.jpg", 1)])
        .unwrap();
    b.upsert_batch(source_b.clone(), vec![input(photos.path(), "b.jpg", 2)])
        .unwrap();
    let media_b = b
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items
        .remove(0);

    // Library A must not read or favorite Library B's media id.
    assert_eq!(a.photo(media_b.id.clone()).unwrap_err(), "PhotoNotFound");
    assert_eq!(
        a.set_favorite(media_b.id.clone(), true).unwrap_err(),
        "PhotoNotFound"
    );
    // Library A must not write through Library B's source id.
    assert!(
        a.upsert_batch(source_b, vec![input(photos.path(), "c.jpg", 3)])
            .unwrap_err()
            .contains("FOREIGN KEY constraint failed")
    );

    // Rejected commands leave both libraries untouched.
    assert_eq!(a.info().unwrap().count, 1);
    assert_eq!(b.info().unwrap().count, 1);
    let still_b = b.photo(media_b.id).unwrap();
    assert!(!still_b.favorite);
    assert_eq!(still_b.name, "b.jpg");
    assert!(
        a.query(
            PhotoFilter {
                search: "c.jpg".into(),
                ..Default::default()
            },
            None,
            10
        )
        .unwrap()
        .items
        .is_empty()
    );
}

#[test]
fn schema_foreign_keys_reject_cross_library_associations() {
    let connection = Connection::open_in_memory().unwrap();
    connection.execute_batch("PRAGMA foreign_keys=ON;").unwrap();
    connection.execute_batch(SCHEMA).unwrap();
    connection
        .execute_batch(
            "INSERT INTO libraries(library_id,name,created_at_ms) VALUES('A','a',1),('B','b',1);
             INSERT INTO sources(library_id,source_id,root_uri,source_kind) VALUES('A','sa','/a','linked_directory'),('B','sb','/b','linked_directory');
             INSERT INTO media(library_id,media_id,source_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,media_kind,mime_type,sort_time_ms)
               VALUES('A','ma','sa','/a/1.jpg','1.jpg','/a',10,1,'image','image/jpeg',1),
                     ('B','mb','sb','/b/2.jpg','2.jpg','/b',10,1,'image','image/jpeg',1);
             INSERT INTO albums(library_id,album_id,name) VALUES('A','aa','album');",
        )
        .unwrap();

    let fk = |sql: &str| {
        connection
            .execute(sql, [])
            .unwrap_err()
            .to_string()
            .contains("FOREIGN KEY constraint failed")
    };
    // Album in A cannot reference media of B, and vice versa.
    assert!(fk("INSERT INTO album_members VALUES('A','aa','mb')"));
    connection
        .execute(
            "INSERT INTO albums(library_id,album_id,name) VALUES('B','ba','album')",
            [],
        )
        .unwrap();
    assert!(fk("INSERT INTO album_members VALUES('B','ba','ma')"));
    // media.source_id is scoped by the composite (library_id, source_id) key.
    assert!(fk(
        "INSERT INTO media(library_id,media_id,source_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,media_kind,mime_type,sort_time_ms) VALUES('A','mx','sb','/a/x.jpg','x.jpg','/a',1,1,'image','image/jpeg',1)"
    ));
    // Sources and thumbnails cannot reference another library or unknown rows.
    assert!(fk(
        "INSERT INTO sources(library_id,source_id,root_uri,source_kind) VALUES('ghost','s','/g','managed')"
    ));
    assert!(fk(
        "INSERT INTO thumbnails(library_id,media_id,content_version,size_class,cache_key,relative_path,state) VALUES('B','ma',1,256,'k','p','ready')"
    ));
    assert!(fk(
        "INSERT INTO scan_runs(library_id,scan_id,source_id,state,started_at_ms) VALUES('A','r','sb','running',1)"
    ));

    // Positive control: same-library associations succeed.
    connection
        .execute("INSERT INTO album_members VALUES('A','aa','ma')", [])
        .unwrap();
    connection
        .execute(
            "INSERT INTO thumbnails(library_id,media_id,content_version,size_class,cache_key,relative_path,state) VALUES('A','ma',1,256,'k','p','ready')",
            [],
        )
        .unwrap();
}
