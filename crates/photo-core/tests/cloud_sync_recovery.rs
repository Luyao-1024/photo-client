#[path = "support/cloud_server.rs"]
mod cloud_server;

use cloud_server::{Fixture, successful};
use photo_core::local_library::PhotoFilter;
use syncserver_client as sdk;

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn repeated_favorite_toggles_reach_the_server() {
    let fixture = Fixture::uploaded().await;
    for desired in [true, false, true, false, true] {
        fixture
            .library
            .set_favorite(fixture.media_id.clone(), desired)
            .unwrap();
        let stamp: (i64, String, String) = fixture
            .db
            .query_row(
                "SELECT edited_at_ms,source,event_id FROM media_sync_state WHERE media_id=?1",
                [&fixture.media_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(
            fixture
                .db
                .query_row(
                    "SELECT dirty FROM media_sync_state WHERE media_id=?1",
                    [&fixture.media_id],
                    |r| r.get::<_, i64>(0)
                )
                .unwrap(),
            2
        );
        let report = fixture.engine.sync_now().await.unwrap();
        successful(&report);
        let event = fixture
            .connection
            .fetch_photo(&fixture.zone, &fixture.photo_id)
            .await
            .unwrap()
            .asset
            .events
            .metadata_event
            .unwrap();
        assert_eq!((event.edited_at_ms, event.source, event.event_id), stamp);
        assert_eq!(
            fixture
                .db
                .query_row(
                    "SELECT dirty FROM media_sync_state WHERE media_id=?1",
                    [&fixture.media_id],
                    |r| r.get::<_, i64>(0)
                )
                .unwrap(),
            0
        );
        assert_eq!(
            fixture
                .connection
                .fetch_photo(&fixture.zone, &fixture.photo_id)
                .await
                .unwrap()
                .is_favorite,
            desired
        );
        assert_eq!(fixture.engine.status().unwrap().pending_favorites, 0);
        assert_eq!(report.favorites_uploaded, 1);
    }
    successful(&fixture.engine.sync_now().await.unwrap());
    assert!(
        fixture
            .library
            .photo(fixture.media_id.clone())
            .unwrap()
            .favorite
    );
}

async fn freeze_metadata(fixture: &Fixture, photo: &sdk::RemotePhoto) -> sdk::MetadataMutation {
    let (local,version,favorite,time,source,event):(i64,i64,bool,i64,String,String)=fixture.db.query_row("SELECT s.local_version,s.metadata_version,m.favorite,s.edited_at_ms,s.source,s.event_id FROM media_sync_state s JOIN media m ON m.library_id=s.library_id AND m.media_id=s.media_id WHERE s.media_id=?1",[&fixture.media_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).unwrap();
    let mut metadata = photo.metadata();
    metadata.is_favorite = favorite;
    let mutation = sdk::MetadataMutation {
        operation_id: format!("photo-op-{}", uuid::Uuid::new_v4()),
        zone: fixture.zone.clone(),
        photo_id: photo.photo_id.clone(),
        record_revision: photo.asset_revision.clone(),
        metadata,
        event: sdk::EditEvent {
            edited_at_ms: time,
            source,
            event_id: event,
        },
    };
    // Model the durable boundary immediately before transmission.
    fixture.db.execute("INSERT INTO cloud_metadata_operations(account_id,photo_id,operation_id,zone_name,record_revision,captured_local_version,captured_metadata_version,relative_path,is_favorite,is_hidden,asset_date_ms,edited_at_ms,source,event_id,created_at_ms,library_id,media_id) SELECT account_id,?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?11,?14,?15 FROM cloud_accounts",rusqlite::params![mutation.photo_id,mutation.operation_id,mutation.zone.zone_name,mutation.record_revision,local,version,mutation.metadata.relative_path,favorite,mutation.metadata.is_hidden,mutation.metadata.asset_date_ms,time,mutation.event.source,mutation.event.event_id,fixture.library.library_id,fixture.media_id]).unwrap();
    mutation
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn metadata_retry_reuses_the_frozen_generic_request_and_edit_event() {
    let fixture = Fixture::uploaded().await;
    let lease = fixture.modify_lease().await;
    fixture
        .library
        .set_favorite(fixture.media_id.clone(), true)
        .unwrap();
    let photo = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    let mutation = freeze_metadata(&fixture, &photo).await;
    let first = sdk::update_metadata(&fixture.connection, &lease, &mutation)
        .await
        .unwrap();
    let second = sdk::update_metadata(&fixture.connection, &lease, &mutation)
        .await
        .unwrap();
    assert_eq!(first.record_change_tag, second.record_change_tag);
    assert_eq!(second.events.metadata_event.as_ref(), Some(&mutation.event));
    let state = fixture
        .connection
        .operation_status(&mutation.operation_id)
        .await
        .unwrap();
    let sdk::OperationState::Committed(receipt) = state else {
        panic!("not committed")
    };
    assert_eq!(
        sdk::metadata_receipt(&mutation, &receipt)
            .unwrap()
            .events
            .metadata_event,
        Some(mutation.event.clone())
    );
    lease.release().await.unwrap();
    // Close the actor and reopen the real SQLite catalog. No in-memory request
    // survives; startup must load and settle the exact persisted operation.
    drop(fixture.engine);
    drop(fixture.library);
    let reopened = photo_core::local_library::LocalLibrary::open(fixture._root.path()).unwrap();
    let resumed = photo_core::cloud::CloudEngine::new(reopened);
    successful(&resumed.sync_now().await.unwrap());
    assert_eq!(resumed.status().unwrap().pending_favorites, 0);
    assert_eq!(
        fixture
            .db
            .query_row("SELECT COUNT(*) FROM cloud_metadata_operations", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap(),
        0
    );
    let remote = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    assert_eq!(remote.relative_path, photo.relative_path);
    assert_eq!(remote.asset_date_ms, photo.asset_date_ms);
    assert_eq!(remote.asset.events.metadata_event, Some(mutation.event));
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn delayed_metadata_callback_cannot_clear_a_later_same_value_edit() {
    let fixture = Fixture::uploaded().await;
    let lease = fixture.modify_lease().await;
    fixture
        .library
        .set_favorite(fixture.media_id.clone(), true)
        .unwrap();
    let photo = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    let old = freeze_metadata(&fixture, &photo).await;
    sdk::update_metadata(&fixture.connection, &lease, &old)
        .await
        .unwrap();
    fixture
        .library
        .set_favorite(fixture.media_id.clone(), false)
        .unwrap();
    fixture
        .library
        .set_favorite(fixture.media_id.clone(), true)
        .unwrap();
    // Force all three edits to the same millisecond: category versions and event
    // identity must still prevent the old response from settling the third edit.
    fixture
        .db
        .execute(
            "UPDATE media_sync_state SET edited_at_ms=?1",
            [old.event.edited_at_ms],
        )
        .unwrap();
    let latest: String = fixture
        .db
        .query_row("SELECT event_id FROM media_sync_state", [], |r| r.get(0))
        .unwrap();
    assert_ne!(latest, old.event.event_id);
    lease.release().await.unwrap();
    let report = fixture.engine.sync_now().await.unwrap();
    successful(&report);
    assert_eq!(report.favorites_uploaded, 2);
    let remote = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    assert!(remote.is_favorite);
    assert_eq!(remote.asset.events.metadata_event.unwrap().event_id, latest);
    let versions: (i64, i64, i64) = fixture
        .db
        .query_row(
            "SELECT dirty,metadata_version,acked_metadata_version FROM media_sync_state",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(versions, (0, 3, 3));
}

async fn recover_create(missing_original: bool) {
    let fixture = Fixture::uploaded().await;
    fixture.lose_create_acknowledgement();
    // Preserve a newer local favorite while recovering the committed create.
    fixture
        .library
        .set_favorite(fixture.media_id.clone(), true)
        .unwrap();
    if missing_original {
        std::fs::remove_file(&fixture.file).unwrap();
    }
    let report = fixture.engine.sync_now().await.unwrap();
    successful(&report);
    assert_eq!(report.uploaded, 1);
    assert_eq!(report.downloaded, u32::from(missing_original));
    let page = fixture
        .library
        .query(PhotoFilter::default(), None, 100)
        .unwrap();
    assert_eq!(page.total, 1);
    assert_eq!(page.items[0].id, fixture.media_id);
    assert!(std::path::Path::new(&page.items[0].path).is_file());
    assert_eq!(
        fixture.engine.bound_media_ids().unwrap(),
        vec![fixture.media_id.clone()]
    );
    assert_eq!(fixture.engine.status().unwrap().pending_uploads, 0);
    assert!(
        fixture
            .connection
            .fetch_photo(&fixture.zone, &fixture.photo_id)
            .await
            .unwrap()
            .is_favorite
    );
    successful(&fixture.engine.sync_now().await.unwrap());
    assert_eq!(
        fixture
            .library
            .query(PhotoFilter::default(), None, 100)
            .unwrap()
            .total,
        1
    );
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn committed_create_recovers_without_importing_a_duplicate() {
    recover_create(false).await;
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn committed_create_recovers_when_the_original_is_missing() {
    recover_create(true).await;
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn renamed_remote_path_can_be_reused_by_another_photo() {
    let fixture = Fixture::uploaded().await;
    let lease = fixture.modify_lease().await;
    let photo = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    let mut metadata = photo.metadata();
    metadata.relative_path = "Uploads/2023/renamed.jpg".into();
    fixture
        .connection
        .update_photo_metadata(&lease, &photo, metadata.clone())
        .await
        .unwrap();
    lease.advance_phase().await.unwrap();
    let second = fixture.create_at(&lease, photo.relative_path.clone()).await;
    lease.release().await.unwrap();
    let report = fixture.engine.sync_now().await.unwrap();
    successful(&report);
    assert_eq!(report.downloaded, 1);
    let path: String = fixture
        .db
        .query_row(
            "SELECT relative_path FROM cloud_bindings WHERE photo_id=?1",
            [&photo.photo_id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(path, metadata.relative_path);
    let second_path: String = fixture
        .db
        .query_row(
            "SELECT relative_path FROM cloud_bindings WHERE photo_id=?1",
            [&second.photo_id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(second_path, photo.relative_path);
    successful(&fixture.engine.sync_now().await.unwrap());
    assert_eq!(
        fixture
            .library
            .query(PhotoFilter::default(), None, 100)
            .unwrap()
            .total,
        2
    );
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn unknown_metadata_request_survives_restart_and_preserves_a_newer_local_edit() {
    let fixture = Fixture::uploaded().await;
    let lease = fixture.modify_lease().await;
    fixture
        .library
        .set_favorite(fixture.media_id.clone(), true)
        .unwrap();
    let photo = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    let operation = freeze_metadata(&fixture, &photo).await;
    fixture
        .library
        .set_favorite(fixture.media_id.clone(), false)
        .unwrap();
    lease.release().await.unwrap();
    assert!(matches!(
        fixture
            .connection
            .operation_status(&operation.operation_id)
            .await
            .unwrap(),
        sdk::OperationState::Unknown
    ));
    drop(fixture.engine);
    drop(fixture.library);
    let reopened = photo_core::local_library::LocalLibrary::open(fixture._root.path()).unwrap();
    let resumed = photo_core::cloud::CloudEngine::new(reopened);
    successful(&resumed.sync_now().await.unwrap());
    assert_eq!(resumed.status().unwrap().pending_favorites, 1);
    let remote = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    assert!(remote.is_favorite);
    assert_eq!(remote.asset.events.metadata_event, Some(operation.event));
    successful(&resumed.sync_now().await.unwrap());
    assert_eq!(resumed.status().unwrap().pending_favorites, 0);
    assert!(
        !fixture
            .connection
            .fetch_photo(&fixture.zone, &fixture.photo_id)
            .await
            .unwrap()
            .is_favorite
    );
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn new_upload_preserves_the_original_local_metadata_edit_time() {
    let fixture = Fixture::uploaded_with_favorite(true).await;
    let local: (i64, String, String) = fixture
        .db
        .query_row(
            "SELECT edited_at_ms,source,event_id FROM media_sync_state WHERE media_id=?1",
            [&fixture.media_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    let remote = fixture
        .connection
        .fetch_photo(&fixture.zone, &fixture.photo_id)
        .await
        .unwrap();
    let event = remote.asset.events.metadata_event.unwrap();
    assert_eq!(event.edited_at_ms, 1700000000123);
    assert_eq!((event.edited_at_ms, event.source, event.event_id), local);
    assert!(remote.is_favorite);
    assert_eq!(fixture.engine.status().unwrap().pending_favorites, 0);
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn persisted_cloud_scope_mismatch_stops_before_replaying_metadata() {
    let fixture = Fixture::uploaded().await;
    fixture
        .library
        .set_favorite(fixture.media_id.clone(), true)
        .unwrap();
    let expected = uuid::Uuid::new_v4().to_string();
    fixture
        .db
        .execute(
            "UPDATE cloud_account_scope SET database_generation=?1",
            [&expected],
        )
        .unwrap();
    drop(fixture.engine);
    drop(fixture.library);
    let reopened = photo_core::local_library::LocalLibrary::open(fixture._root.path()).unwrap();
    let resumed = photo_core::cloud::CloudEngine::new(reopened);
    assert_eq!(resumed.sync_now().await.unwrap_err(), "CloudScopeChanged");
    assert_eq!(
        fixture
            .db
            .query_row(
                "SELECT database_generation FROM cloud_account_scope",
                [],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
        expected
    );
    assert_eq!(
        fixture
            .db
            .query_row("SELECT dirty FROM media_sync_state", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        2
    );
    assert_eq!(
        fixture
            .db
            .query_row("SELECT COUNT(*) FROM cloud_metadata_operations", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap(),
        0
    );
    assert!(
        !fixture
            .connection
            .fetch_photo(&fixture.zone, &fixture.photo_id)
            .await
            .unwrap()
            .is_favorite
    );
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; isolated cache-only upload check"]
async fn upload_without_a_thumbnail_defers_then_resumes_from_local_cache() {
    let fixture = Fixture::uploaded().await;
    let folder = std::path::Path::new(&fixture.file).parent().unwrap();
    let file = folder.join("uncached.jpg");
    image::RgbImage::from_pixel(64, 48, image::Rgb([30, 80, 140]))
        .save(&file)
        .unwrap();
    let media = photo_core::media::inspect_file(&file).unwrap();
    let source = fixture.library.add_source(folder).unwrap();
    fixture
        .library
        .upsert_batch(
            source,
            vec![photo_core::local_library::MediaInput {
                path: file.to_string_lossy().into(),
                name: media.display_name,
                parent: media.parent_path.to_string_lossy().into(),
                size_bytes: media.size_bytes,
                modified_ns: media.modified_ns,
                mime_type: media.mime_type,
                width: media.width,
                height: media.height,
                orientation: media.orientation,
                capture_time_ms: media.capture_time_ms,
            }],
        )
        .unwrap();
    let photo = fixture
        .library
        .query_window(
            PhotoFilter {
                search: "uncached".into(),
                ..PhotoFilter::default()
            },
            0,
            1,
        )
        .unwrap()
        .items
        .remove(0);
    assert_eq!(
        fixture
            .engine
            .queue_upload(vec![photo.id.clone()])
            .unwrap()
            .queued,
        1
    );
    let report = fixture.engine.sync_now().await.unwrap();
    successful(&report);
    assert_eq!(report.uploaded, 0);
    assert_eq!(fixture.engine.status().unwrap().pending_uploads, 1);
    let state: (String, u32, Option<String>) = fixture
        .db
        .query_row(
            "SELECT state,attempt,error_code FROM cloud_uploads WHERE media_id=?1",
            [&photo.id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(state, ("pending".into(), 0, None));
    assert!(!fixture.library.root.join("cache").join(&photo.id).exists());
    let loader = photo_core::thumbnail_loader::ThumbnailLoader::new(fixture.library.clone(), 1);
    loader
        .request(
            photo.id.clone(),
            Some(photo.content_version),
            512,
            "after-defer".into(),
            0,
        )
        .unwrap()
        .await
        .unwrap()
        .unwrap();
    loader.close();
    let report = fixture.engine.sync_now().await.unwrap();
    successful(&report);
    assert_eq!(report.uploaded, 1);
    assert_eq!(fixture.engine.status().unwrap().pending_uploads, 0);
}
