//! Uplink under one exclusive lease: favorites first, then new photos.
use std::fs;
use std::path::PathBuf;

use syncserver_client as sdk;

use super::*;
use crate::local_library::{CloudBinding, CloudUpload};

const THUMBNAIL_LIMIT: u64 = 2 * 1024 * 1024;

struct Staging(PathBuf);
impl Drop for Staging {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

impl CloudEngine {
    pub(super) async fn uplink(
        &self,
        session: &CloudSession,
        report: &mut CloudSyncReport,
    ) -> Result<(), String> {
        let account_id = session.account.account_id.clone();
        let state = store(self.library.cloud_sync_state(account_id.clone()))?.unwrap_or_default();
        let applied_token = state.sync_token.ok_or("NotCurrent")?;
        let pending = store(self.library.cloud_pending_uploads(account_id.clone()))?;
        let dirty: Vec<CloudBinding> =
            store(self.library.cloud_dirty_bindings(account_id.clone()))?;
        if pending.is_empty() && dirty.is_empty() {
            return Ok(());
        }
        let lease = match sdk::UploadLease::acquire(
            &session.connection,
            &session.account.device_id,
            &session.zone,
        )
        .await
        {
            Ok(lease) => lease,
            Err(sdk::Error::LeaseBusy) => {
                report.skipped += 1;
                return Ok(());
            }
            Err(error) => return Err(sdk_code(&error)),
        };
        let outcome = self
            .drive_upload(session, &lease, &applied_token, &pending, &dirty, report)
            .await;
        let _ = lease.release().await;
        outcome
    }

    async fn drive_upload(
        &self,
        session: &CloudSession,
        lease: &sdk::UploadLease,
        applied_token: &str,
        pending: &[CloudUpload],
        dirty: &[CloudBinding],
        report: &mut CloudSyncReport,
    ) -> Result<(), String> {
        let check = lease
            .check(applied_token, true)
            .await
            .map_err(|error| sdk_code(&error))?;
        if !check.is_current || !check.may_upload {
            return Err("NotCurrent".into());
        }
        let mut phase = lease.phase().ok_or("NotCurrent")?;
        if phase == sdk::UploadPhase::Delete {
            phase = lease
                .advance_phase()
                .await
                .map_err(|error| sdk_code(&error))?
                .ok_or("Protocol")?;
        }
        if phase == sdk::UploadPhase::Modify {
            for batch in dirty.chunks(20) {
                let before = report.favorites_uploaded;
                let failed = report.failed;
                self.upload_metadata(session, lease, batch, report).await?;
                eprintln!(
                    "cloud_uplink_batch kind=metadata items={} uploaded={} failed={} status={}",
                    batch.len(),
                    report.favorites_uploaded - before,
                    report.failed - failed,
                    if report.failed == failed {
                        "complete"
                    } else {
                        "partial"
                    }
                );
                tokio::task::yield_now().await;
            }
            if !lease.is_held() {
                return Err("LeaseLost".into());
            }
            lease
                .advance_phase()
                .await
                .map_err(|error| sdk_code(&error))?;
        }
        if lease.phase() == Some(sdk::UploadPhase::Create) {
            for batch in pending.chunks(5) {
                let before = report.uploaded;
                let failed = report.failed;
                let skipped = report.skipped;
                self.upload_photos(session, lease, batch, report).await?;
                eprintln!(
                    "cloud_uplink_batch kind=photos items={} uploaded={} failed={} deferred_or_skipped={} status={}",
                    batch.len(),
                    report.uploaded - before,
                    report.failed - failed,
                    report.skipped - skipped,
                    if report.failed > failed {
                        "partial"
                    } else if report.skipped > skipped {
                        "deferred"
                    } else {
                        "complete"
                    }
                );
                tokio::task::yield_now().await;
            }
        }
        Ok(())
    }

