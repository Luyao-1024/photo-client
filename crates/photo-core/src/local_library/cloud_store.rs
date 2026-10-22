//! Cloud-sync persistence. Every method runs inside the catalog actor, and all
//! multi-row changes share one transaction.
use super::*;

#[derive(Debug, Clone)]
pub(crate) struct CloudAccount {
    pub account_id: String,
    pub endpoint: String,
    pub username: String,
    pub user_id: Option<String>,
    pub token_file: String,
    pub token_expires_at_ms: Option<i64>,
    pub device_id: String,
    pub created_at_ms: i64,
    pub last_sync_ms: Option<i64>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct CloudSyncState {
    pub zone_name: Option<String>,
    pub sync_token: Option<String>,
    pub snapshot_token: Option<String>,
    pub status: String,
    pub error_code: Option<String>,
    pub last_sync_ms: Option<i64>,
}

#[derive(Debug, Clone)]
pub(crate) struct StoredCloudRecord {
    pub record_name: String,
    pub record_type: Option<String>,
    pub record_change_tag: Option<String>,
    pub deleted: bool,
    pub record_json: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct CloudBinding {
    pub account_id: String,
    pub photo_id: String,
    pub master_id: String,
    pub content_generation: String,
    pub library_id: String,
    pub media_id: String,
    pub relative_path: String,
    pub cloud_favorite: bool,
    pub dirty: u8,
    pub asset_date_ms: Option<i64>,
    pub is_hidden: bool,
    pub is_trashed: bool,
    pub content_stale: bool,
    pub thumbnail_path: Option<String>,
    pub thumbnail_sha256: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct RemoteMediaInput {
    pub source_id: String,
    pub photo_id: String,
    pub master_id: String,
    pub content_generation: String,
    pub relative_path: String,
    pub display_name: String,
    pub parent_uri: String,
    pub path: String,
    pub size_bytes: u64,
    pub modified_ns: i64,
    pub mime_type: String,
    pub media_kind: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub orientation: u8,
    pub capture_time_ms: Option<i64>,
    pub sort_time_ms: i64,
    pub remote_favorite: bool,
    pub media_state: String,
    pub error_code: Option<String>,
    pub is_trashed: bool,
    pub asset_date_ms: Option<i64>,
    pub thumbnail_path: Option<String>,
    pub thumbnail_sha256: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct CloudBindingMedia {
    pub media_id: String,
    pub path: String,
    pub state: String,
    pub error_code: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct CloudBindingUpdate {
    pub photo_id: String,
    pub is_hidden: bool,
    pub is_trashed: bool,
    pub content_stale: bool,
    pub media_state: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct CloudUploadIntent {
    pub media_id: String,
    pub content_generation: String,
    pub photo_id: String,
    pub master_id: String,
    pub relative_path: String,
    pub operation_id: String,
    pub content_version: u64,
    pub size_bytes: u64,
    pub modified_ns: i64,
}

#[derive(Debug, Clone)]
pub(crate) struct CloudUpload {
    pub media_id: String,
    pub content_generation: String,
    pub photo_id: String,
    pub master_id: String,
    pub relative_path: String,
    pub operation_id: String,
    pub content_version: u64,
    pub size_bytes: u64,
    pub modified_ns: i64,
    pub state: String,
    pub attempt: u32,
    pub error_code: Option<String>,
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct CloudQueueCounts {
    pub queued: u32,
    pub skipped: u32,
    pub rejected: u32,
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct CloudCounts {
    pub pending_uploads: u32,
    pub pending_favorites: u32,
    pub bound: u32,
}

fn account_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CloudAccount> {
    Ok(CloudAccount {
        account_id: row.get(0)?,
        endpoint: row.get(1)?,
        username: row.get(2)?,
        user_id: row.get(3)?,
        token_file: row.get(4)?,
        token_expires_at_ms: row.get(5)?,
        device_id: row.get(6)?,
        created_at_ms: row.get(7)?,
        last_sync_ms: row.get(8)?,
    })
}

fn binding_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CloudBinding> {
    Ok(CloudBinding {
        account_id: row.get(0)?,
        photo_id: row.get(1)?,
        master_id: row.get(2)?,
        content_generation: row.get(3)?,
        library_id: row.get(4)?,
        media_id: row.get(5)?,
        relative_path: row.get(6)?,
        cloud_favorite: row.get(7)?,
        dirty: row.get(8)?,
        asset_date_ms: row.get(9)?,
        is_hidden: row.get(10)?,
        is_trashed: row.get(11)?,
        content_stale: row.get(12)?,
        thumbnail_path: row.get(13)?,
        thumbnail_sha256: row.get(14)?,
    })
}

const BINDING_COLUMNS: &str = "account_id,photo_id,master_id,content_generation,library_id,media_id,relative_path,cloud_favorite,COALESCE((SELECT dirty FROM media_sync_state s WHERE s.library_id=cloud_bindings.library_id AND s.media_id=cloud_bindings.media_id),0),asset_date_ms,is_hidden,is_trashed,content_stale,thumbnail_path,thumbnail_sha256";

/// Whether a media row belongs to any cloud account. File-mutating catalog
/// operations call this inside their transaction before touching the file.
pub(super) fn is_bound(c: &Connection, library: &str, media_id: &str) -> Result<bool, String> {
    c.query_row(
        "SELECT EXISTS(SELECT 1 FROM cloud_bindings WHERE library_id=?1 AND media_id=?2)",
        params![library, media_id],
        |r| r.get(0),
    )
    .map_err(error)
}

impl LocalLibrary {
    pub(crate) fn cloud_account(&self) -> Result<Option<CloudAccount>, String> {
        self.execute(|c| {
            c.query_row(
                "SELECT account_id,endpoint,username,user_id,token_file,token_expires_at_ms,device_id,created_at_ms,last_sync_ms FROM cloud_accounts ORDER BY created_at_ms LIMIT 1",
                [],
                account_row,
            )
            .optional()
            .map_err(error)
        })
    }

    pub(crate) fn cloud_upsert_account(&self, account: CloudAccount) -> Result<(), String> {
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            tx.execute(
                "INSERT INTO cloud_accounts(account_id,endpoint,username,user_id,token_file,token_expires_at_ms,device_id,created_at_ms,last_sync_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(account_id) DO UPDATE SET endpoint=excluded.endpoint,username=excluded.username,user_id=excluded.user_id,token_file=excluded.token_file,token_expires_at_ms=excluded.token_expires_at_ms,device_id=excluded.device_id,last_sync_ms=excluded.last_sync_ms",
                params![
                    account.account_id,
                    account.endpoint,
                    account.username,
                    account.user_id,
                    account.token_file,
                    account.token_expires_at_ms,
                    account.device_id,
                    account.created_at_ms,
                    account.last_sync_ms,
                ],
            )
            .map_err(error)?;
            tx.execute(
                "INSERT INTO cloud_sync_state(account_id,status,updated_at_ms) VALUES(?1,'logged_out',?2) ON CONFLICT(account_id) DO NOTHING",
                params![account.account_id, now_ms()],
            )
            .map_err(error)?;
            tx.commit().map_err(error)
        })
    }

    pub(crate) fn cloud_sync_state(
        &self,
        account_id: String,
    ) -> Result<Option<CloudSyncState>, String> {
        self.execute(move |c| {
            c.query_row(
                "SELECT zone_name,sync_token,snapshot_token,status,error_code,last_sync_ms FROM cloud_sync_state WHERE account_id=?1",
                [&account_id],
                |r| {
                    Ok(CloudSyncState {
                        zone_name: r.get(0)?,
                        sync_token: r.get(1)?,
                        snapshot_token: r.get(2)?,
                        status: r.get(3)?,
                        error_code: r.get(4)?,
                        last_sync_ms: r.get(5)?,
                    })
                },
            )
            .optional()
            .map_err(error)
        })
    }

    pub(crate) fn cloud_set_status(
        &self,
        account_id: String,
        status: String,
        error_code: Option<String>,
    ) -> Result<(), String> {
        self.execute(move |c| {
            c.execute(
                "INSERT INTO cloud_sync_state(account_id,status,error_code,updated_at_ms) VALUES(?1,?2,?3,?4) ON CONFLICT(account_id) DO UPDATE SET status=excluded.status,error_code=excluded.error_code,updated_at_ms=excluded.updated_at_ms",
                params![account_id, status, error_code, now_ms()],
            )
            .map_err(error)?;
            Ok(())
        })
    }

    pub(crate) fn cloud_mark_logged_out(&self, account_id: String) -> Result<(), String> {
        self.cloud_set_status(account_id, "logged_out".into(), None)
    }

    /// Persist a completed downlink: records, token and idle status become
    /// visible together only after every referenced file has settled.
    pub(crate) fn cloud_commit_download(
        &self,
        account_id: String,
        zone_name: String,
        snapshot_token: Option<String>,
        sync_token: String,
    ) -> Result<(), String> {
        self.execute(move |c| {
            let now = now_ms();
            c.execute(
                "UPDATE cloud_sync_state SET zone_name=?2,snapshot_token=?3,sync_token=?4,status='idle',error_code=NULL,last_sync_ms=?5,updated_at_ms=?5 WHERE account_id=?1",
                params![account_id, zone_name, snapshot_token, sync_token, now],
            )
            .map_err(error)?;
            c.execute(
                "UPDATE cloud_accounts SET last_sync_ms=?2 WHERE account_id=?1",
                params![account_id, now],
            )
            .map_err(error)?;
            Ok(())
        })
    }

    pub(crate) fn cloud_clear_records_and_token(
        &self,
        account_id: String,
    ) -> Result<(), String> {
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            tx.execute("DELETE FROM cloud_records WHERE account_id=?1", [&account_id])
                .map_err(error)?;
            tx.execute(
                "UPDATE cloud_sync_state SET sync_token=NULL,snapshot_token=NULL,updated_at_ms=?2 WHERE account_id=?1",
                params![account_id, now_ms()],
            )
            .map_err(error)?;
            tx.commit().map_err(error)
        })
    }

    pub(crate) fn cloud_replace_records(
        &self,
        account_id: String,
        records: Vec<StoredCloudRecord>,
    ) -> Result<(), String> {
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            tx.execute("DELETE FROM cloud_records WHERE account_id=?1", [&account_id])
                .map_err(error)?;
            insert_records(&tx, &account_id, records)?;
            tx.commit().map_err(error)
        })
    }

    pub(crate) fn cloud_apply_record_changes(
        &self,
        account_id: String,
        records: Vec<StoredCloudRecord>,
    ) -> Result<(), String> {
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            insert_records(&tx, &account_id, records)?;
            tx.commit().map_err(error)
        })
    }

