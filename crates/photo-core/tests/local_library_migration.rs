//! L02-04: failed transactions and interrupted migration must preserve the
//! original library; a newer schema must reject old writers without wiping it.
use photo_core::local_library::{LocalLibrary, MediaInput, PhotoFilter};
use rusqlite::Connection;
use std::fs;
use tempfile::TempDir;

const SCHEMA: &str = include_str!("../src/storage/local-schema.sql");

/// Mirrors `photo_core::local_library::SCHEMA_VERSION`; the pre-release build
/// refuses any database written by a different version.
const CURRENT_SCHEMA_VERSION: i64 = 2;

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
fn failed_batch_transaction_preserves_committed_state() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(photos.path()).unwrap();
    library
        .upsert_batch(
            source.clone(),
            (0..3)
                .map(|i| input(photos.path(), &format!("photo-{i}.jpg"), i))
                .collect(),
        )
        .unwrap();
    let favorite_id = library
        .query(
            PhotoFilter {
                search: "photo-1".into(),
                ..Default::default()
            },
            None,
            10,
        )
        .unwrap()
        .items[0]
        .id
        .clone();
    library.set_favorite(favorite_id.clone(), true).unwrap();
    let before = library.info().unwrap();

    // The first item of the batch is valid; the second fails mid-transaction
    // because its size does not fit the signed column domain.
    let mut mixed = vec![input(photos.path(), "new.jpg", 100)];
    mixed.push(MediaInput {
        size_bytes: u64::MAX,
        ..input(photos.path(), "huge.jpg", 101)
    });
    assert_eq!(
        library.upsert_batch(source, mixed).unwrap_err(),
        "FileTooLarge"
    );

    // Nothing from the failed batch is visible and prior state is untouched.
    let after = library.info().unwrap();
    assert_eq!(after.count, before.count);
    assert_eq!(after.revision, before.revision);
    assert!(
        library
            .query(
                PhotoFilter {
                    search: "new.jpg".into(),
                    ..Default::default()
                },
                None,
                10
            )
            .unwrap()
            .items
            .is_empty()
    );
    assert!(library.photo(favorite_id).unwrap().favorite);
    assert_eq!(
        library
            .query(
                PhotoFilter {
                    favorites_only: true,
                    ..Default::default()
                },
                None,
                10
            )
            .unwrap()
            .total,
        1
    );
}

#[test]
fn interrupted_initial_migration_leaves_no_partial_schema_and_reopen_recovers() {
    let root = TempDir::new().unwrap();
    fs::create_dir_all(root.path()).unwrap();
    let database = root.path().join("library.sqlite");

    // Apply only a prefix of the schema inside one transaction, then abandon
    // it (rollback stands in for a crash before commit).
    {
        let mut connection = Connection::open(&database).unwrap();
        let transaction = connection.transaction().unwrap();
        let prefix = SCHEMA.split("CREATE TABLE app_settings").next().unwrap();
        transaction.execute_batch(prefix).unwrap();
        transaction
            .execute("INSERT INTO app_meta VALUES(1,1,'install',0)", [])
            .unwrap();
        // Simulated interruption: never committed.
    }
    {
        let connection = Connection::open(&database).unwrap();
        let tables: i64 = connection
            .query_row("SELECT COUNT(*) FROM sqlite_master", [], |r| r.get(0))
            .unwrap();
        assert_eq!(tables, 0, "aborted migration must not leave tables");
        let version: i64 = connection
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, 0);
    }

    // Reopening runs the migration from scratch and yields a working library.
    let photos = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(photos.path()).unwrap();
    library
        .upsert_batch(source, vec![input(photos.path(), "a.jpg", 1)])
        .unwrap();
    assert_eq!(
        library
            .query(PhotoFilter::default(), None, 10)
            .unwrap()
            .total,
        1
    );
    drop(library);
    let reopened = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(reopened.info().unwrap().count, 1);
}

#[test]
fn newer_schema_rejects_old_writer_without_wiping_the_library() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let library_id = library.library_id.clone();
    let source = library.add_source(photos.path()).unwrap();
    library
        .upsert_batch(source, vec![input(photos.path(), "keep.jpg", 7)])
        .unwrap();
    let media_id = library
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items[0]
        .id
        .clone();
    library.set_favorite(media_id.clone(), true).unwrap();
    let revision = library.info().unwrap().revision;
    drop(library);

    let database = root.path().join("library.sqlite");
    let connection = Connection::open(&database).unwrap();
    connection.pragma_update(None, "user_version", 999).unwrap();
    drop(connection);

    // The old writer is refused and no reset happens.
    assert_eq!(
        LocalLibrary::open(root.path()).err().unwrap(),
        "SchemaTooNew"
    );
    let connection = Connection::open(&database).unwrap();
    let version: i64 = connection
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 999, "downgrade attempt must not rewrite version");
    let (count, favorite): (i64, i64) = connection
        .query_row(
            "SELECT COUNT(*), SUM(favorite) FROM media WHERE library_id=?1",
            [&library_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!((count, favorite), (1, 1), "rows survive the refusal");
    drop(connection);

    // Once the future writer restores the current version, all data is intact.
    // The pre-release schema has no downgrade path, so only the exact version
    // the writer was built for is accepted.
    let connection = Connection::open(&database).unwrap();
    connection
        .pragma_update(None, "user_version", CURRENT_SCHEMA_VERSION)
        .unwrap();
    drop(connection);
    let restored = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(restored.library_id, library_id);
    assert_eq!(restored.info().unwrap().revision, revision);
    assert!(restored.photo(media_id).unwrap().favorite);
}

#[test]
fn reopen_settles_interrupted_scan_runs_and_keeps_the_catalog() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let library_id = library.library_id.clone();
    let source = library.add_source(photos.path()).unwrap();
    library
        .upsert_batch(source.clone(), vec![input(photos.path(), "a.jpg", 1)])
        .unwrap();
    drop(library);

    // A scan row left in 'running' models a crash during ingestion.
    let connection = Connection::open(root.path().join("library.sqlite")).unwrap();
    connection
        .execute(
            "INSERT INTO scan_runs(library_id,scan_id,source_id,state,started_at_ms) VALUES(?1,'scan-1',?2,'running',1)",
            rusqlite::params![library_id, source],
        )
        .unwrap();
    drop(connection);

    let reopened = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(reopened.info().unwrap().count, 1);
    let connection = Connection::open(root.path().join("library.sqlite")).unwrap();
    let state: String = connection
        .query_row(
            "SELECT state FROM scan_runs WHERE scan_id='scan-1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(state, "interrupted");
}
