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
            store(self.library.cloud_bindings(account_id.clone()))?
                .into_iter()
                .filter(|binding| binding.favorite_dirty)
                .collect();
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
            self.upload_favorites(session, lease, dirty, report).await?;
            if !lease.is_held() {
                return Err("LeaseLost".into());
            }
            lease
                .advance_phase()
                .await
                .map_err(|error| sdk_code(&error))?;
        }
        if lease.phase() == Some(sdk::UploadPhase::Create) {
            self.upload_photos(session, lease, pending, report).await?;
        }
        Ok(())
    }

    async fn upload_favorites(
        &self,
        session: &CloudSession,
        lease: &sdk::UploadLease,
        dirty: &[CloudBinding],
        report: &mut CloudSyncReport,
    ) -> Result<(), String> {
        let account_id = session.account.account_id.clone();
        for binding in dirty {
            if self.library.is_closed() {
                return Err("LibraryClosed".into());
            }
            if !lease.is_held() {
                return Err("LeaseLost".into());
            }
            let Some((_media_id, local_favorite)) = store(
                self.library
                    .cloud_binding_favorite(account_id.clone(), binding.photo_id.clone()),
            )?
            else {
                continue;
            };
            let photo = match session
                .connection
                .fetch_photo(&session.zone, &binding.photo_id)
                .await
            {
                Ok(photo) => photo,
                Err(sdk::Error::NotFound(_)) => {
                    store(
                        self.library
                            .cloud_clear_favorite_dirty(account_id.clone(), binding.photo_id.clone()),
                    )?;
                    report.skipped += 1;
                    continue;
                }
                Err(error) => {
                    let code = sdk_code(&error);
                    super::note_failure(report, &code);
                    if super::fatal(&code) {
                        return Err(code);
                    }
                    continue;
                }
            };
            if local_favorite == photo.is_favorite {
                store(self.library.cloud_finish_favorite_upload(
                    account_id.clone(),
                    binding.photo_id.clone(),
                    local_favorite,
                ))?;
                report.skipped += 1;
                continue;
            }
            let mut metadata = photo.metadata();
            metadata.is_favorite = local_favorite;
            let operation_id = sdk::update_metadata_operation_id(&photo.photo_id, &metadata);
            match session.connection.operation_status(&operation_id).await {
                Ok(sdk::OperationState::Committed(_)) => {
                    store(self.library.cloud_finish_favorite_upload(
                        account_id.clone(),
                        binding.photo_id.clone(),
                        local_favorite,
                    ))?;
                    report.favorites_uploaded += 1;
                }
                Ok(sdk::OperationState::Pending(_)) => {
                    report.skipped += 1;
                }
                Ok(sdk::OperationState::Unknown) => {
                    match session
                        .connection
                        .update_photo_metadata(lease, &photo, metadata)
                        .await
                    {
                        Ok(_) => {
                            store(self.library.cloud_finish_favorite_upload(
                                account_id.clone(),
                                binding.photo_id.clone(),
                                local_favorite,
                            ))?;
                            report.favorites_uploaded += 1;
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
                Err(error) => {
                    let code = sdk_code(&error);
                    super::note_failure(report, &code);
                    if super::fatal(&code) {
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
            let photo = match store(self.library.photo(upload.media_id.clone())) {
                Ok(photo) => photo,
                Err(_) => {
                    self.fail_upload(&account_id, upload, "SourceChanged").await?;
                    super::note_failure(report, "SourceChanged");
                    continue;
                }
            };
            if photo.state != "active"
                || photo.content_version != upload.content_version
                || photo.size_bytes != upload.size_bytes
                || photo.modified_ns != upload.modified_ns
            {
                self.fail_upload(&account_id, upload, "SourceChanged").await?;
                super::note_failure(report, "SourceChanged");
                continue;
            }
            store(self.library.cloud_mark_upload_publishing(
                account_id.clone(),
                upload.media_id.clone(),
                upload.content_generation.clone(),
            ))?;
            let staging = match self.prepare_thumbnail(&account_id, upload, &photo).await {
                Ok(path) => Staging(path),
                Err(code) => {
                    let state = if code == "Internal" { "pending" } else { "failed" };
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
            // The preview is generated from the same bytes that are about to
            // be uploaded; a change in between invalidates the whole intent.
            let metadata = match fs::symlink_metadata(&photo.path) {
                Ok(metadata) => metadata,
                Err(_) => {
                    self.fail_upload(&account_id, upload, "SourceChanged").await?;
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
                self.fail_upload(&account_id, upload, "SourceChanged").await?;
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
                    self.fail_upload(&account_id, upload, "SourceChanged").await?;
                    super::note_failure(report, "SourceChanged");
                    continue;
                }
            };
            if original.digest.size() != upload.size_bytes {
                self.fail_upload(&account_id, upload, "SourceChanged").await?;
                super::note_failure(report, "SourceChanged");
                continue;
            }
            if let (Some(width), Some(height)) = (photo.width, photo.height) {
                original = original.with_dimensions(width, height);
            }
            let thumbnail = match sdk::AssetUpload::from_file(
                staging.0.clone(),
                "image/jpeg".to_owned(),
            )
            .await
            {
                Ok(asset) => asset,
                Err(_) => {
                    self.fail_upload(&account_id, upload, "ThumbnailFailed").await?;
                    super::note_failure(report, "ThumbnailFailed");
                    continue;
                }
            };
            let mut photo_metadata = sdk::PhotoMetadata::new(upload.relative_path.clone());
            photo_metadata.is_favorite = photo.favorite;
            photo_metadata.asset_date_ms =
                Some(photo.capture_time_ms.unwrap_or(photo.sort_time_ms));
            photo_metadata.is_hidden = false;
            let expected_operation =
                sdk::create_operation_id(&upload.photo_id, &upload.content_generation);
            if expected_operation != upload.operation_id {
                self.fail_upload(&account_id, upload, "Internal").await?;
                return Err("Internal".into());
            }
            match session.connection.operation_status(&upload.operation_id).await {
                Ok(sdk::OperationState::Committed(_)) => {
                    self.publish_committed(session, upload, report).await?;
                }
                Ok(sdk::OperationState::Pending(_)) => {
                    store(self.library.cloud_set_upload_state(
                        account_id.clone(),
                        upload.media_id.clone(),
                        upload.content_generation.clone(),
                        "pending".into(),
                        None,
                    ))?;
                    report.skipped += 1;
                }
                Ok(sdk::OperationState::Unknown) => {
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
                            self.publish_binding(&account_id, upload, &remote, report).await?;
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
                            if error.is_lease_lost() || super::fatal(&code) || code == "QuotaExceeded"
                            {
                                return Err(code);
                            }
                        }
                    }
                }
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
                }
            }
        }
        Ok(())
    }

    async fn prepare_thumbnail(
        &self,
        account_id: &str,
        upload: &CloudUpload,
        photo: &crate::local_library::LocalPhoto,
    ) -> Result<PathBuf, String> {
        let directory = self
            .library
            .root
            .join("cloud")
            .join(account_id)
            .join("staging");
        paths::private_directory(&directory)?;
        let destination = directory.join(format!("{}.jpg", Uuid::new_v4()));
        let source = PathBuf::from(&photo.path);
        for max_edge in [2048_u32, 1600, 1200, 800] {
            let attempt = directory.join(format!("{}.{max_edge}.jpg", Uuid::new_v4()));
            let source = source.clone();
            let expected_size = upload.size_bytes;
            let expected_ns = upload.modified_ns;
            let target = attempt.clone();
            let generated = tokio::task::spawn_blocking(move || {
                crate::media::prepare_preview(
                    &source,
                    expected_size,
                    expected_ns,
                    max_edge,
                    &target,
                )
            })
            .await
            .map_err(|_| "Internal")?;
            match generated {
                Ok(()) => {
                    let size = fs::metadata(&attempt).map(|m| m.len()).unwrap_or(u64::MAX);
                    if size <= THUMBNAIL_LIMIT {
                        fs::rename(&attempt, &destination).map_err(|_| "Internal")?;
                        return Ok(destination);
                    }
                    let _ = fs::remove_file(&attempt);
                }
                Err(error) => {
                    let _ = fs::remove_file(&attempt);
                    return Err(if error.starts_with("SourceChanged") {
                        "SourceChanged".into()
                    } else if error.starts_with("UnsupportedSource")
                        || error.starts_with("UnsupportedMedia")
                    {
                        "UnsupportedMedia".into()
                    } else {
                        "ThumbnailFailed".into()
                    });
                }
            }
        }
        Err("ThumbnailTooLarge".into())
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
                self.fail_upload(&session.account.account_id, upload, &code)
                    .await?;
                super::note_failure(report, &code);
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

    async fn publish_binding(
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
