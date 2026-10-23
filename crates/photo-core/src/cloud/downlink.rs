//! Reliable downlink: cache complete change pages, rebuild once, then settle
//! every referenced file before advancing the zone token.
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use syncserver_client as sdk;

use super::*;
use crate::local_library::{CloudBindingMedia, CloudBindingUpdate, RemoteMediaInput};

enum DownloadOutcome {
    Downloaded,
    Unsupported,
    Gone,
}

/// Where this account's downloads publish: the user-chosen real root and the
/// linked source row it is registered under.
struct DownloadContext {
    source_id: String,
    download_root: PathBuf,
}

impl CloudEngine {
    pub(super) async fn downlink(
        &self,
        session: &CloudSession,
        report: &mut CloudSyncReport,
    ) -> Result<(), String> {
        let account_id = session.account.account_id.clone();
        let download_root = session
            .account
            .download_root
            .clone()
            .ok_or_else(|| "DownloadRootMissing".to_owned())?;
        let download_root = PathBuf::from(download_root);
        let source_id = self
            .library
            .add_source(&download_root)
            .map_err(|_| "DownloadRootUnavailable".to_owned())?;
        let context = DownloadContext {
            source_id,
            download_root,
        };
        let state = store(self.library.cloud_sync_state(account_id.clone()))?.unwrap_or_default();
        let mut sync_token = state.sync_token;
        let mut snapshot_token = state.snapshot_token;
        let mut restarted = false;

        loop {
            if self.library.is_closed() {
                return Err("LibraryClosed".into());
            }
            let Some(current) = sync_token.clone() else {
                // Bootstrap is only allowed to start from a cleared cache, so
                // a rebuild never mixes snapshots from two generations.
                store(
                    self.library
                        .cloud_clear_records_and_token(account_id.clone()),
                )?;
                let bootstrap = session
                    .connection
                    .bootstrap(&session.zone)
                    .await
                    .map_err(|error| sdk_code(&error))?;
                let records = bootstrap
                    .masters
                    .iter()
                    .chain(bootstrap.assets.iter())
                    .map(records::stored)
                    .collect::<Result<Vec<_>, _>>()?;
                store(
                    self.library
                        .cloud_replace_records(account_id.clone(), records),
                )?;
                sync_token = Some(bootstrap.sync_token);
                snapshot_token = Some(bootstrap.snapshot_token);
                break;
            };

            let mut token = current;
            let mut expired = false;
            loop {
                if self.library.is_closed() {
                    return Err("LibraryClosed".into());
                }
                let request = sdk::ZoneChangesRequest::new(session.zone.clone())
                    .token(token.clone())
                    .record_types([
                        sdk::MASTER_RECORD_TYPE.to_owned(),
                        sdk::ASSET_RECORD_TYPE.to_owned(),
                    ]);
                match session.connection.changes_zone(&request).await {
                    Ok(page) => {
                        if !page.failures.is_empty() {
                            return Err("ChangeFailed".into());
                        }
                        let records = page
                            .records
                            .iter()
                            .map(records::stored)
                            .collect::<Result<Vec<_>, _>>()?;
                        store(
                            self.library
                                .cloud_apply_record_changes(account_id.clone(), records),
                        )?;
                        token = page.sync_token;
                        if !page.more_coming {
                            sync_token = Some(token);
                            break;
                        }
                    }
                    Err(sdk::Error::ExpiredSyncToken) if !restarted => {
                        restarted = true;
                        expired = true;
                        break;
                    }
                    Err(error) => return Err(sdk_code(&error)),
                }
            }
            if expired {
                store(
                    self.library
                        .cloud_clear_records_and_token(account_id.clone()),
                )?;
                sync_token = None;
                snapshot_token = None;
                continue;
            }
            break;
        }

        // Only a complete set of pages may be interpreted. A half pair or a
        // duplicate path keeps the previous token and cache untouched.
        let cached = store(self.library.cloud_records(account_id.clone()))?;
        let graph = records::graph(&cached)?;
        let remote_ids: Vec<String> = graph
            .photos
            .iter()
            .map(|photo| photo.photo_id.clone())
            .collect();

        store(
            self.library.cloud_refresh_binding_paths(
                account_id.clone(),
                graph
                    .photos
                    .iter()
                    .map(|photo| (photo.photo_id.clone(), photo.relative_path.clone()))
                    .collect(),
            ),
        )?;

        // The files mirror the cloud path inside the real download root: a
        // rename or album move on the cloud side moves the local file too,
        // without downloading it again.
        store(
            self.library
                .cloud_sync_remote_paths(account_id.clone(), context.download_root.clone()),
        )?;

        // A committed create can reach this graph before its response/binding
        // reached the client. Reattach its durable intent before classifying
        // unbound photos as downloads, preserving the original local media ID.
        let pending: HashMap<_, _> = store(self.library.cloud_pending_uploads(account_id.clone()))?
            .into_iter()
            .map(|upload| (upload.photo_id.clone(), upload))
            .collect();
        for photo in &graph.photos {
            if let Some(upload) = pending.get(&photo.photo_id)
                && upload.master_id == photo.master_id
                && upload.content_generation == photo.content_generation
            {
                self.publish_binding(&account_id, upload, photo, report)
                    .await?;
            }
        }

        let bindings: HashMap<String, _> = store(self.library.cloud_bindings(account_id.clone()))?
            .into_iter()
            .map(|binding| (binding.photo_id.clone(), binding))
            .collect();
        let pending_deletes: HashSet<String> = store(
            self.library
                .cloud_pending_delete_photo_ids(account_id.clone()),
        )?
        .into_iter()
        .collect();
        let media: HashMap<String, CloudBindingMedia> =
            store(self.library.cloud_binding_media(account_id.clone()))?
                .into_iter()
                .map(|media| (media.media_id.clone(), media))
                .collect();

        let mut updates = Vec::new();
        let mut downloads = Vec::new();
        let mut skipped = 0;
        for photo in &graph.photos {
            if pending_deletes.contains(&photo.photo_id) {
                skipped += 1;
                continue;
            }
            let hidden = photo.is_hidden;
            let trashed = records::is_trashed(photo);
            let inactive = hidden || trashed;
            let Some(binding) = bindings.get(&photo.photo_id) else {
                if inactive {
                    skipped += 1;
                } else {
                    downloads.push(photo.clone());
                }
                continue;
            };
            let info = media.get(&binding.media_id);
            let unsupported = info.is_some_and(|info| info.state == "unsupported");
            let present = info.is_some_and(|info| Path::new(&info.path).is_file());
            let was_inactive = binding.is_hidden || binding.is_trashed;
            let pending = binding.dirty != 0;
            let locally_trashed = info.is_some_and(|info| info.state == "trashed");
            let generation_changed = binding.content_generation != photo.content_generation;
            let mut media_state = None;
            if inactive {
                // A pending local edit (trash/restore) owns the local state
                // until the server echoes it.
                if !unsupported && !pending && !locally_trashed {
                    media_state = Some("missing".to_owned());
                }
                skipped += 1;
            } else if unsupported {
                // A decoded failure is not retried every cycle; the binding
                // keeps the file so export/copy still work.
            } else if present {
                if !pending
                    && !locally_trashed
                    && (was_inactive || info.is_some_and(|info| info.state != "active"))
                {
                    media_state = Some("active".to_owned());
                }
            } else if locally_trashed {
                // The file lives in the system trash until the local restore.
                skipped += 1;
            } else {
                downloads.push(photo.clone());
            }
            updates.push(CloudBindingUpdate {
                photo_id: photo.photo_id.clone(),
                is_hidden: hidden,
                is_trashed: trashed,
                content_stale: binding.content_stale || (generation_changed && present),
                media_state,
            });
        }
        if !updates.is_empty() {
            for batch in updates.chunks(100) {
                store(
                    self.library
                        .cloud_apply_binding_updates(account_id.clone(), batch.to_vec()),
                )?;
            }
        }
        let orphans = store(
            self.library
                .cloud_deactivate_orphan_bindings(account_id.clone(), remote_ids),
        )?;
        report.skipped += skipped + orphans;
        report.download_total = downloads.len() as u32;
        self.notify("receiving", report);

        let metadata: Vec<_> = graph
            .photos
            .iter()
            .filter(|p| bindings.contains_key(&p.photo_id))
            .collect();
        for batch in metadata.chunks(100) {
            report.favorites_applied += store(
                self.library.cloud_apply_remote_metadata_batch(
                    account_id.clone(),
                    batch
                        .iter()
                        .map(|p| {
                            (
                                p.photo_id.clone(),
                                p.is_favorite,
                                p.asset.events.metadata_event.clone(),
                            )
                        })
                        .collect(),
                ),
            )?;
            self.notify("receiving", report);
            self.admitted(false);
        }

        for photo in downloads {
            if self.library.is_closed() {
                return Err("LibraryClosed".into());
            }
            match self.download_photo(session, &context, &photo).await? {
                DownloadOutcome::Downloaded => {
                    report.downloaded += 1;
                    self.admitted(false);
                }
                DownloadOutcome::Unsupported | DownloadOutcome::Gone => {
                    report.skipped += 1;
                }
            }
            self.notify("receiving", report);
        }

        let token = sync_token.ok_or("NotCurrent")?;
        store(self.library.cloud_commit_download(
            account_id,
            session.zone.zone_name.clone(),
            snapshot_token,
            token,
        ))?;
        self.admitted(true);
        report.state = "idle".into();
        Ok(())
    }

