//! L02-04: failed transactions and interrupted migration must preserve the
//! original library; a newer schema must reject old writers without wiping it.
use photo_core::local_library::{LocalLibrary, MediaInput, PhotoFilter};
use rusqlite::Connection;
use std::fs;
use tempfile::TempDir;

const SCHEMA: &str = include_str!("../src/storage/local-schema.sql");
const EXTENSIONS: &str = include_str!("../src/storage/local-v3.sql");

/// Older supported catalogs are upgraded; future writers are still rejected.
const CURRENT_SCHEMA_VERSION: i64 = 8;

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
    // A future schema must be restored by its own writer before this client
    // may open it; unsupported downgrades never reset the catalog.
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

fn legacy_catalog(root: &TempDir, photos: &TempDir, version: i64) {
    let schema = if version == 1 {
        SCHEMA
            .replace("  original_uri TEXT,\n", "")
            .replace("  trashed_at_ms INTEGER,\n", "")
            .replace(
                "('auto','full','reduced')",
                "('auto','full','reduced','plain')",
            )
    } else {
        SCHEMA.to_owned()
    };
    let photo = input(photos.path(), "keep.jpg", 1_000_000);
    let c = Connection::open(root.path().join("library.sqlite")).unwrap();
    c.execute_batch(&schema).unwrap();
    if version >= 3 {
        c.execute_batch(EXTENSIONS).unwrap();
    }
    c.execute(
        "INSERT INTO app_meta VALUES(1,?1,'installation',0)",
        [version],
    )
    .unwrap();
    c.execute(
        "INSERT INTO schema_migrations VALUES(?1,?2,1)",
        rusqlite::params![version, "1".repeat(64)],
    )
    .unwrap();
    c.execute(
        "INSERT INTO libraries VALUES('legacy-library','Legacy',7,123,1,1)",
        [],
    )
    .unwrap();
    c.execute("INSERT INTO app_settings(singleton,selected_library_id,theme,glass_mode,locale) VALUES(1,'legacy-library','dark',?1,'en-US')", [if version == 1 { "plain" } else { "full" }]).unwrap();
    c.execute("INSERT INTO sources(library_id,source_id,root_uri,source_kind) VALUES('legacy-library','source',?1,'linked_directory')", [photos.path().to_str().unwrap()]).unwrap();
    c.execute("INSERT INTO media(library_id,media_id,source_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,media_kind,mime_type,sort_time_ms,favorite) VALUES('legacy-library','photo','source',?1,'keep.jpg',?2,15,1000000,'image','image/jpeg',1,1)",rusqlite::params![photo.path,photo.parent]).unwrap();
    c.execute(
        "INSERT INTO albums VALUES('legacy-library','album','Keep',4)",
        [],
    )
    .unwrap();
    c.execute(
        "INSERT INTO album_members VALUES('legacy-library','album','photo')",
        [],
    )
    .unwrap();
    c.pragma_update(None, "user_version", version).unwrap();
}

fn backup_files(root: &TempDir) -> Vec<std::path::PathBuf> {
    fs::read_dir(root.path().join("backups"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "sqlite")
        })
        .collect()
}

