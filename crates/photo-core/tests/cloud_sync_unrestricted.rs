#[path = "support/cloud_server.rs"]
mod cloud_server;

use cloud_server::{Fixture, successful};
use photo_core::edit::EditAdjustments;
use photo_core::local_library::{LocalLibrary, MediaInput, PhotoFilter};
use rusqlite::{Connection, params};
use std::fs;
use std::time::UNIX_EPOCH;
use syncserver_client as sdk;
use tempfile::TempDir;

fn browser(root: &TempDir) -> Connection {
    Connection::open(root.path().join("library.sqlite")).unwrap()
}

#[test]
fn purging_a_bound_photo_keeps_a_tombstone_until_the_cloud_accepts_it() {
    let root = TempDir::new().unwrap();
    let originals = TempDir::new().unwrap();
    let file = originals.path().join("tombstone.jpg");
    image::RgbImage::from_pixel(8, 6, image::Rgb([20, 40, 60]))
        .save(&file)
        .unwrap();
    let metadata = fs::metadata(&file).unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(originals.path()).unwrap();
    library
        .upsert_batch(
            source,
            vec![MediaInput {
                path: file.to_str().unwrap().into(),
                name: "tombstone.jpg".into(),
                parent: originals.path().to_str().unwrap().into(),
                size_bytes: metadata.len(),
                modified_ns: metadata
                    .modified()
                    .unwrap()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos() as i64,
                mime_type: "image/jpeg".into(),
                width: Some(8),
                height: Some(6),
                orientation: 1,
                capture_time_ms: None,
            }],
        )
        .unwrap();
    let media_id = library
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items[0]
        .id
        .clone();
    let db = browser(&root);
    db.execute(
        "INSERT INTO cloud_accounts(account_id,endpoint,username,user_id,token_file,token_expires_at_ms,device_id,created_at_ms,last_sync_ms,upload_scope,is_active) VALUES('acct','http://127.0.0.1:1','review',NULL,'token',NULL,'device',1,NULL,'all',1)",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO cloud_bindings(account_id,photo_id,master_id,content_generation,library_id,media_id,relative_path,cloud_favorite,asset_date_ms,is_hidden,is_trashed,content_stale,thumbnail_path,thumbnail_sha256,created_at_ms,updated_at_ms) VALUES('acct','photo','master','generation',?1,?2,'Album/tombstone.jpg',0,NULL,0,0,0,NULL,NULL,1,1)",
        params![library.library_id, media_id],
    )
    .unwrap();
    library.trash_media(vec![media_id.clone()]).unwrap();
    library.purge_media(vec![media_id.clone()]).unwrap();

    let row: (String, String) = db
        .query_row(
            "SELECT m.state,b.photo_id FROM media m JOIN cloud_bindings b ON b.library_id=m.library_id AND b.media_id=m.media_id WHERE m.media_id=?1",
            [&media_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(row, ("missing".into(), "photo".into()));
    let state: (i64, i64, i64) = db
        .query_row(
            "SELECT dirty,deletion_version,acked_deletion_version FROM media_sync_state WHERE media_id=?1",
            [&media_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(state, (4, 1, 0));
    assert_eq!(
        library
            .query(PhotoFilter::default(), None, 10)
            .unwrap()
            .total,
        0
    );
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn renaming_a_bound_photo_updates_the_cloud_path() {
    let fixture = Fixture::uploaded().await;
    fixture
        .library
        .rename_media(fixture.media_id.clone(), "renamed.jpg".into())
        .unwrap();
    let report = fixture.engine.sync_now().await.unwrap();
    successful(&report);
    let remote = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    assert_eq!(
        remote.relative_path,
        "Uploads/2023/renamed.jpg".to_string(),
        "the local name and album define the cloud path"
    );
    let state: (i64, i64) = fixture
        .db
        .query_row(
            "SELECT dirty,path_dirty FROM media_sync_state WHERE media_id=?1",
            [&fixture.media_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(state, (0, 0));
    assert_eq!(
        fixture
            .db
            .query_row("SELECT relative_path FROM cloud_bindings", [], |r| r
                .get::<_, String>(0))
            .unwrap(),
        remote.relative_path
    );
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn trash_and_restore_are_metadata_not_content_or_deletion() {
    let fixture = Fixture::uploaded().await;
    let generation = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap()
        .content_generation;
    fixture
        .library
        .trash_media(vec![fixture.media_id.clone()])
        .unwrap();
    successful(&fixture.engine.sync_now().await.unwrap());
    let trashed = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    assert_eq!(trashed.asset.int64("isTrashed"), Some(1));
    assert_eq!(trashed.content_generation, generation);
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT state FROM media WHERE media_id=?1",
                [&fixture.media_id],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
        "trashed"
    );

    fixture
        .library
        .restore_media(vec![fixture.media_id.clone()])
        .unwrap();
    successful(&fixture.engine.sync_now().await.unwrap());
    let restored = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    assert_eq!(restored.asset.int64("isTrashed"), Some(0));
    assert_eq!(restored.content_generation, generation);
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT state FROM media WHERE media_id=?1",
                [&fixture.media_id],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
        "active"
    );
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn editing_a_bound_photo_replaces_the_cloud_content() {
    let fixture = Fixture::uploaded().await;
    let before = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    let saved = fixture
        .library
        .save_edited_versioned(
            fixture.media_id.clone(),
            EditAdjustments {
                rotation_degrees: 90,
                flip_horizontal: false,
                flip_vertical: false,
                brightness: 0,
                contrast: 0,
                saturation: 0,
                crop: None,
            },
            false,
            Some(1),
        )
        .unwrap();
    assert_eq!(saved.content_version, 2);
    let report = fixture.engine.sync_now().await.unwrap();
    successful(&report);
    assert_eq!(report.uploaded, 1);
    let after = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    assert_ne!(after.content_generation, before.content_generation);
    let expected = sdk::ContentDigest::from_file(&saved.path).await.unwrap();
    assert_eq!(after.original_digest().unwrap().hex(), expected.hex());
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT content_version,acked_content_version,dirty FROM media_sync_state WHERE media_id=?1",
                [&fixture.media_id],
                |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)),
            )
            .unwrap(),
        (1, 1, 0)
    );
    assert_eq!(
        fixture
            .db
            .query_row("SELECT content_generation FROM cloud_bindings", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap(),
        after.content_generation
    );
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn purging_a_bound_photo_deletes_both_cloud_records() {
    let fixture = Fixture::uploaded().await;
    fixture
        .library
        .trash_media(vec![fixture.media_id.clone()])
        .unwrap();
    fixture
        .library
        .purge_media(vec![fixture.media_id.clone()])
        .unwrap();
    // The local tombstone remains until the cloud accepts the delete.
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT state FROM media WHERE media_id=?1",
                [&fixture.media_id],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
        "missing"
    );
    let report = fixture.engine.sync_now().await.unwrap();
    successful(&report);
    assert!(
        fixture
            .connection
            .fetch_photo(&fixture.zone, &fixture.photo_id)
            .await
            .is_err(),
        "both cloud records are deleted"
    );
    assert_eq!(
        fixture
            .db
            .query_row("SELECT COUNT(*) FROM cloud_bindings", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        fixture
            .db
            .query_row("SELECT COUNT(*) FROM media", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        fixture
            .db
            .query_row("SELECT COUNT(*) FROM cloud_delete_operations", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
}

#[test]
fn logging_out_removes_the_token_and_keeps_the_account() {
    let root = tempfile::TempDir::new().unwrap();
    let library = photo_core::local_library::LocalLibrary::open(root.path()).unwrap();
    let database = rusqlite::Connection::open(root.path().join("library.sqlite")).unwrap();
    database
        .execute(
            "INSERT INTO cloud_accounts(account_id,endpoint,username,token_file,device_id,created_at_ms,is_active) \
             VALUES('acct','http://127.0.0.1:8790','alice','cloud/acct/session.token','device',1,1)",
            [],
        )
        .unwrap();
    database
        .execute(
            "INSERT INTO cloud_sync_state(account_id,status,updated_at_ms) VALUES('acct','idle',1)",
            [],
        )
        .unwrap();
    drop(database);
    let token = root.path().join("cloud").join("acct").join("session.token");
    std::fs::create_dir_all(token.parent().unwrap()).unwrap();
    std::fs::write(&token, b"token").unwrap();
    let engine = photo_core::cloud::CloudEngine::new(library.clone());
    let status = engine.logout().unwrap();
    assert!(!status.logged_in, "logout must end the session");
    assert!(!token.exists(), "logout must remove the session token");
    let database = rusqlite::Connection::open(root.path().join("library.sqlite")).unwrap();
    let state: String = database
        .query_row(
            "SELECT status FROM cloud_sync_state WHERE account_id='acct'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(state, "logged_out");
    // The account row survives for offline browsing and a later re-login.
    let accounts: i64 = database
        .query_row("SELECT COUNT(*) FROM cloud_accounts", [], |r| r.get(0))
        .unwrap();
    assert_eq!(accounts, 1);
}

#[test]
fn choosing_a_download_root_clears_the_missing_root_error() {
    let root = TempDir::new().unwrap();
    let downloads = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let database = Connection::open(root.path().join("library.sqlite")).unwrap();
    database
        .execute(
            "INSERT INTO cloud_accounts(account_id,endpoint,username,token_file,device_id,created_at_ms,is_active) \
             VALUES('acct','http://127.0.0.1:8790','alice','cloud/acct/session.token','device',1,1)",
            [],
        )
        .unwrap();
    database
        .execute(
            "INSERT INTO cloud_sync_state(account_id,status,error_code,updated_at_ms) \
             VALUES('acct','error','DownloadRootMissing',1)",
            [],
        )
        .unwrap();
    drop(database);

    let engine = photo_core::cloud::CloudEngine::new(library);
    let status = engine
        .set_download_root(downloads.path().to_str().unwrap())
        .unwrap();
    let canonical = downloads.path().canonicalize().unwrap();
    assert_eq!(status.download_root.as_deref(), canonical.to_str());
    assert_eq!(status.error_code, None, "the resolved error still shows");
    assert_eq!(status.state, "idle");
}