    async fn download_photo(
        &self,
        session: &CloudSession,
        context: &DownloadContext,
        graph_photo: &sdk::RemotePhoto,
    ) -> Result<DownloadOutcome, String> {
        let photo = match session
            .connection
            .fetch_photo(&session.zone, &graph_photo.photo_id)
            .await
        {
            Ok(photo) => photo,
            Err(sdk::Error::NotFound(_)) => return Ok(DownloadOutcome::Gone),
            Err(error) => return Err(sdk_code(&error)),
        };
        let account_id = session.account.account_id.clone();
        let original_extension =
            paths::download_extension(&photo.relative_path, &photo.original.mime_type)
                .ok_or("UnsupportedMedia")?;
        let thumbnail_extension =
            paths::thumbnail_extension(&photo.thumbnail.mime_type).ok_or("UnsupportedMedia")?;
        // The original publishes as a real file of a real album directory
        // inside the download root; the thumbnail stays in the private cache.
        let placement = paths::download_placement(&context.download_root, &photo.relative_path);
        fs::create_dir_all(&placement.directory)
            .map_err(|_| "DownloadRootUnavailable".to_owned())?;
        let thumbnail_directory = paths::thumbnail_cache_dir(
            &self.library.root,
            &account_id,
            &photo.photo_id,
            &photo.content_generation,
        )?;
        paths::private_directory(&thumbnail_directory)?;
        let thumbnail_path = thumbnail_directory.join(format!("thumbnail.{thumbnail_extension}"));

        let original_descriptor = session
            .connection
            .describe_asset(&photo.original.asset_id, sdk::AssetRole::Original)
            .await
            .map_err(|error| sdk_code(&error))?;
        let thumbnail_descriptor = session
            .connection
            .describe_asset(&photo.thumbnail.asset_id, sdk::AssetRole::Thumbnail)
            .await
            .map_err(|error| sdk_code(&error))?;
        let thumbnail_sha256 = thumbnail_descriptor
            .digest()
            .map_err(|error| sdk_code(&error))?
            .hex()
            .to_owned();
        let expected = original_descriptor
            .digest()
            .map_err(|error| sdk_code(&error))?;
        let wanted = format!("{}.{original_extension}", placement.stem);
        let mut original_path = placement.directory.join(&wanted);
        if original_path.exists() {
            // Verified bytes of an unclaimed file are reused; a name another
            // photo of this account already owns gets a fresh spelling.
            let verified = original_path.is_file()
                && sdk::ContentDigest::from_file(&original_path)
                    .await
                    .is_ok_and(|actual| {
                        actual.size() == expected.size() && actual.hex() == expected.hex()
                    });
            let claimed = verified
                && store(self.library.cloud_path_claimed_by_other(
                    account_id.clone(),
                    photo.photo_id.clone(),
                    original_path.to_string_lossy().into_owned(),
                ))?;
            if !verified || claimed {
                original_path =
                    crate::local_library::unique_destination(&placement.directory, &wanted)?;
            }
        }
        ensure_asset(&session.connection, &original_descriptor, &original_path).await?;
        ensure_asset(&session.connection, &thumbnail_descriptor, &thumbnail_path).await?;

        let metadata = fs::metadata(&original_path).map_err(|_| "Internal")?;
        let size_bytes = metadata.len();
        let modified_ns = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_nanos().min(i64::MAX as u128) as i64)
            .unwrap_or(0);
        let inspected = crate::media::inspect_file(&original_path);
        let (mime_type, media_kind, width, height, orientation, capture_time_ms, state, error_code) =
            match inspected {
                Ok(found) => {
                    let media_kind = if found.mime_type.starts_with("video/") {
                        "video".to_owned()
                    } else {
                        "image".to_owned()
                    };
                    (
                        found.mime_type,
                        media_kind,
                        found.width,
                        found.height,
                        found.orientation,
                        found.capture_time_ms,
                        "active",
                        None,
                    )
                }
                Err(_) => {
                    let mime = if photo.original.mime_type.is_empty() {
                        crate::media::mime_from_extension(&original_path)
                            .unwrap_or("application/octet-stream")
                            .to_owned()
                    } else {
                        photo.original.mime_type.clone()
                    };
                    let kind = if mime.starts_with("video/") {
                        "video".to_owned()
                    } else {
                        "image".to_owned()
                    };
                    (
                        mime,
                        kind,
                        photo.original.width,
                        photo.original.height,
                        1,
                        None,
                        "unsupported",
                        Some("UnsupportedMedia".to_owned()),
                    )
                }
            };
        let display_name = original_path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "photo".into());
        let parent_uri = original_path
            .parent()
            .map(|parent| parent.to_string_lossy().into_owned())
            .unwrap_or_default();
        let asset_date_ms = photo.asset_date_ms;
        let sort_time_ms = asset_date_ms
            .or(capture_time_ms)
            .unwrap_or(modified_ns / 1_000_000);
        let input = RemoteMediaInput {
            source_id: context.source_id.clone(),
            photo_id: photo.photo_id.clone(),
            master_id: photo.master_id.clone(),
            content_generation: photo.content_generation.clone(),
            relative_path: photo.relative_path.clone(),
            display_name,
            parent_uri,
            path: original_path.to_string_lossy().into_owned(),
            size_bytes,
            modified_ns,
            mime_type,
            media_kind,
            width,
            height,
            orientation,
            capture_time_ms,
            sort_time_ms,
            remote_favorite: photo.is_favorite,
            media_state: state.to_owned(),
            error_code: error_code.clone(),
            is_trashed: records::is_trashed(&photo),
            asset_date_ms,
            thumbnail_path: Some(thumbnail_path.to_string_lossy().into_owned()),
            thumbnail_sha256: Some(thumbnail_sha256),
        };
        store(self.library.cloud_publish_remote_media(account_id, input))?;
        store(self.library.cloud_apply_remote_metadata(
            session.account.account_id.clone(),
            photo.photo_id.clone(),
            photo.is_favorite,
            photo.asset.events.metadata_event.clone(),
        ))?;
        Ok(if state == "active" {
            DownloadOutcome::Downloaded
        } else {
            DownloadOutcome::Unsupported
        })
    }
}

/// Reuse a verified file or publish a new one through `.part` + fsync + rename.
async fn ensure_asset(
    connection: &sdk::Connection,
    descriptor: &sdk::DownloadDescriptor,
    path: &Path,
) -> Result<(), String> {
    let expected = descriptor.digest().map_err(|error| sdk_code(&error))?;
    if path.is_file() {
        let verified = sdk::ContentDigest::from_file(path)
            .await
            .is_ok_and(|actual| actual.size() == expected.size() && actual.hex() == expected.hex());
        if verified {
            return Ok(());
        }
        fs::remove_file(path).map_err(|_| "Internal")?;
    }
    let directory = path.parent().ok_or("Internal")?;
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .ok_or("Internal")?;
    let part = directory.join(format!(".{name}.{}.part", Uuid::new_v4()));
    if let Err(error) = connection.download_to_file(descriptor, &part).await {
        let _ = fs::remove_file(&part);
        return Err(sdk_code(&error));
    }
    let result = (|| -> std::io::Result<()> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&part, fs::Permissions::from_mode(0o600))?;
        }
        let file = OpenOptions::new().write(true).open(&part)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&part, path)?;
        File::open(directory)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&part);
    }
    result.map_err(|_| "Internal".into())
}