#[test]
fn v1_migration_preserves_catalog_preferences_and_originals() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    legacy_catalog(&root, &photos, 1);
    let before = fs::read(photos.path().join("keep.jpg")).unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(library.library_id, "legacy-library");
    assert_eq!(library.info().unwrap().count, 1);
    assert_eq!(library.info().unwrap().revision, 7);
    assert!(library.photo("photo".into()).unwrap().favorite);
    assert_eq!(library.sources().unwrap().len(), 1);
    let prefs: serde_json::Value = serde_json::from_str(&library.preferences().unwrap()).unwrap();
    assert_eq!(prefs["theme"], "dark");
    assert_eq!(prefs["glassMode"], "auto");
    assert_eq!(prefs["locale"], "en");
    library
        .set_preference("transparency".into(), "0.25".into())
        .unwrap();
    let c = Connection::open(root.path().join("library.sqlite")).unwrap();
    assert_eq!(
        c.query_row("SELECT COUNT(*) FROM album_members", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        CURRENT_SCHEMA_VERSION
    );
    assert_eq!(
        c.query_row("SELECT schema_version FROM app_meta", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        CURRENT_SCHEMA_VERSION
    );
    assert_eq!(fs::read(photos.path().join("keep.jpg")).unwrap(), before);
    let backups = backup_files(&root);
    assert_eq!(backups.len(), 1);
    let backup = Connection::open(&backups[0]).unwrap();
    assert_eq!(
        backup
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        backup
            .query_row(
                "SELECT favorite FROM media WHERE media_id='photo'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        1
    );
    drop(library);
    let reopened = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(
        backup_files(&root).len(),
        1,
        "reopening must not migrate again"
    );
    let prefs: serde_json::Value = serde_json::from_str(&reopened.preferences().unwrap()).unwrap();
    assert_eq!(prefs["transparency"], 0.25);
}

#[test]
fn v2_migration_keeps_already_saved_preferences() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    legacy_catalog(&root, &photos, 2);
    let c = Connection::open(root.path().join("library.sqlite")).unwrap();
    c.execute_batch("CREATE TABLE local_preferences(key TEXT PRIMARY KEY,value TEXT NOT NULL) STRICT; INSERT INTO local_preferences VALUES('theme','\"light\"');").unwrap();
    drop(c);
    let library = LocalLibrary::open(root.path()).unwrap();
    assert!(library.photo("photo".into()).unwrap().favorite);
    let prefs: serde_json::Value = serde_json::from_str(&library.preferences().unwrap()).unwrap();
    assert_eq!(prefs["theme"], "light");
    assert_eq!(prefs["glassMode"], "full");
    assert_eq!(backup_files(&root).len(), 1);
}

#[test]
fn v3_migration_adds_cloud_tables_and_preserves_catalog() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    legacy_catalog(&root, &photos, 3);
    let library = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(library.library_id, "legacy-library");
    assert_eq!(library.info().unwrap().count, 1);
    assert_eq!(library.info().unwrap().revision, 7);
    assert!(library.photo("photo".into()).unwrap().favorite);
    let prefs: serde_json::Value = serde_json::from_str(&library.preferences().unwrap()).unwrap();
    assert_eq!(prefs["glassMode"], "full");
    let c = Connection::open(root.path().join("library.sqlite")).unwrap();
    for table in [
        "cloud_accounts",
        "cloud_sync_state",
        "cloud_records",
        "cloud_bindings",
        "cloud_uploads",
    ] {
        assert_eq!(
            c.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                [table],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1,
            "{table} must exist after the v3 upgrade"
        );
    }
    assert_eq!(
        c.query_row("SELECT COUNT(*) FROM album_members", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        CURRENT_SCHEMA_VERSION
    );
    assert_eq!(
        c.query_row("SELECT schema_version FROM app_meta", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        CURRENT_SCHEMA_VERSION
    );
    assert_eq!(
        c.query_row(
            "SELECT favorite FROM media WHERE media_id='photo'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
    drop(c);
    let backups = backup_files(&root);
    assert_eq!(backups.len(), 1);
    let backup = Connection::open(&backups[0]).unwrap();
    assert_eq!(
        backup
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        3
    );
    assert_eq!(
        backup
            .query_row(
                "SELECT favorite FROM media WHERE media_id='photo'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        1
    );
}

#[test]
fn failed_v1_migration_rolls_back_schema_and_keeps_backup() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    legacy_catalog(&root, &photos, 1);
    let c = Connection::open(root.path().join("library.sqlite")).unwrap();
    c.execute_batch("CREATE TABLE local_preferences(key TEXT PRIMARY KEY,value TEXT NOT NULL CHECK(value='reject')) STRICT;").unwrap();
    drop(c);
    assert!(LocalLibrary::open(root.path()).is_err());
    let c = Connection::open(root.path().join("library.sqlite")).unwrap();
    assert_eq!(
        c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        c.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('media') WHERE name='original_uri'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    assert_eq!(
        c.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE name='album_preferences'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    assert_eq!(
        c.query_row("SELECT favorite FROM media", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(backup_files(&root).len(), 1);
}

#[test]
fn migration_backup_failure_leaves_database_untouched() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    legacy_catalog(&root, &photos, 1);
    fs::write(
        root.path().join("backups"),
        b"cannot create a directory here",
    )
    .unwrap();
    assert!(LocalLibrary::open(root.path()).is_err());
    let c = Connection::open(root.path().join("library.sqlite")).unwrap();
    assert_eq!(
        c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        c.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('media') WHERE name='original_uri'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    assert_eq!(
        c.query_row("SELECT favorite FROM media", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn v4_metadata_upgrade_preserves_dirty_work_and_backs_up_before_migration() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    legacy_catalog(&root, &photos, 4);
    let old = Connection::open(root.path().join("library.sqlite")).unwrap();
    old.execute_batch(include_str!("../src/storage/local-v4.sql"))
        .unwrap();
    old.execute("INSERT INTO cloud_accounts(account_id,endpoint,username,token_file,device_id,created_at_ms) VALUES('account','http://127.0.0.1:8790','user','cloud/account/session.token','device',1)",[]).unwrap();
    old.execute("INSERT INTO cloud_sync_state(account_id,status,sync_token,updated_at_ms) VALUES('account','idle','keep-token',1)",[]).unwrap();
    old.execute("INSERT INTO cloud_bindings(account_id,photo_id,master_id,content_generation,library_id,media_id,relative_path,cloud_favorite,favorite_dirty,created_at_ms,updated_at_ms) VALUES('account','photo-id','master-id','generation','legacy-library','photo','keep.jpg',0,1,1,123456)",[]).unwrap();
    drop(old);
    let library = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(library.library_id, "legacy-library");
    assert!(library.photo("photo".into()).unwrap().favorite);
    let db = Connection::open(root.path().join("library.sqlite")).unwrap();
    let state:(i64,i64,i64,i64,String,String)=db.query_row("SELECT dirty,metadata_version,acked_metadata_version,edited_at_ms,source,event_id FROM media_sync_state WHERE media_id='photo'",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).unwrap();
    assert_eq!((state.0, state.1, state.2, state.3), (2, 1, 0, 123456));
    assert_eq!(state.4, "installation");
    assert!(state.5.starts_with("migration-"));
    assert_eq!(
        db.query_row("SELECT sync_token FROM cloud_sync_state", [], |r| r
            .get::<_, String>(0))
            .unwrap(),
        "keep-token"
    );
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('cloud_bindings') WHERE name='favorite_dirty'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        CURRENT_SCHEMA_VERSION
    );
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('cloud_accounts') WHERE name IN ('is_active','upload_scope')",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        2
    );
    assert_eq!(
        db.query_row(
            "SELECT is_active FROM cloud_accounts WHERE account_id='account'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('cloud_bindings') WHERE name IN ('remote_edited_at_ms','remote_source','remote_event_id')",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        3
    );
    let backups = backup_files(&root);
    assert_eq!(backups.len(), 1);
    let backup = Connection::open(&backups[0]).unwrap();
    assert_eq!(
        backup
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        4
    );
    assert_eq!(
        backup
            .query_row("SELECT favorite_dirty FROM cloud_bindings", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert!(photos.path().join("keep.jpg").is_file());
}

#[test]
fn v8_upgrade_adds_the_download_root_column_and_keeps_accounts() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    legacy_catalog(&root, &photos, 7);
    let old = Connection::open(root.path().join("library.sqlite")).unwrap();
    old.execute_batch(include_str!("../src/storage/local-v4.sql"))
        .unwrap();
    old.execute_batch(include_str!("../src/storage/local-v5.sql"))
        .unwrap();
    old.execute_batch(include_str!("../src/storage/local-v6.sql"))
        .unwrap();
    old.execute_batch(include_str!("../src/storage/local-v7.sql"))
        .unwrap();
    old.execute("INSERT INTO cloud_accounts(account_id,endpoint,username,token_file,device_id,created_at_ms) VALUES('account','http://127.0.0.1:8790','user','cloud/account/session.token','device',1)",[]).unwrap();
    old.execute(
        "INSERT INTO cloud_sync_state(account_id,status,updated_at_ms) VALUES('account','idle',1)",
        [],
    )
    .unwrap();
    drop(old);

    let library = LocalLibrary::open(root.path()).unwrap();
    assert!(library.photo("photo".into()).unwrap().favorite);
    let db = Connection::open(root.path().join("library.sqlite")).unwrap();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        CURRENT_SCHEMA_VERSION
    );
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('cloud_accounts') WHERE name='download_root'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1,
        "the v8 upgrade must add the download root column"
    );
    assert_eq!(
        db.query_row("SELECT COUNT(*) FROM cloud_accounts", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        db.query_row("SELECT download_root FROM cloud_accounts", [], |r| r
            .get::<_, Option<String>>(0))
            .unwrap(),
        None
    );
    assert_eq!(backup_files(&root).len(), 1);
    assert!(photos.path().join("keep.jpg").is_file());
}

#[test]
fn v6_upgrade_adds_content_and_delete_obligations_without_dropping_pending_work() {
    let root = TempDir::new().unwrap();
    let photos = TempDir::new().unwrap();
    legacy_catalog(&root, &photos, 6);
    let old = Connection::open(root.path().join("library.sqlite")).unwrap();
    old.execute_batch(include_str!("../src/storage/local-v4.sql"))
        .unwrap();
    old.execute("INSERT INTO cloud_accounts(account_id,endpoint,username,token_file,device_id,created_at_ms) VALUES('account','http://127.0.0.1:8790','user','cloud/account/session.token','device',1)",[]).unwrap();
    old.execute("INSERT INTO cloud_sync_state(account_id,status,sync_token,updated_at_ms) VALUES('account','idle','keep-token',1)",[]).unwrap();
    old.execute("INSERT INTO cloud_bindings(account_id,photo_id,master_id,content_generation,library_id,media_id,relative_path,cloud_favorite,favorite_dirty,created_at_ms,updated_at_ms) VALUES('account','photo-id','master-id','generation','legacy-library','photo','keep.jpg',0,1,1,123456)",[]).unwrap();
    old.execute_batch(include_str!("../src/storage/local-v5.sql"))
        .unwrap();
    old.execute(
        "UPDATE media_sync_state SET dirty=2,metadata_version=3,acked_metadata_version=1,edited_at_ms=999,source='user',event_id='event-1' WHERE media_id='photo'",
        [],
    )
    .unwrap();
    old.execute("INSERT INTO cloud_metadata_operations(account_id,photo_id,operation_id,library_id,media_id,zone_name,record_revision,captured_local_version,captured_metadata_version,relative_path,is_favorite,is_hidden,asset_date_ms,edited_at_ms,source,event_id,created_at_ms) VALUES('account','photo-id','operation','legacy-library','photo','zone','revision',1,1,'keep.jpg',0,0,NULL,999,'user','event-1',1)",[]).unwrap();
    old.execute_batch(include_str!("../src/storage/local-v6.sql"))
        .unwrap();
    old.execute(
        "UPDATE cloud_bindings SET remote_edited_at_ms=555,remote_source='remote',remote_event_id='remote-event' WHERE photo_id='photo-id'",
        [],
    )
    .unwrap();
    drop(old);

    let library = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(library.library_id, "legacy-library");
    assert!(library.photo("photo".into()).unwrap().favorite);
    let db = Connection::open(root.path().join("library.sqlite")).unwrap();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        CURRENT_SCHEMA_VERSION
    );
    let state: (i64, i64, i64, i64, i64, i64, Option<String>) = db
        .query_row(
            "SELECT dirty,metadata_version,acked_metadata_version,path_dirty,content_version,deletion_version,event_id FROM media_sync_state WHERE media_id='photo'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)),
        )
        .unwrap();
    assert_eq!(state, (2, 3, 1, 0, 0, 0, Some("event-1".into())));
    assert_eq!(
        db.query_row(
            "SELECT is_trashed FROM cloud_metadata_operations WHERE operation_id='operation'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('media_sync_state') WHERE name IN ('content_version','acked_content_version','content_edited_at_ms','content_source','content_event_id','deletion_version','acked_deletion_version','deletion_edited_at_ms','deletion_source','deletion_event_id')",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        10
    );
    for table in ["cloud_content_operations", "cloud_delete_operations"] {
        assert_eq!(
            db.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                [table],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
    }
    let binding: (String, String, String) = db
        .query_row(
            "SELECT remote_source,remote_event_id,relative_path FROM cloud_bindings WHERE photo_id='photo-id'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(
        binding,
        ("remote".into(), "remote-event".into(), "keep.jpg".into())
    );
    assert_eq!(
        db.query_row("SELECT upload_scope FROM cloud_accounts", [], |r| r
            .get::<_, String>(0))
            .unwrap(),
        "none"
    );
    assert_eq!(
        db.query_row("SELECT sync_token FROM cloud_sync_state", [], |r| r
            .get::<_, String>(0))
            .unwrap(),
        "keep-token"
    );
    let backups = backup_files(&root);
    assert_eq!(backups.len(), 1);
    let backup = Connection::open(&backups[0]).unwrap();
    assert_eq!(
        backup
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        6
    );
    assert_eq!(
        backup
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('media_sync_state') WHERE name='content_version'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
    assert!(photos.path().join("keep.jpg").is_file());
}