    /// Resolve exact persisted requests before interpreting newer cloud metadata.
    pub(super) async fn recover_metadata_operations(
        &self,
        session: &CloudSession,
        report: &mut CloudSyncReport,
    ) -> Result<(), String> {
        let account = session.account.account_id.clone();
        for photo in store(
            self.library
                .cloud_metadata_operation_photos(account.clone()),
        )? {
            let Some(issued) = store(self.library.cloud_issued_metadata(account.clone(), photo))?
            else {
                continue;
            };
            match session
                .connection
                .operation_status(&issued.mutation.operation_id)
                .await
            {
                Ok(sdk::OperationState::Committed(receipt)) => {
                    match sdk::metadata_receipt(&issued.mutation, &receipt) {
                        Ok(record) => {
                            store(self.library.cloud_confirm_metadata(
                                account.clone(),
                                issued,
                                record,
                            ))?;
                            report.favorites_uploaded += 1;
                        }
                        Err(sdk::Error::InBand(failure)) if failure.code == "CONFLICT" => {
                            store(self.library.cloud_forget_rejected_metadata(
                                account.clone(),
                                issued.mutation.operation_id,
                            ))?;
                        }
                        Err(error) => return Err(sdk_code(&error)),
                    }
                }
                Ok(sdk::OperationState::Pending(_) | sdk::OperationState::Unknown) => {}
                Err(error) => return Err(sdk_code(&error)),
            }
        }
        Ok(())
    }

    async fn upload_metadata(
        &self,
        session: &CloudSession,
        lease: &sdk::UploadLease,
        dirty: &[CloudBinding],
        report: &mut CloudSyncReport,
    ) -> Result<(), String> {
        let account = session.account.account_id.clone();
        for binding in dirty {
            if self.library.is_closed() {
                return Err("LibraryClosed".into());
            }
            if !lease.is_held() {
                return Err("LeaseLost".into());
            }
            let issued = match store(
                self.library
                    .cloud_issued_metadata(account.clone(), binding.photo_id.clone()),
            )? {
                Some(issued) => Some(issued),
                None => {
                    let photo = match session
                        .connection
                        .fetch_photo(&session.zone, &binding.photo_id)
                        .await
                    {
                        Ok(photo) => photo,
                        Err(error) => {
                            let code = sdk_code(&error);
                            super::note_failure(report, &code);
                            if super::fatal(&code) {
                                return Err(code);
                            }
                            continue;
                        }
                    };
                    // Even an equal field value may represent a newer edit.
                    // Persist its event and captured versions before dispatch.
                    store(self.library.cloud_issue_metadata(
                        account.clone(),
                        photo,
                        session.zone.clone(),
                    ))?
                }
            };
            let Some(issued) = issued else {
                continue;
            };
            let result = match session
                .connection
                .operation_status(&issued.mutation.operation_id)
                .await
            {
                Ok(sdk::OperationState::Committed(receipt)) => {
                    sdk::metadata_receipt(&issued.mutation, &receipt)
                }
                Ok(sdk::OperationState::Pending(_)) => {
                    report.skipped += 1;
                    continue;
                }
                Ok(sdk::OperationState::Unknown) => {
                    sdk::update_metadata(&session.connection, lease, &issued.mutation).await
                }
                Err(error) => Err(error),
            };
            match result {
                Ok(record) => {
                    store(
                        self.library
                            .cloud_confirm_metadata(account.clone(), issued, record),
                    )?;
                    report.favorites_uploaded += 1;
                }
                Err(sdk::Error::InBand(failure)) if failure.code == "CONFLICT" => {
                    store(self.library.cloud_forget_rejected_metadata(
                        account.clone(),
                        issued.mutation.operation_id,
                    ))?;
                    return Err("NotCurrent".into());
                }
                Err(error) => {
                    let code = sdk_code(&error);
                    super::note_failure(report, &code);
                    if error.is_lease_lost() || super::fatal(&code) {
                        return Err(code);
                    }
                }
            }
        }
        Ok(())
    }