    pub(crate) fn cloud_records(
        &self,
        account_id: String,
    ) -> Result<Vec<StoredCloudRecord>, String> {
        self.execute(move |c| {
            let mut statement = c
                .prepare("SELECT record_name,record_type,record_change_tag,deleted,record_json FROM cloud_records WHERE account_id=?1 ORDER BY record_name")
                .map_err(error)?;
            statement
                .query_map([&account_id], |r| {
                    Ok(StoredCloudRecord {
                        record_name: r.get(0)?,
                        record_type: r.get(1)?,
                        record_change_tag: r.get(2)?,
                        deleted: r.get(3)?,
                        record_json: r.get(4)?,
                    })
                })
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    pub(crate) fn cloud_bindings(
        &self,
        account_id: String,
    ) -> Result<Vec<CloudBinding>, String> {
        self.execute(move |c| {
            let mut statement = c
                .prepare(&format!(
                    "SELECT {BINDING_COLUMNS} FROM cloud_bindings WHERE account_id=?1 ORDER BY photo_id"
                ))
                .map_err(error)?;
            statement
                .query_map([&account_id], binding_row)
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    pub(crate) fn cloud_binding_media(
        &self,
        account_id: String,
    ) -> Result<Vec<CloudBindingMedia>, String> {
        self.execute(move |c| {
            let mut statement = c
                .prepare("SELECT b.media_id,m.source_uri,m.state,m.error_code FROM cloud_bindings b JOIN media m ON m.library_id=b.library_id AND m.media_id=b.media_id WHERE b.account_id=?1")
                .map_err(error)?;
            statement
                .query_map([&account_id], |r| {
                    Ok(CloudBindingMedia {
                        media_id: r.get(0)?,
                        path: r.get(1)?,
                        state: r.get(2)?,
                        error_code: r.get(3)?,
                    })
                })
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    pub(crate) fn cloud_bound_media_ids(&self) -> Result<Vec<String>, String> {
        self.execute(|c| {
            let mut statement = c
                .prepare("SELECT DISTINCT media_id FROM cloud_bindings")
                .map_err(error)?;
            statement
                .query_map([], |r| r.get(0))
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    pub(crate) fn cloud_media_read_only(&self, media_id: String) -> Result<bool, String> {
        let library = self.library_id.clone();
        self.execute(move |c| is_bound(c, &library, &media_id))
    }

    pub fn cloud_thumbnail_for_media(
        &self,
        media_id: String,
    ) -> Result<Option<(String, Option<String>)>, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            c.query_row(
                "SELECT thumbnail_path,thumbnail_sha256 FROM cloud_bindings WHERE library_id=?1 AND media_id=?2 AND thumbnail_path IS NOT NULL LIMIT 1",
                params![library, media_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(error)
        })
    }

    pub(crate) fn cloud_publish_remote_media(
        &self,
        account_id: String,
        input: RemoteMediaInput,
    ) -> Result<String, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let now = now_ms();
            let tx = c.transaction().map_err(error)?;
            let bound: Option<String> = tx
                .query_row(
                    "SELECT media_id FROM cloud_bindings WHERE account_id=?1 AND photo_id=?2",
                    params![account_id, input.photo_id],
                    |r| r.get(0),
                )
                .optional()
                .map_err(error)?;
            let state = input.media_state.as_str();
            if !matches!(state, "active" | "missing" | "unsupported") {
                return Err("InvalidMediaState".into());
            }
            let size = i64::try_from(input.size_bytes).map_err(|_| "FileTooLarge")?;
            let media_id = if let Some(media_id) = bound {
                tx.execute(
                    "UPDATE media SET source_id=?3,source_uri=?4,display_name=?5,parent_uri=?6,size_bytes=?7,modified_ns=?8,content_version=content_version+CASE WHEN source_uri<>?4 OR size_bytes<>?7 OR modified_ns<>?8 THEN 1 ELSE 0 END,media_kind=?9,mime_type=?10,width=?11,height=?12,orientation=?13,capture_time_ms=?14,sort_time_ms=?15,state=?16,error_code=?17,original_uri=NULL,trashed_at_ms=NULL WHERE library_id=?1 AND media_id=?2",
                    params![
                        library,
                        media_id,
                        input.source_id,
                        input.path,
                        input.display_name,
                        input.parent_uri,
                        size,
                        input.modified_ns,
                        input.media_kind,
                        input.mime_type,
                        input.width,
                        input.height,
                        input.orientation,
                        input.capture_time_ms,
                        input.sort_time_ms,
                        state,
                        input.error_code,
                    ],
                )
                .map_err(error)?;
                media_id
            } else {
                let existing: Option<String> = tx
                    .query_row(
                        "SELECT media_id FROM media WHERE library_id=?1 AND source_uri=?2",
                        params![library, input.path],
                        |r| r.get(0),
                    )
                    .optional()
                    .map_err(error)?;
                let media_id = existing.unwrap_or_else(|| Uuid::new_v4().to_string());
                tx.execute(
                    "INSERT INTO media(library_id,media_id,source_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,content_version,media_kind,mime_type,width,height,orientation,capture_time_ms,sort_time_ms,favorite,state,error_code) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,1,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18) ON CONFLICT(library_id,source_uri) DO UPDATE SET source_id=excluded.source_id,display_name=excluded.display_name,parent_uri=excluded.parent_uri,size_bytes=excluded.size_bytes,modified_ns=excluded.modified_ns,content_version=media.content_version+CASE WHEN media.size_bytes<>excluded.size_bytes OR media.modified_ns<>excluded.modified_ns THEN 1 ELSE 0 END,media_kind=excluded.media_kind,mime_type=excluded.mime_type,width=excluded.width,height=excluded.height,orientation=excluded.orientation,capture_time_ms=excluded.capture_time_ms,sort_time_ms=excluded.sort_time_ms,state=excluded.state,error_code=excluded.error_code,original_uri=NULL,trashed_at_ms=NULL",
                    params![
                        library,
                        media_id,
                        input.source_id,
                        input.path,
                        input.display_name,
                        input.parent_uri,
                        size,
                        input.modified_ns,
                        input.media_kind,
                        input.mime_type,
                        input.width,
                        input.height,
                        input.orientation,
                        input.capture_time_ms,
                        input.sort_time_ms,
                        input.remote_favorite,
                        state,
                        input.error_code,
                    ],
                )
                .map_err(error)?;
                media_id
            };
            tx.execute(
                "INSERT INTO cloud_bindings(account_id,photo_id,master_id,content_generation,library_id,media_id,relative_path,cloud_favorite,asset_date_ms,is_hidden,is_trashed,content_stale,thumbnail_path,thumbnail_sha256,created_at_ms,updated_at_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,0,?10,0,?11,?12,?13,?13) ON CONFLICT(account_id,photo_id) DO UPDATE SET master_id=excluded.master_id,content_generation=excluded.content_generation,library_id=excluded.library_id,media_id=excluded.media_id,relative_path=excluded.relative_path,asset_date_ms=excluded.asset_date_ms,is_hidden=excluded.is_hidden,is_trashed=excluded.is_trashed,content_stale=0,thumbnail_path=excluded.thumbnail_path,thumbnail_sha256=excluded.thumbnail_sha256,updated_at_ms=excluded.updated_at_ms",
                params![
                    account_id,
                    input.photo_id,
                    input.master_id,
                    input.content_generation,
                    library,
                    media_id,
                    input.relative_path,
                    input.remote_favorite,
                    input.asset_date_ms,
                    input.is_trashed,
                    input.thumbnail_path,
                    input.thumbnail_sha256,
                    now,
                ],
            )
            .map_err(error)?;
            super::tools::recount(&tx, &library)?;
            tx.commit().map_err(error)?;
            Ok(media_id)
        })
    }

    /// Refresh the whole graph's paths before admitting new bindings. Park all
    /// changed paths first so swaps and reuse of a deleted photo's path cannot
    /// violate the immediate UNIQUE constraint. Parked paths start with `/`,
    /// which the remote safe-relative-path contract forbids; they stay local.
    /// An orphan retains its binding and media under its reserved local path.
    pub(crate) fn cloud_refresh_binding_paths(
        &self,
        account_id: String,
        remote_paths: Vec<(String, String)>,
    ) -> Result<(), String> {
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            let remote: std::collections::HashMap<_, _> = remote_paths.into_iter().collect();
            let bindings = {
                let mut statement = tx.prepare(
                    "SELECT photo_id,relative_path FROM cloud_bindings WHERE account_id=?1",
                ).map_err(error)?;
                statement.query_map([&account_id], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                }).map_err(error)?.collect::<rusqlite::Result<Vec<_>>>().map_err(error)?
            };
            let changes: Vec<_> = bindings.into_iter().filter_map(|(photo_id, current)| {
                let parked = format!("/.cloud-binding/{photo_id}");
                let target = remote.get(&photo_id).cloned().unwrap_or_else(|| parked.clone());
                (target != current).then_some((photo_id, parked, target))
            }).collect();
            let now = now_ms();
            for (photo_id, parked, _) in &changes {
                tx.execute(
                    "UPDATE cloud_bindings SET relative_path=?3,updated_at_ms=?4 WHERE account_id=?1 AND photo_id=?2",
                    params![account_id, photo_id, parked, now],
                ).map_err(error)?;
            }
            for (photo_id, _, target) in changes {
                tx.execute(
                    "UPDATE cloud_bindings SET relative_path=?3 WHERE account_id=?1 AND photo_id=?2",
                    params![account_id, photo_id, target],
                ).map_err(error)?;
            }
            tx.commit().map_err(error)
        })
    }

    pub(crate) fn cloud_apply_binding_updates(
        &self,
        account_id: String,
        updates: Vec<CloudBindingUpdate>,
    ) -> Result<(), String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let now = now_ms();
            let tx = c.transaction().map_err(error)?;
            let mut state_changed = false;
            for update in updates {
                if let Some(state) = update.media_state.as_deref()
                    && !matches!(state, "active" | "missing" | "unsupported")
                {
                    return Err("InvalidMediaState".into());
                }
                let media_id: Option<String> = tx
                    .query_row(
                        "SELECT media_id FROM cloud_bindings WHERE account_id=?1 AND photo_id=?2",
                        params![account_id, update.photo_id],
                        |r| r.get(0),
                    )
                    .optional()
                    .map_err(error)?;
                let Some(media_id) = media_id else {
                    continue;
                };
                tx.execute(
                    "UPDATE cloud_bindings SET is_hidden=?3,is_trashed=?4,content_stale=?5,updated_at_ms=?6 WHERE account_id=?1 AND photo_id=?2",
                    params![
                        account_id,
                        update.photo_id,
                        update.is_hidden,
                        update.is_trashed,
                        update.content_stale,
                        now,
                    ],
                )
                .map_err(error)?;
                if let Some(state) = update.media_state {
                    state_changed |= tx
                        .execute(
                            "UPDATE media SET state=?3 WHERE library_id=?1 AND media_id=?2 AND state<>?3",
                            params![library, media_id, state],
                        )
                        .map_err(error)?
                        > 0;
                }
            }
            if state_changed {
                super::tools::recount(&tx, &library)?;
            }
            tx.commit().map_err(error)
        })
    }

    /// Photos that disappeared from the remote graph keep their files and
    /// bindings; only visibility changes so the local grid stops showing them.
    pub(crate) fn cloud_deactivate_orphan_bindings(
        &self,
        account_id: String,
        active_photo_ids: Vec<String>,
    ) -> Result<u32, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            let mut deactivated = 0;
            let mut statement = tx
                .prepare("SELECT photo_id,media_id FROM cloud_bindings WHERE account_id=?1")
                .map_err(error)?;
            let bindings: Vec<(String, String)> = statement
                .query_map([&account_id], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)?;
            drop(statement);
            let active: std::collections::HashSet<&String> = active_photo_ids.iter().collect();
            for (photo_id, media_id) in &bindings {
                if active.contains(photo_id) {
                    continue;
                }
                deactivated += tx
                    .execute(
                        "UPDATE media SET state='missing' WHERE library_id=?1 AND media_id=?2 AND state='active'",
                        params![library, media_id],
                    )
                    .map_err(error)? as u32;
            }
            if deactivated > 0 {
                super::tools::recount(&tx, &library)?;
            }
            tx.commit().map_err(error)?;
            Ok(deactivated)
        })
    }

    pub(crate) fn cloud_queue_uploads(
        &self,
        account_id: String,
        intents: Vec<CloudUploadIntent>,
    ) -> Result<CloudQueueCounts, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let now = now_ms();
            let tx = c.transaction().map_err(error)?;
            let mut counts = CloudQueueCounts::default();
            for intent in intents {
                let media: Option<(String, i64, i64, i64)> = tx
                    .query_row(
                        "SELECT state,content_version,size_bytes,modified_ns FROM media WHERE library_id=?1 AND media_id=?2",
                        params![library, intent.media_id],
                        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                    )
                    .optional()
                    .map_err(error)?;
                let Some((state, content_version, size, modified)) = media else {
                    counts.rejected += 1;
                    continue;
                };
                let version = i64::try_from(intent.content_version).map_err(|_| "VersionOutOfRange")?;
                let size_bytes = i64::try_from(intent.size_bytes).map_err(|_| "FileTooLarge")?;
                if state != "active"
                    || content_version != version
                    || size != size_bytes
                    || modified != intent.modified_ns
                {
                    counts.rejected += 1;
                    continue;
                }
                let bound: bool = tx
                    .query_row(
                        "SELECT EXISTS(SELECT 1 FROM cloud_bindings WHERE account_id=?1 AND media_id=?2)",
                        params![account_id, intent.media_id],
                        |r| r.get(0),
                    )
                    .map_err(error)?;
                let queued: bool = tx
                    .query_row(
                        "SELECT EXISTS(SELECT 1 FROM cloud_uploads WHERE account_id=?1 AND media_id=?2 AND state IN ('pending','publishing'))",
                        params![account_id, intent.media_id],
                        |r| r.get(0),
                    )
                    .map_err(error)?;
                if bound || queued {
                    counts.skipped += 1;
                    continue;
                }
                let inserted = tx
                    .execute(
                        "INSERT OR IGNORE INTO cloud_uploads(account_id,library_id,media_id,content_generation,photo_id,master_id,relative_path,operation_id,content_version,size_bytes,modified_ns,state,attempt,created_at_ms,updated_at_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,'pending',0,?12,?12)",
                        params![
                            account_id,
                            library,
                            intent.media_id,
                            intent.content_generation,
                            intent.photo_id,
                            intent.master_id,
                            intent.relative_path,
                            intent.operation_id,
                            version,
                            size_bytes,
                            intent.modified_ns,
                            now,
                        ],
                    )
                    .map_err(error)?;
                if inserted > 0 {
                    tx.execute("INSERT INTO media_sync_state(library_id,media_id,dirty) VALUES(?1,?2,1) ON CONFLICT(library_id,media_id) DO UPDATE SET dirty=1", params![library, intent.media_id]).map_err(error)?;
                    counts.queued += 1;
                } else {
                    counts.skipped += 1;
                }
            }
            tx.commit().map_err(error)?;
            Ok(counts)
        })
    }

    pub(crate) fn cloud_pending_uploads(
        &self,
        account_id: String,
    ) -> Result<Vec<CloudUpload>, String> {
        self.execute(move |c| {
            let mut statement = c
                .prepare("SELECT media_id,content_generation,photo_id,master_id,relative_path,operation_id,content_version,size_bytes,modified_ns,state,attempt,error_code FROM cloud_uploads WHERE account_id=?1 AND state IN ('pending','publishing') ORDER BY created_at_ms")
                .map_err(error)?;
            statement
                .query_map([&account_id], |r| {
                    Ok(CloudUpload {
                        media_id: r.get(0)?,
                        content_generation: r.get(1)?,
                        photo_id: r.get(2)?,
                        master_id: r.get(3)?,
                        relative_path: r.get(4)?,
                        operation_id: r.get(5)?,
                        content_version: sql_u64(r, 6)?,
                        size_bytes: sql_u64(r, 7)?,
                        modified_ns: r.get(8)?,
                        state: r.get(9)?,
                        attempt: r.get(10)?,
                        error_code: r.get(11)?,
                    })
                })
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    pub(crate) fn cloud_mark_upload_publishing(
        &self,
        account_id: String,
        media_id: String,
        content_generation: String,
    ) -> Result<(), String> {
        self.execute(move |c| {
            c.execute(
                "UPDATE cloud_uploads SET state='publishing',attempt=attempt+1,error_code=NULL,updated_at_ms=?4 WHERE account_id=?1 AND media_id=?2 AND content_generation=?3",
                params![account_id, media_id, content_generation, now_ms()],
            )
            .map_err(error)?;
            Ok(())
        })
    }

    pub(crate) fn cloud_set_upload_state(
        &self,
        account_id: String,
        media_id: String,
        content_generation: String,
        state: String,
        error_code: Option<String>,
    ) -> Result<(), String> {
        self.execute(move |c| {
            c.execute(
                "UPDATE cloud_uploads SET state=?4,error_code=?5,updated_at_ms=?6 WHERE account_id=?1 AND media_id=?2 AND content_generation=?3",
                params![account_id, media_id, content_generation, state, error_code, now_ms()],
            )
            .map_err(error)?;
            Ok(())
        })
    }

    pub(crate) fn cloud_publish_upload_binding(
        &self,
        account_id: String,
        media_id: String,
        content_generation: String,
        photo_id: String,
        master_id: String,
        relative_path: String,
        cloud_favorite: bool,
        asset_date_ms: Option<i64>,
    ) -> Result<(), String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let now = now_ms();
            let tx = c.transaction().map_err(error)?;
            let local_favorite: bool = tx
                .query_row(
                    "SELECT favorite FROM media WHERE library_id=?1 AND media_id=?2",
                    params![library, media_id],
                    |r| r.get(0),
                )
                .map_err(error)?;
            tx.execute(
                "INSERT INTO cloud_bindings(account_id,photo_id,master_id,content_generation,library_id,media_id,relative_path,cloud_favorite,asset_date_ms,is_hidden,is_trashed,content_stale,thumbnail_path,thumbnail_sha256,created_at_ms,updated_at_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,0,0,0,NULL,NULL,?10,?10) ON CONFLICT(account_id,photo_id) DO UPDATE SET master_id=excluded.master_id,content_generation=excluded.content_generation,library_id=excluded.library_id,media_id=excluded.media_id,relative_path=excluded.relative_path,asset_date_ms=excluded.asset_date_ms,updated_at_ms=excluded.updated_at_ms",
                params![
                    account_id,
                    photo_id,
                    master_id,
                    content_generation,
                    library,
                    media_id,
                    relative_path,
                    cloud_favorite,
                    asset_date_ms,
                    now,
                ],
            )
            .map_err(error)?;
            metadata::settle_create(&tx, &library, &media_id, local_favorite != cloud_favorite)?;
            tx.execute(
                "UPDATE cloud_uploads SET state='published',error_code=NULL,updated_at_ms=?4 WHERE account_id=?1 AND media_id=?2 AND content_generation=?3",
                params![account_id, media_id, content_generation, now],
            )
            .map_err(error)?;
            tx.commit().map_err(error)
        })
    }

    pub(crate) fn cloud_counts(&self, account_id: String) -> Result<CloudCounts, String> {
        self.execute(move |c| {
            let bound = c
                .query_row(
                    "SELECT COUNT(*) FROM cloud_bindings WHERE account_id=?1",
                    [&account_id],
                    |r| r.get::<_, i64>(0),
                )
                .map_err(error)?;
            let pending_uploads = c
                .query_row(
                    "SELECT COUNT(*) FROM cloud_uploads WHERE account_id=?1 AND state IN ('pending','publishing')",
                    [&account_id],
                    |r| r.get::<_, i64>(0),
                )
                .map_err(error)?;
            let pending_favorites = c
                .query_row(
                    "SELECT COUNT(*) FROM cloud_bindings b JOIN media_sync_state s ON s.library_id=b.library_id AND s.media_id=b.media_id WHERE b.account_id=?1 AND s.dirty=2",
                    [&account_id],
                    |r| r.get::<_, i64>(0),
                )
                .map_err(error)?;
            Ok(CloudCounts {
                pending_uploads: pending_uploads.max(0) as u32,
                pending_favorites: pending_favorites.max(0) as u32,
                bound: bound.max(0) as u32,
            })
        })
    }

    pub(crate) fn ensure_managed_cloud_source(
        &self,
        account_id: &str,
    ) -> Result<String, String> {
        if account_id.is_empty()
            || !account_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err("InvalidAccount".into());
        }
        let directory = self.root.join("cloud").join(account_id);
        fs::create_dir_all(&directory).map_err(error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
                .map_err(error)?;
        }
        let directory = directory.canonicalize().map_err(error)?;
        let path = directory
            .to_str()
            .ok_or("UnsupportedPathEncoding")?
            .to_owned();
        let library = self.library_id.clone();
        self.execute(move |c| {
            c.execute(
                "INSERT INTO sources(library_id,source_id,root_uri,source_kind,recursive) VALUES(?1,?2,?3,'managed',0) ON CONFLICT(library_id,root_uri) DO UPDATE SET source_kind='managed',recursive=0,enabled=1,availability='available'",
                params![library, Uuid::new_v4().to_string(), path],
            )
            .map_err(error)?;
            c.query_row(
                "SELECT source_id FROM sources WHERE library_id=?1 AND root_uri=?2",
                params![library, path],
                |r| r.get(0),
            )
            .map_err(error)
        })
    }
}