    async fn upload_photos(
        &self,
        session: &CloudSession,
        lease: &sdk::UploadLease,
        pending: &[CloudUpload],
        report: &mut CloudSyncReport,
    ) -> Result<(), String> {
        let account_id = session.account.account_id.clone();
        for upload in pending {
            if self.library.is_closed() {
                return Err("LibraryClosed".into());
            }
            if !lease.is_held() {
                return Err("LeaseLost".into());
            }
            // Resolve an earlier attempt before touching source files or
            // regenerating its thumbnail. A committed upload remains recoverable
            // even when the original has become unavailable in the meantime.
            let expected_operation =
                sdk::create_operation_id(&upload.photo_id, &upload.content_generation);
            if expected_operation != upload.operation_id {
                self.fail_upload(&account_id, upload, "Internal").await?;
                return Err("Internal".into());
            }
            match session
                .connection
                .operation_status(&upload.operation_id)
                .await
            {
                Ok(sdk::OperationState::Committed(_)) => {
                    self.publish_committed(session, upload, report).await?;
                    continue;
                }
                Ok(sdk::OperationState::Pending(_)) => {
                    report.skipped += 1;
                    continue;
                }
                Ok(sdk::OperationState::Unknown) => {}
                Err(error) => {
                    let code = sdk_code(&error);
                    store(self.library.cloud_set_upload_state(
                        account_id.clone(),
                        upload.media_id.clone(),
                        upload.content_generation.clone(),
                        "pending".into(),
                        Some(code.clone()),
                    ))?;
                    super::note_failure(report, &code);
                    if super::fatal(&code) {
                        return Err(code);
                    }
                    continue;
                }
            }
            let photo = match store(self.library.photo(upload.media_id.clone())) {
                Ok(photo) => photo,
                Err(_) => {
                    self.fail_upload(&account_id, upload, "SourceChanged")
                        .await?;
                    super::note_failure(report, "SourceChanged");
                    continue;
                }
            };
            if photo.state != "active"
                || photo.content_version != upload.content_version
                || photo.size_bytes != upload.size_bytes
                || photo.modified_ns != upload.modified_ns
            {
                self.fail_upload(&account_id, upload, "SourceChanged")
                    .await?;
                super::note_failure(report, "SourceChanged");
                continue;
            }
            let staging = match self.prepare_thumbnail(&account_id, &photo).await {
                Ok(path) => Staging(path),
                Err(code) if code == "ThumbnailDeferred" => {
                    report.skipped += 1;
                    continue;
                }
                Err(code) => {
                    let state = if code == "Internal" {
                        "pending"
                    } else {
                        "failed"
                    };
                    store(self.library.cloud_set_upload_state(
                        account_id.clone(),
                        upload.media_id.clone(),
                        upload.content_generation.clone(),
                        state.into(),
                        Some(code.clone()),
                    ))?;
                    super::note_failure(report, &code);
                    if super::fatal(&code) || code == "Internal" {
                        return Err(code);
                    }
                    continue;
                }
            };
            store(self.library.cloud_mark_upload_publishing(
                account_id.clone(),
                upload.media_id.clone(),
                upload.content_generation.clone(),
            ))?;
            // Reuse a versioned local cache. Source changes still invalidate
            // the upload intent before any assets are sent.
            let metadata = match fs::symlink_metadata(&photo.path) {
                Ok(metadata) => metadata,
                Err(_) => {
                    self.fail_upload(&account_id, upload, "SourceChanged")
                        .await?;
                    super::note_failure(report, "SourceChanged");
                    continue;
                }
            };
            let modified_ns = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|duration| duration.as_nanos().min(i64::MAX as u128) as i64)
                .unwrap_or(0);
            if metadata.len() != upload.size_bytes || modified_ns != upload.modified_ns {
                self.fail_upload(&account_id, upload, "SourceChanged")
                    .await?;
                super::note_failure(report, "SourceChanged");
                continue;
            }
            let mut original = match sdk::AssetUpload::from_file(
                PathBuf::from(&photo.path),
                photo.mime_type.clone(),
            )
            .await
            {
                Ok(asset) => asset,
                Err(_) => {
                    self.fail_upload(&account_id, upload, "SourceChanged")
                        .await?;
                    super::note_failure(report, "SourceChanged");
                    continue;
                }
            };
            if original.digest.size() != upload.size_bytes {
                self.fail_upload(&account_id, upload, "SourceChanged")
                    .await?;
                super::note_failure(report, "SourceChanged");
                continue;
            }
            if let (Some(width), Some(height)) = (photo.width, photo.height) {
                original = original.with_dimensions(width, height);
            }
            let thumbnail =
                match sdk::AssetUpload::from_file(staging.0.clone(), "image/jpeg".to_owned()).await
                {
                    Ok(asset) => asset,
                    Err(_) => {
                        self.fail_upload(&account_id, upload, "ThumbnailFailed")
                            .await?;
                        super::note_failure(report, "ThumbnailFailed");
                        continue;
                    }
                };
            let mut photo_metadata = sdk::PhotoMetadata::new(upload.relative_path.clone());
            photo_metadata.is_favorite = photo.favorite;
            photo_metadata.asset_date_ms =
                Some(photo.capture_time_ms.unwrap_or(photo.sort_time_ms));
            photo_metadata.is_hidden = false;
            let value = sdk::PhotoUpload::with_ids(
                upload.photo_id.clone(),
                upload.master_id.clone(),
                upload.content_generation.clone(),
                photo_metadata,
                original,
                thumbnail,
            );
            match session.connection.create_photo(lease, value).await {
                Ok(remote) => {
                    self.publish_binding(&account_id, upload, &remote, report)
                        .await?;
                }
                Err(error) => {
                    let code = sdk_code(&error);
                    let definitive = matches!(
                        code.as_str(),
                        "UploadRejected"
                            | "UploadFailed"
                            | "QuotaExceeded"
                            | "Protocol"
                            | "ServerRejected"
                            | "IdempotencyConflict"
                            | "UnsupportedMedia"
                            | "ThumbnailFailed"
                            | "ThumbnailTooLarge"
                            | "SourceChanged"
                    );
                    let state = if definitive { "failed" } else { "pending" };
                    store(self.library.cloud_set_upload_state(
                        account_id.clone(),
                        upload.media_id.clone(),
                        upload.content_generation.clone(),
                        state.into(),
                        Some(code.clone()),
                    ))?;
                    super::note_failure(report, &code);
                    if error.is_lease_lost() || super::fatal(&code) || code == "QuotaExceeded" {
                        return Err(code);
                    }
                }
            }
        }
        Ok(())
    }

    async fn prepare_thumbnail(
        &self,
        account_id: &str,
        photo: &crate::local_library::LocalPhoto,
    ) -> Result<PathBuf, String> {
        let library = self.library.clone();
        let photo = photo.clone();
        let account = account_id.to_owned();
        tokio::task::spawn_blocking(move || -> Result<PathBuf, String> {
            let source = crate::thumbnail_loader::cached_upload_source(&library, &photo)
                .ok_or("ThumbnailDeferred")?;
            let directory = library.root.join("cloud").join(account).join("staging");
            paths::private_directory(&directory)?;
            let destination = directory.join(format!("{}.jpg", Uuid::new_v4()));
            let result = (|| -> Result<(), String> {
                let metadata = fs::metadata(&source).map_err(|_| "Internal")?;
                if metadata.len() <= THUMBNAIL_LIMIT {
                    fs::copy(&source, &destination).map_err(|_| "Internal")?;
                    return Ok(());
                }
                let modified_ns = metadata
                    .modified()
                    .map_err(|_| "Internal")?
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| "Internal")?
                    .as_nanos() as i64;
                crate::media::prepare_thumbnail(
                    &source,
                    metadata.len(),
                    modified_ns,
                    512,
                    &destination,
                )
                .map_err(|_| "ThumbnailFailed")?;
                if fs::metadata(&destination).map_err(|_| "Internal")?.len() > THUMBNAIL_LIMIT {
                    return Err("ThumbnailTooLarge".into());
                }
                Ok(())
            })();
            if let Err(error) = result {
                let _ = fs::remove_file(&destination);
                return Err(error);
            }
            Ok(destination)
        })
        .await
        .map_err(|_| "Internal".to_owned())?
    }

    async fn fail_upload(
        &self,
        account_id: &str,
        upload: &CloudUpload,
        code: &str,
    ) -> Result<(), String> {
        store(self.library.cloud_set_upload_state(
            account_id.to_owned(),
            upload.media_id.clone(),
            upload.content_generation.clone(),
            "failed".into(),
            Some(code.to_owned()),
        ))
    }

    async fn publish_committed(
        &self,
        session: &CloudSession,
        upload: &CloudUpload,
        report: &mut CloudSyncReport,
    ) -> Result<(), String> {
        let remote = match session
            .connection
            .fetch_photo(&session.zone, &upload.photo_id)
            .await
        {
            Ok(photo) => photo,
            Err(error) => {
                let code = sdk_code(&error);
                store(self.library.cloud_set_upload_state(
                    session.account.account_id.clone(),
                    upload.media_id.clone(),
                    upload.content_generation.clone(),
                    "pending".into(),
                    Some(code.clone()),
                ))?;
                super::note_failure(report, &code);
                if super::fatal(&code) {
                    return Err(code);
                }
                return Ok(());
            }
        };
        if remote.content_generation != upload.content_generation {
            self.fail_upload(&session.account.account_id, upload, "SourceChanged")
                .await?;
            super::note_failure(report, "SourceChanged");
            return Ok(());
        }
        self.publish_binding(&session.account.account_id, upload, &remote, report)
            .await
    }

    pub(super) async fn publish_binding(
        &self,
        account_id: &str,
        upload: &CloudUpload,
        remote: &sdk::RemotePhoto,
        report: &mut CloudSyncReport,
    ) -> Result<(), String> {
        if remote.photo_id != upload.photo_id
            || remote.master_id != upload.master_id
            || remote.content_generation != upload.content_generation
        {
            self.fail_upload(account_id, upload, "Protocol").await?;
            super::note_failure(report, "Protocol");
            return Ok(());
        }
        store(self.library.cloud_publish_upload_binding(
            account_id.to_owned(),
            upload.media_id.clone(),
            upload.content_generation.clone(),
            remote.photo_id.clone(),
            remote.master_id.clone(),
            remote.relative_path.clone(),
            remote.is_favorite,
            remote.asset_date_ms,
        ))?;
        report.uploaded += 1;
        Ok(())
    }
}