fn insert_records(
    connection: &Connection,
    account_id: &str,
    records: Vec<StoredCloudRecord>,
) -> Result<(), String> {
    let now = now_ms();
    let mut statement = connection
        .prepare(
            "INSERT INTO cloud_records(account_id,record_name,record_type,record_change_tag,deleted,record_json,updated_at_ms) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(account_id,record_name) DO UPDATE SET record_type=excluded.record_type,record_change_tag=excluded.record_change_tag,deleted=excluded.deleted,record_json=excluded.record_json,updated_at_ms=excluded.updated_at_ms",
        )
        .map_err(error)?;
    for record in records {
        statement
            .execute(params![
                account_id,
                record.record_name,
                record.record_type,
                record.record_change_tag,
                record.deleted,
                record.record_json,
                now,
            ])
            .map_err(error)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ACCOUNT: &str = "acct-1";

    fn open_library() -> (tempfile::TempDir, LocalLibrary) {
        let root = tempfile::TempDir::new().unwrap();
        let library = LocalLibrary::open(root.path()).unwrap();
        library
            .cloud_upsert_account(CloudAccount {
                account_id: ACCOUNT.into(),
                endpoint: "http://127.0.0.1:8790".into(),
                username: "alice".into(),
                user_id: Some("user-1".into()),
                token_file: format!("cloud/{ACCOUNT}/session.token"),
                token_expires_at_ms: None,
                device_id: "device-1".into(),
                created_at_ms: 1,
                last_sync_ms: None,
            })
            .unwrap();
        (root, library)
    }

    fn seed_photo(library: &LocalLibrary, folder: &Path, name: &str) -> (String, String) {
        let path = folder.join(name);
        fs::write(&path, b"cloud fixture").unwrap();
        let modified_ns = fs::metadata(&path)
            .unwrap()
            .modified()
            .unwrap()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as i64;
        let source_id = library.add_source(folder).unwrap();
        library
            .upsert_batch(
                source_id.clone(),
                vec![MediaInput {
                    path: path.to_str().unwrap().into(),
                    name: name.into(),
                    parent: folder.to_str().unwrap().into(),
                    size_bytes: 14,
                    modified_ns,
                    mime_type: "image/jpeg".into(),
                    width: Some(4),
                    height: Some(2),
                    orientation: 1,
                    capture_time_ms: Some(1_700_000_000_000),
                }],
            )
            .unwrap();
        let media_id = library
            .query(PhotoFilter::default(), None, 10)
            .unwrap()
            .items[0]
            .id
            .clone();
        (source_id, media_id)
    }

    fn remote_input(
        source_id: &str,
        photo_id: &str,
        relative_path: &str,
        path: &Path,
        favorite: bool,
    ) -> RemoteMediaInput {
        RemoteMediaInput {
            source_id: source_id.into(),
            photo_id: photo_id.into(),
            master_id: format!("{photo_id}-master"),
            content_generation: Uuid::new_v4().to_string(),
            relative_path: relative_path.into(),
            display_name: path.file_name().unwrap().to_string_lossy().into(),
            parent_uri: path.parent().unwrap().to_string_lossy().into(),
            path: path.to_str().unwrap().into(),
            size_bytes: 14,
            modified_ns: 1_700_000_000_000,
            mime_type: "image/jpeg".into(),
            media_kind: "image".into(),
            width: Some(4),
            height: Some(2),
            orientation: 1,
            capture_time_ms: Some(1_700_000_000_000),
            sort_time_ms: 1_700_000_000_000,
            remote_favorite: favorite,
            media_state: "active".into(),
            error_code: None,
            is_trashed: false,
            asset_date_ms: Some(1_700_000_000_000),
            thumbnail_path: None,
            thumbnail_sha256: None,
        }
    }

    fn record(name: &str, deleted: bool, json: Option<&str>) -> StoredCloudRecord {
        StoredCloudRecord {
            record_name: name.into(),
            record_type: Some("CPLMaster".into()),
            record_change_tag: Some("tag".into()),
            deleted,
            record_json: json.map(str::to_owned),
        }
    }

    #[test]
    fn record_changes_upsert_and_tombstone() {
        let (_root, library) = open_library();
        library
            .cloud_apply_record_changes(
                ACCOUNT.into(),
                vec![record("A", false, Some("{\"v\":1}")), record("B", false, Some("{\"v\":2}"))],
            )
            .unwrap();
        library
            .cloud_apply_record_changes(
                ACCOUNT.into(),
                vec![record("A", true, None), record("B", false, Some("{\"v\":3}"))],
            )
            .unwrap();
        let records = library.cloud_records(ACCOUNT.into()).unwrap();
        assert_eq!(records.len(), 2);
        assert!(records[0].record_name == "A" && records[0].deleted);
        assert_eq!(records[0].record_json, None);
        assert_eq!(records[1].record_json.as_deref(), Some("{\"v\":3}"));
    }

    #[test]
    fn paginated_changes_accumulate_before_rebuild() {
        let (_root, library) = open_library();
        library
            .cloud_apply_record_changes(ACCOUNT.into(), vec![record("m1", false, Some("{}"))])
            .unwrap();
        library
            .cloud_apply_record_changes(ACCOUNT.into(), vec![record("a1", false, Some("{}"))])
            .unwrap();
        let records = library.cloud_records(ACCOUNT.into()).unwrap();
        let names: Vec<_> = records.iter().map(|r| r.record_name.as_str()).collect();
        assert_eq!(names, ["a1", "m1"]);
    }

    #[test]
    fn binding_is_unique_per_photo_and_relative_path() {
        let (root, library) = open_library();
        let folder = root.path().join("photos");
        fs::create_dir_all(&folder).unwrap();
        let (source_id, media_id) = seed_photo(&library, &folder, "one.jpg");
        let other = folder.join("two.jpg");
        fs::write(&other, b"cloud fixture").unwrap();
        let path = PathBuf::from(&library.photo(media_id.clone()).unwrap().path);

        library
            .cloud_publish_remote_media(
                ACCOUNT.into(),
                remote_input(&source_id, "photo-1", "a.jpg", &path, false),
            )
            .unwrap();
        let duplicate = library.cloud_publish_remote_media(
            ACCOUNT.into(),
            remote_input(&source_id, "photo-2", "a.jpg", &other, false),
        );
        assert!(duplicate.is_err());
        assert_eq!(library.cloud_bindings(ACCOUNT.into()).unwrap().len(), 1);

        // Re-publishing the same remote photo moves the binding instead of
        // creating a second row.
        library
            .cloud_publish_remote_media(
                ACCOUNT.into(),
                remote_input(&source_id, "photo-1", "a.jpg", &path, false),
            )
            .unwrap();
        let bindings = library.cloud_bindings(ACCOUNT.into()).unwrap();
        assert_eq!(bindings.len(), 1);
        assert_eq!(bindings[0].media_id, media_id);
    }

    fn metadata_photo() -> syncserver_client::RemotePhoto {
        use syncserver_client as sdk;
        let record: sdk::RemoteRecord=serde_json::from_value(serde_json::json!({
            "recordName":"photo-1","recordType":"CPLAsset","recordChangeTag":"revision-1",
            "fields":{"relativePath":{"type":"STRING","value":"a.jpg"},"isFavorite":{"type":"INT64","value":0},"isHidden":{"type":"INT64","value":0}}
        })).unwrap();
        let asset:sdk::AssetDescriptor=serde_json::from_value(serde_json::json!({"assetId":Uuid::new_v4().to_string(),"size":14,"fileChecksum":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","mimeType":"image/jpeg"})).unwrap();
        sdk::RemotePhoto {
            photo_id: "photo-1".into(),
            master_id: "photo-1-master".into(),
            content_generation: Uuid::new_v4().to_string(),
            relative_path: "a.jpg".into(),
            is_favorite: false,
            asset_date_ms: None,
            is_hidden: false,
            original: asset.clone(),
            thumbnail: asset,
            thumbnail_source_sha256: "0".repeat(64),
            events: Default::default(),
            asset_revision: "revision-1".into(),
            master_revision: "master-revision".into(),
            asset: record.clone(),
            master: record,
        }
    }

    fn confirmed_metadata(operation: &metadata::IssuedMetadata) -> syncserver_client::RemoteRecord {
        let mutation = &operation.mutation;
        serde_json::from_value(serde_json::json!({
            "recordName":mutation.photo_id,"recordType":"CPLAsset","recordChangeTag":"confirmed-revision",
            "fields":{"relativePath":{"type":"STRING","value":mutation.metadata.relative_path},"isFavorite":{"type":"INT64","value":i64::from(mutation.metadata.is_favorite)},"isHidden":{"type":"INT64","value":0}},
            "_syncserver":{"metadataEvent":mutation.event}
        })).unwrap()
    }

    fn metadata_binding() -> (tempfile::TempDir, LocalLibrary, String) {
        let (root, library) = open_library();
        let folder = root.path().join("photos");
        fs::create_dir_all(&folder).unwrap();
        let (source, media) = seed_photo(&library, &folder, "one.jpg");
        let path = PathBuf::from(library.photo(media.clone()).unwrap().path);
        library
            .cloud_publish_remote_media(
                ACCOUNT.into(),
                remote_input(&source, "photo-1", "a.jpg", &path, false),
            )
            .unwrap();
        (root, library, media)
    }

    #[test]
    fn metadata_dirty_is_cleared_only_by_matching_event_confirmation() {
        let (_root, library, media) = metadata_binding();
        library.set_favorite(media.clone(), true).unwrap();
        let issued = library
            .cloud_issue_metadata(
                ACCOUNT.into(),
                metadata_photo(),
                syncserver_client::ZoneId::primary(),
            )
            .unwrap()
            .unwrap();
        assert!(
            !library
                .cloud_apply_remote_metadata(ACCOUNT.into(), "photo-1".into(), false, None)
                .unwrap()
        );
        assert!(library.photo(media.clone()).unwrap().favorite);
        let mut wrong = confirmed_metadata(&issued);
        wrong.events.metadata_event.as_mut().unwrap().event_id = "another-event".into();
        assert!(
            library
                .cloud_confirm_metadata(ACCOUNT.into(), issued.clone(), wrong)
                .is_err()
        );
        assert_eq!(library.cloud_bindings(ACCOUNT.into()).unwrap()[0].dirty, 2);
        assert!(
            !library
                .cloud_confirm_metadata(ACCOUNT.into(), issued.clone(), confirmed_metadata(&issued))
                .unwrap()
        );
        let remote = syncserver_client::EditEvent {
            edited_at_ms: issued.mutation.event.edited_at_ms + 1,
            source: "other-device".into(),
            event_id: "newer".into(),
        };
        assert!(
            library
                .cloud_apply_remote_metadata(ACCOUNT.into(), "photo-1".into(), false, Some(remote))
                .unwrap()
        );
        assert!(!library.photo(media).unwrap().favorite);
    }

    #[test]
    fn metadata_confirmation_keeps_a_newer_edit_even_when_value_returns_to_sent_value() {
        let (_root, library, media) = metadata_binding();
        library.set_favorite(media.clone(), true).unwrap();
        let issued = library
            .cloud_issue_metadata(
                ACCOUNT.into(),
                metadata_photo(),
                syncserver_client::ZoneId::primary(),
            )
            .unwrap()
            .unwrap();
        library.set_favorite(media.clone(), false).unwrap();
        library.set_favorite(media.clone(), true).unwrap();
        assert!(
            library
                .cloud_confirm_metadata(ACCOUNT.into(), issued.clone(), confirmed_metadata(&issued))
                .unwrap()
        );
        assert_eq!(library.cloud_bindings(ACCOUNT.into()).unwrap()[0].dirty, 2);
        let library_id = library.library_id.clone();
        let versions=library.execute(move|c|c.query_row("SELECT metadata_version,acked_metadata_version FROM media_sync_state WHERE library_id=?1 AND media_id=?2",params![library_id,media],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?))).map_err(error)).unwrap();
        assert_eq!(versions, (3, 1));
    }

    #[test]
    fn metadata_conflict_uses_event_order_and_preserves_pending_requests() {
        let (_root, library, media) = metadata_binding();
        library.set_favorite(media.clone(), true).unwrap();
        let issued = library
            .cloud_issue_metadata(
                ACCOUNT.into(),
                metadata_photo(),
                syncserver_client::ZoneId::primary(),
            )
            .unwrap()
            .unwrap();
        let newer = syncserver_client::EditEvent {
            edited_at_ms: issued.mutation.event.edited_at_ms + 1,
            source: "other-device".into(),
            event_id: "remote".into(),
        };
        assert!(
            !library
                .cloud_apply_remote_metadata(
                    ACCOUNT.into(),
                    "photo-1".into(),
                    false,
                    Some(newer.clone())
                )
                .unwrap()
        );
        library
            .cloud_forget_rejected_metadata(ACCOUNT.into(), issued.mutation.operation_id)
            .unwrap();
        assert!(
            library
                .cloud_apply_remote_metadata(ACCOUNT.into(), "photo-1".into(), false, Some(newer))
                .unwrap()
        );
        assert!(!library.photo(media).unwrap().favorite);
        assert_eq!(library.cloud_bindings(ACCOUNT.into()).unwrap()[0].dirty, 0);
    }

    #[test]
    fn metadata_event_order_matches_legacy_ties_and_unknown_fallback() {
        for (local_time, remote_time, remote_source, remote_id, keep_local) in [
            (Some(300), Some(200), "remote", "r", true),
            (Some(100), Some(200), "remote", "r", false),
            (Some(200), Some(200), "aaa", "r", true),
            (Some(200), Some(200), "zzz", "r", false),
            (Some(200), Some(200), "local", "zzz", false),
            (Some(200), None, "", "", true),
            (None, None, "", "", true),
            (None, Some(200), "remote", "r", false),
        ] {
            let (_root, library, media) = metadata_binding();
            library.set_favorite(media.clone(), true).unwrap();
            library
                .execute(move |c| {
                    c.execute(
                        "UPDATE media_sync_state SET edited_at_ms=?1,source=?2,event_id=?3",
                        params![
                            local_time,
                            local_time.map(|_| "local"),
                            local_time.map(|_| "local")
                        ],
                    )
                    .map_err(error)?;
                    Ok(())
                })
                .unwrap();
            let remote = remote_time.map(|edited_at_ms| syncserver_client::EditEvent {
                edited_at_ms,
                source: remote_source.into(),
                event_id: remote_id.into(),
            });
            library
                .cloud_apply_remote_metadata(ACCOUNT.into(), "photo-1".into(), false, remote)
                .unwrap();
            assert_eq!(library.photo(media).unwrap().favorite, keep_local);
            assert_eq!(
                library.cloud_bindings(ACCOUNT.into()).unwrap()[0].dirty,
                if keep_local { 2 } else { 0 }
            );
            if keep_local && local_time.is_none() {
                let issued=library.cloud_issue_metadata(ACCOUNT.into(),metadata_photo(),syncserver_client::ZoneId::primary()).unwrap().unwrap();
                assert_eq!(issued.mutation.event.edited_at_ms,0);
                assert!(!issued.mutation.event.source.is_empty());
                assert!(!issued.mutation.event.event_id.is_empty());
            }
        }
    }
    #[test]
    fn favorite_toggle_heals_a_drifted_counter() {
        let (root, library) = open_library();
        let folder = root.path().join("photos");
        fs::create_dir_all(&folder).unwrap();
        let (_source_id, media_id) = seed_photo(&library, &folder, "one.jpg");
        let library_id = library.library_id.clone();
        library
            .execute(move |c| {
                c.execute(
                    "UPDATE libraries SET favorite_count=(SELECT COUNT(*) FROM media WHERE library_id=?1 AND state='active') WHERE library_id=?1",
                    [&library_id],
                )
                .map_err(error)?;
                Ok(())
            })
            .unwrap();

        assert!(library.set_favorite(media_id.clone(), true).unwrap());
        assert!(library.photo(media_id.clone()).unwrap().favorite);
        assert_eq!(library_favorite_counts(&library), (1, 1));

        assert!(library.set_favorite(media_id, false).unwrap());
        assert_eq!(library_favorite_counts(&library), (1, 0));
    }

    fn library_favorite_counts(library: &LocalLibrary) -> (i64, i64) {
        let library_id = library.library_id.clone();
        library
            .execute(move |c| {
                c.query_row(
                    "SELECT media_count,favorite_count FROM libraries WHERE library_id=?1",
                    [&library_id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .map_err(error)
            })
            .unwrap()
    }

    #[test]
    fn managed_source_stays_out_of_normal_source_handling() {
        let (root, library) = open_library();
        let managed = library.ensure_managed_cloud_source(ACCOUNT).unwrap();
        let source = library
            .sources()
            .unwrap()
            .into_iter()
            .find(|s| s.id == managed)
            .unwrap();
        assert_eq!(source.kind, "managed");
        assert_eq!(library.remove_source(managed).unwrap_err(), "ManagedSource");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(root.path().join("cloud").join(ACCOUNT))
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o700);
        }
    }

    #[test]
    fn bound_media_rejects_file_mutations() {
        let (root, library) = open_library();
        let folder = root.path().join("photos");
        fs::create_dir_all(&folder).unwrap();
        let (source_id, media_id) = seed_photo(&library, &folder, "one.jpg");
        let path = PathBuf::from(&library.photo(media_id.clone()).unwrap().path);
        library
            .cloud_publish_remote_media(
                ACCOUNT.into(),
                remote_input(&source_id, "photo-1", "a.jpg", &path, false),
            )
            .unwrap();

        assert_eq!(
            library.trash_media(vec![media_id.clone()]).unwrap_err(),
            "CloudMediaReadOnly"
        );
        assert_eq!(
            library
                .rename_media(media_id.clone(), "renamed.jpg".into())
                .unwrap_err(),
            "CloudMediaReadOnly"
        );
        assert!(path.exists());
        assert_eq!(library.photo(media_id).unwrap().state, "active");
        assert_eq!(library.cloud_bound_media_ids().unwrap().len(), 1);
    }

    fn path_binding_fixture() -> (tempfile::TempDir, LocalLibrary, String, Vec<String>) {
        let (root, library) = open_library();
        let source = library.ensure_managed_cloud_source(ACCOUNT).unwrap();
        let mut media_ids = Vec::new();
        for name in ["one", "two"] {
            let path = root.path().join(format!("{name}.jpg"));
            fs::write(&path, b"cloud fixture").unwrap();
            media_ids.push(
                library
                    .cloud_publish_remote_media(
                        ACCOUNT.into(),
                        remote_input(&source, name, &format!("{name}.jpg"), &path, false),
                    )
                    .unwrap(),
            );
        }
        (root, library, source, media_ids)
    }

    #[test]
    fn binding_paths_swap_atomically_without_changing_media_identity() {
        let (_root, library, _source, media_ids) = path_binding_fixture();
        library
            .cloud_refresh_binding_paths(
                ACCOUNT.into(),
                vec![
                    ("one".into(), "two.jpg".into()),
                    ("two".into(), "one.jpg".into()),
                ],
            )
            .unwrap();
        let bindings = library.cloud_bindings(ACCOUNT.into()).unwrap();
        assert_eq!(bindings[0].relative_path, "two.jpg");
        assert_eq!(bindings[1].relative_path, "one.jpg");
        assert_eq!(bindings[0].media_id, media_ids[0]);
        assert_eq!(bindings[1].media_id, media_ids[1]);
        assert_eq!(
            library
                .query(PhotoFilter::default(), None, 10)
                .unwrap()
                .total,
            2
        );
    }

    #[test]
    fn orphan_binding_releases_its_path_and_can_later_return() {
        let (root, library, source, media_ids) = path_binding_fixture();
        library
            .cloud_refresh_binding_paths(
                ACCOUNT.into(),
                vec![
                    ("two".into(), "two.jpg".into()),
                    ("three".into(), "one.jpg".into()),
                ],
            )
            .unwrap();
        library
            .cloud_deactivate_orphan_bindings(ACCOUNT.into(), vec!["two".into(), "three".into()])
            .unwrap();
        let path = root.path().join("three.jpg");
        fs::write(&path, b"cloud fixture").unwrap();
        library
            .cloud_publish_remote_media(
                ACCOUNT.into(),
                remote_input(&source, "three", "one.jpg", &path, false),
            )
            .unwrap();
        let bindings = library.cloud_bindings(ACCOUNT.into()).unwrap();
        let orphan = bindings.iter().find(|b| b.photo_id == "one").unwrap();
        assert!(orphan.relative_path.starts_with('/'));
        assert_eq!(orphan.media_id, media_ids[0]);
        assert_eq!(library.cloud_bound_media_ids().unwrap().len(), 3);
        assert!(root.path().join("one.jpg").is_file());
        library
            .cloud_refresh_binding_paths(
                ACCOUNT.into(),
                vec![
                    ("one".into(), "restored.jpg".into()),
                    ("two".into(), "two.jpg".into()),
                    ("three".into(), "one.jpg".into()),
                ],
            )
            .unwrap();
        let restored = library
            .cloud_bindings(ACCOUNT.into())
            .unwrap()
            .into_iter()
            .find(|b| b.photo_id == "one")
            .unwrap();
        assert_eq!(restored.relative_path, "restored.jpg");
        assert_eq!(restored.media_id, media_ids[0]);
    }

    #[test]
    fn binding_path_conflict_rolls_back_the_entire_remap() {
        let (_root, library, _source, _ids) = path_binding_fixture();
        assert!(
            library
                .cloud_refresh_binding_paths(
                    ACCOUNT.into(),
                    vec![
                        ("one".into(), "same.jpg".into()),
                        ("two".into(), "same.jpg".into()),
                    ]
                )
                .is_err()
        );
        let bindings = library.cloud_bindings(ACCOUNT.into()).unwrap();
        assert_eq!(bindings[0].relative_path, "one.jpg");
        assert_eq!(bindings[1].relative_path, "two.jpg");
    }
    #[test]
    fn cloud_scope_pin_rejects_changed_namespace_or_database_generation() {
        let (_root,library)=open_library();
        let namespace=syncserver_client::Namespace {tenant:"user".into(),container:"photos".into(),environment:"production".into(),database:"private".into()};
        assert!(library.cloud_pin_scope(ACCOUNT.into(),namespace.clone(),"generation-1".into()).unwrap());
        assert!(library.cloud_pin_scope(ACCOUNT.into(),namespace.clone(),"generation-1".into()).unwrap());
        assert!(!library.cloud_pin_scope(ACCOUNT.into(),namespace.clone(),"generation-2".into()).unwrap());
        let mut other=namespace.clone();other.tenant="another-user".into();
        assert!(!library.cloud_pin_scope(ACCOUNT.into(),other,"generation-1".into()).unwrap());
        assert!(library.cloud_pin_scope(ACCOUNT.into(),namespace,"generation-1".into()).unwrap());
    }
}