#[cfg(test)]
mod thumbnail_tests {
    use super::*;
    use crate::local_library::{LocalLibrary, MediaInput, PhotoFilter};
    use crate::thumbnail_loader::ThumbnailLoader;
    use tempfile::TempDir;
    fn fixture() -> (
        TempDir,
        TempDir,
        CloudEngine,
        crate::local_library::LocalPhoto,
    ) {
        let root = TempDir::new().unwrap();
        let source_root = TempDir::new().unwrap();
        let source = source_root.path().join("source.jpg");
        image::RgbImage::from_pixel(64, 48, image::Rgb([10, 100, 200]))
            .save(&source)
            .unwrap();
        let media = crate::media::inspect_file(&source).unwrap();
        let library = LocalLibrary::open(root.path()).unwrap();
        let id = library.add_source(source_root.path()).unwrap();
        library
            .upsert_batch(
                id,
                vec![MediaInput {
                    path: source.to_string_lossy().into(),
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
        let photo = library
            .query_window(PhotoFilter::default(), 0, 1)
            .unwrap()
            .items
            .remove(0);
        (root, source_root, CloudEngine::new(library), photo)
    }
    #[tokio::test]
    async fn missing_cache_defers_without_decoding_or_creating_staging() {
        let (root, _sources, engine, photo) = fixture();
        let bytes = fs::read(&photo.path).unwrap();
        assert_eq!(
            engine
                .prepare_thumbnail("test-account", &photo)
                .await
                .unwrap_err(),
            "ThumbnailDeferred"
        );
        assert!(!root.path().join("cache").exists());
        assert!(!root.path().join("cloud").exists());
        assert_eq!(fs::read(&photo.path).unwrap(), bytes);
    }
    #[tokio::test]
    async fn cached_upload_reuses_bytes_without_accessing_the_original() {
        let (_root, _sources, engine, photo) = fixture();
        let loader = ThumbnailLoader::new(engine.library.clone(), 1);
        let path = loader
            .request(
                photo.id.clone(),
                Some(photo.content_version),
                512,
                "fixture".into(),
                0,
            )
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        loader.close();
        let expected = fs::read(&path).unwrap();
        fs::remove_file(&photo.path).unwrap();
        let staged = engine
            .prepare_thumbnail("test-account", &photo)
            .await
            .unwrap();
        assert_eq!(fs::read(&staged).unwrap(), expected);
        assert!(Path::new(&path).is_file());
    }
}
