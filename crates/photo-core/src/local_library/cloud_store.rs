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
    pub upload_scope: String,
    pub is_active: bool,
    pub download_root: Option<String>,
}

/// A local photo that the active account's upload scope may still send.
#[derive(Debug, Clone)]
pub(crate) struct CloudScopeCandidate {
    pub media_id: String,
    pub path: String,
    pub name: String,
    pub mime_type: String,
    pub content_version: u64,
    pub size_bytes: u64,
    pub modified_ns: i64,
    pub sort_time_ms: i64,
    pub parent: String,
    pub root: String,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct CloudSyncState {
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

/// A cloud binding as the sync engine consumes it. Columns that only the
/// persistence layer needs (account, master, library, remote path, favorite
/// flag, zone, asset date, thumbnail cache) stay in the database and are read
/// through their own queries.
#[derive(Debug, Clone)]
pub(crate) struct CloudBinding {
    pub photo_id: String,
    pub content_generation: String,
    pub media_id: String,
    pub is_hidden: bool,
    pub is_trashed: bool,
    pub content_stale: bool,
    pub dirty: u8,
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

/// A queued upload as the uplink consumes it. The upload state machine
/// (state, attempt counter and last error code) stays in `cloud_uploads`.
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
    pub failed_uploads: u32,
    pub pending_favorites: u32,
    pub bound: u32,
}

const ACCOUNT_COLUMNS: &str = "account_id,endpoint,username,user_id,token_file,token_expires_at_ms,device_id,created_at_ms,last_sync_ms,upload_scope,is_active,download_root";

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
        upload_scope: row.get(9)?,
        is_active: row.get(10)?,
        download_root: row.get(11)?,
    })
}

fn binding_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CloudBinding> {
    Ok(CloudBinding {
        photo_id: row.get(0)?,
        content_generation: row.get(1)?,
        media_id: row.get(2)?,
        is_hidden: row.get(3)?,
        is_trashed: row.get(4)?,
        content_stale: row.get(5)?,
        dirty: row.get(6)?,
    })
}

const BINDING_SELECT: &str = "SELECT b.photo_id,b.content_generation,b.media_id,b.is_hidden,b.is_trashed,b.content_stale,COALESCE(s.dirty,0) FROM cloud_bindings b LEFT JOIN media_sync_state s ON s.library_id=b.library_id AND s.media_id=b.media_id";

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

/// The name a cloud-side move publishes under: the wanted name when it is
/// free, otherwise the first suffixed variant that is not taken. A foreign
/// file sitting on the wanted name must not block the sync forever.
fn unique_move_target(current: &Path, target: &Path) -> Result<PathBuf, String> {
    if !target.exists() || target == current {
        return Ok(target.to_path_buf());
    }
    let parent = target.parent().ok_or("Internal")?;
    let name = target
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or("Internal")?;
    let stem = Path::new(name)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| !stem.is_empty())
        .unwrap_or("photo");
    let extension = Path::new(name).extension().and_then(|ext| ext.to_str());
    for index in 1..=9999_u32 {
        let candidate = if let Some(extension) = extension {
            parent.join(format!("{stem}_{index}.{extension}"))
        } else {
            parent.join(format!("{stem}_{index}"))
        };
        if !candidate.exists() || candidate == current {
            return Ok(candidate);
        }
    }
    Err("NoAvailableFileName".into())
}

/// Whether a file already carries a suffixed spelling of the wanted name. A
/// permanent foreign blocker leaves the photo on `stem_1.ext`; that settled
/// name must not be reshuffled on every sync.
fn settled_under_suffix(current: &Path, target: &Path) -> bool {
    if current
        .parent()
        .zip(target.parent())
        .is_none_or(|(a, b)| a != b)
    {
        return false;
    }
    let Some(current_name) = current.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    let Some(target_name) = target.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    let Some(current_stem) = Path::new(current_name).file_stem().and_then(|s| s.to_str()) else {
        return false;
    };
    let Some(target_stem) = Path::new(target_name).file_stem().and_then(|s| s.to_str()) else {
        return false;
    };
    let extension = Path::new(current_name).extension().and_then(|e| e.to_str())
        == Path::new(target_name).extension().and_then(|e| e.to_str());
    let suffix = current_stem
        .strip_prefix(target_stem)
        .and_then(|rest| rest.strip_prefix('_'));
    extension
        && !target_stem.is_empty()
        && (current_stem == target_stem
            || suffix.is_some_and(|rest| {
                !rest.is_empty() && rest.bytes().all(|byte| byte.is_ascii_digit())
            }))
}

impl LocalLibrary {
    pub(crate) fn cloud_account(&self) -> Result<Option<CloudAccount>, String> {
        self.execute(|c| {
            c.query_row(
                &format!("SELECT {ACCOUNT_COLUMNS} FROM cloud_accounts WHERE is_active=1 LIMIT 1"),
                [],
                account_row,
            )
            .optional()
            .map_err(error)
        })
    }

    pub(crate) fn cloud_accounts(&self) -> Result<Vec<CloudAccount>, String> {
        self.execute(|c| {
            let mut statement = c
                .prepare(&format!(
                    "SELECT {ACCOUNT_COLUMNS} FROM cloud_accounts ORDER BY created_at_ms,account_id"
                ))
                .map_err(error)?;
            statement
                .query_map([], account_row)
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    pub(crate) fn cloud_account_by_identity(
        &self,
        endpoint: String,
        username: String,
    ) -> Result<Option<CloudAccount>, String> {
        self.execute(move |c| {
            c.query_row(
                &format!(
                    "SELECT {ACCOUNT_COLUMNS} FROM cloud_accounts WHERE endpoint=?1 AND username=?2"
                ),
                params![endpoint, username],
                account_row,
            )
            .optional()
            .map_err(error)
        })
    }

    pub(crate) fn cloud_set_active_account(&self, account_id: String) -> Result<(), String> {
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            let exists: bool = tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM cloud_accounts WHERE account_id=?1)",
                    [&account_id],
                    |r| r.get(0),
                )
                .map_err(error)?;
            if !exists {
                return Err("AccountNotFound".into());
            }
            tx.execute(
                "UPDATE cloud_accounts SET is_active=0 WHERE is_active=1",
                [],
            )
            .map_err(error)?;
            tx.execute(
                "UPDATE cloud_accounts SET is_active=1 WHERE account_id=?1",
                [&account_id],
            )
            .map_err(error)?;
            tx.commit().map_err(error)
        })
    }

    pub(crate) fn cloud_remove_account(&self, account_id: String) -> Result<(), String> {
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            for table in [
                "cloud_metadata_operations",
                "cloud_content_operations",
                "cloud_delete_operations",
            ] {
                tx.execute(
                    &format!("DELETE FROM {table} WHERE account_id=?1"),
                    [&account_id],
                )
                .map_err(error)?;
            }
            let removed = tx
                .execute(
                    "DELETE FROM cloud_accounts WHERE account_id=?1",
                    [&account_id],
                )
                .map_err(error)?;
            if removed == 0 {
                return Err("AccountNotFound".into());
            }
            tx.commit().map_err(error)
        })
    }

    pub(crate) fn cloud_upsert_account(&self, account: CloudAccount) -> Result<(), String> {
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            tx.execute(
                "INSERT INTO cloud_accounts(account_id,endpoint,username,user_id,token_file,token_expires_at_ms,device_id,created_at_ms,last_sync_ms,upload_scope,is_active,download_root) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,0,?11) ON CONFLICT(account_id) DO UPDATE SET endpoint=excluded.endpoint,username=excluded.username,user_id=excluded.user_id,token_file=excluded.token_file,token_expires_at_ms=excluded.token_expires_at_ms,device_id=excluded.device_id,last_sync_ms=excluded.last_sync_ms,download_root=excluded.download_root",
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
                    account.upload_scope,
                    account.download_root,
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
                "SELECT sync_token,snapshot_token,status,error_code,last_sync_ms FROM cloud_sync_state WHERE account_id=?1",
                [&account_id],
                |r| {
                    Ok(CloudSyncState {
                        sync_token: r.get(0)?,
                        snapshot_token: r.get(1)?,
                        status: r.get(2)?,
                        error_code: r.get(3)?,
                        last_sync_ms: r.get(4)?,
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

    pub(crate) fn cloud_clear_records_and_token(&self, account_id: String) -> Result<(), String> {
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
            tx.execute(
                "DELETE FROM cloud_records WHERE account_id=?1",
                [&account_id],
            )
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

    pub(crate) fn cloud_bindings(&self, account_id: String) -> Result<Vec<CloudBinding>, String> {
        self.execute(move |c| {
            let mut statement = c
                .prepare(&format!(
                    "{BINDING_SELECT} WHERE b.account_id=?1 ORDER BY b.photo_id"
                ))
                .map_err(error)?;
            statement
                .query_map([&account_id], binding_row)
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    pub(crate) fn cloud_dirty_bindings(
        &self,
        account_id: String,
    ) -> Result<Vec<CloudBinding>, String> {
        self.execute(move |c|{
            let mut statement=c.prepare(&format!("{BINDING_SELECT} WHERE b.account_id=?1 AND s.dirty=2 AND NOT (s.content_version>s.acked_content_version) ORDER BY b.photo_id")).map_err(error)?;
            statement.query_map([account_id],binding_row).map_err(error)?.collect::<rusqlite::Result<_>>().map_err(error)
        })
    }

    pub(crate) fn cloud_content_bindings(
        &self,
        account_id: String,
    ) -> Result<Vec<CloudBinding>, String> {
        self.execute(move |c| {
            let mut statement = c
                .prepare(&format!(
                    "{BINDING_SELECT} WHERE b.account_id=?1 AND s.dirty=2 AND s.content_version>s.acked_content_version ORDER BY b.photo_id"
                ))
                .map_err(error)?;
            statement
                .query_map([&account_id], binding_row)
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    pub(crate) fn cloud_delete_bindings(
        &self,
        account_id: String,
    ) -> Result<Vec<CloudBinding>, String> {
        self.execute(move |c| {
            let mut statement = c
                .prepare(&format!(
                    "{BINDING_SELECT} WHERE b.account_id=?1 AND s.dirty=4 ORDER BY b.photo_id"
                ))
                .map_err(error)?;
            statement
                .query_map([&account_id], binding_row)
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    /// Remote photos whose local copy was permanently deleted. They must not
    /// be downloaded again while their cloud deletion is still outstanding.
    pub(crate) fn cloud_pending_delete_photo_ids(
        &self,
        account_id: String,
    ) -> Result<Vec<String>, String> {
        self.execute(move |c| {
            let mut statement = c
                .prepare(
                    "SELECT b.photo_id FROM cloud_bindings b JOIN media_sync_state s ON s.library_id=b.library_id AND s.media_id=b.media_id WHERE b.account_id=?1 AND s.dirty=4",
                )
                .map_err(error)?;
            statement
                .query_map([&account_id], |r| r.get(0))
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
                .prepare("SELECT b.media_id,m.source_uri,m.state FROM cloud_bindings b JOIN media m ON m.library_id=b.library_id AND m.media_id=b.media_id WHERE b.account_id=?1")
                .map_err(error)?;
            statement
                .query_map([&account_id], |r| {
                    Ok(CloudBindingMedia {
                        media_id: r.get(0)?,
                        path: r.get(1)?,
                        state: r.get(2)?,
                    })
                })
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    pub(crate) fn cloud_account_bound_media_ids(
        &self,
        account_id: String,
    ) -> Result<Vec<String>, String> {
        self.execute(move |c| {
            let mut statement = c
                .prepare("SELECT DISTINCT media_id FROM cloud_bindings WHERE account_id=?1")
                .map_err(error)?;
            statement
                .query_map([&account_id], |r| r.get(0))
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    /// Every downloaded cloud photo, regardless of which saved account owns it.
    /// File-mutating actions use this set so switching accounts never makes a
    /// managed cloud copy editable.
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

    pub(crate) fn cloud_media_bound(&self, media_id: String) -> Result<bool, String> {
        let library = self.library_id.clone();
        self.execute(move |c| is_bound(c, &library, &media_id))
    }

    /// Whether a media row other than this photo's own binding already owns
    /// the path. A download must never rebind another photo's file.
    pub(crate) fn cloud_path_claimed_by_other(
        &self,
        account_id: String,
        photo_id: String,
        path: String,
    ) -> Result<bool, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            c.query_row(
                "SELECT EXISTS(SELECT 1 FROM media m WHERE m.library_id=?1 AND m.source_uri=?2 \
                 AND NOT EXISTS(SELECT 1 FROM cloud_bindings b WHERE b.library_id=m.library_id \
                 AND b.media_id=m.media_id AND b.account_id=?3 AND b.photo_id=?4))",
                params![library, path, account_id, photo_id],
                |r| r.get(0),
            )
            .map_err(error)
        })
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
                .prepare("SELECT media_id,content_generation,photo_id,master_id,relative_path,operation_id,content_version,size_bytes,modified_ns FROM cloud_uploads WHERE account_id=?1 AND state IN ('pending','publishing') ORDER BY created_at_ms")
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
                    "SELECT (SELECT COUNT(*) FROM cloud_uploads WHERE account_id=?1 AND state IN ('pending','publishing'))
                        + (SELECT COUNT(*) FROM cloud_bindings b JOIN media_sync_state s ON s.library_id=b.library_id AND s.media_id=b.media_id WHERE b.account_id=?1 AND s.dirty=2 AND s.content_version>s.acked_content_version)
                        + (SELECT COUNT(*) FROM cloud_bindings b JOIN media_sync_state s ON s.library_id=b.library_id AND s.media_id=b.media_id WHERE b.account_id=?1 AND s.dirty=4)",
                    [&account_id],
                    |r| r.get::<_, i64>(0),
                )
                .map_err(error)?;
            let failed_uploads = c
                .query_row(
                    "SELECT COUNT(*) FROM cloud_uploads u WHERE u.account_id=?1 AND u.state='failed'
                       AND NOT EXISTS(SELECT 1 FROM cloud_bindings b WHERE b.account_id=u.account_id AND b.media_id=u.media_id)
                       AND NOT EXISTS(SELECT 1 FROM cloud_uploads newer WHERE newer.account_id=u.account_id AND newer.media_id=u.media_id AND newer.state IN ('pending','publishing','published'))",
                    [&account_id],
                    |r| r.get::<_, i64>(0),
                )
                .map_err(error)?;
            let pending_favorites = c
                .query_row(
                    "SELECT COUNT(*) FROM cloud_bindings b JOIN media_sync_state s ON s.library_id=b.library_id AND s.media_id=b.media_id WHERE b.account_id=?1 AND s.dirty=2 AND NOT (s.content_version>s.acked_content_version)",
                    [&account_id],
                    |r| r.get::<_, i64>(0),
                )
                .map_err(error)?;
            Ok(CloudCounts {
                pending_uploads: pending_uploads.max(0) as u32,
                failed_uploads: failed_uploads.max(0) as u32,
                pending_favorites: pending_favorites.max(0) as u32,
                bound: bound.max(0) as u32,
            })
        })
    }

    pub(crate) fn cloud_upload_albums(&self, account_id: String) -> Result<Vec<String>, String> {
        self.execute(move |c| {
            let mut statement = c
                .prepare(
                    "SELECT folder FROM cloud_upload_albums WHERE account_id=?1 ORDER BY folder",
                )
                .map_err(error)?;
            statement
                .query_map([&account_id], |r| r.get(0))
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    pub(crate) fn cloud_set_upload_scope(
        &self,
        account_id: String,
        mode: String,
        albums: Vec<String>,
    ) -> Result<(), String> {
        if !matches!(mode.as_str(), "none" | "selected" | "all") {
            return Err("InvalidUploadScope".into());
        }
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            let exists: bool = tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM cloud_accounts WHERE account_id=?1)",
                    [&account_id],
                    |r| r.get(0),
                )
                .map_err(error)?;
            if !exists {
                return Err("AccountNotFound".into());
            }
            tx.execute(
                "UPDATE cloud_accounts SET upload_scope=?2 WHERE account_id=?1",
                params![account_id, mode],
            )
            .map_err(error)?;
            tx.execute(
                "DELETE FROM cloud_upload_albums WHERE account_id=?1",
                [&account_id],
            )
            .map_err(error)?;
            let mut seen = std::collections::HashSet::new();
            for folder in albums {
                let folder = folder.trim().to_owned();
                if folder.is_empty() || !seen.insert(folder.clone()) {
                    continue;
                }
                tx.execute(
                    "INSERT INTO cloud_upload_albums(account_id,folder) VALUES(?1,?2)",
                    params![account_id, folder],
                )
                .map_err(error)?;
            }
            tx.commit().map_err(error)
        })
    }

    /// Local photos the active account's explicit upload scope still owes.
    /// Managed cloud sources are downloads, and a binding or an existing
    /// upload row means this account has already seen the photo.
    /// Whether the explicit upload scope still owns at least one local photo.
    /// The automatic scheduler asks this before starting a sweep; it must not
    /// become a periodic remote poll when nothing local changed.
    pub(crate) fn cloud_scope_has_candidates(
        &self,
        account_id: String,
        all_albums: bool,
    ) -> Result<bool, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            c.query_row(
                "SELECT EXISTS(SELECT 1 FROM media m JOIN sources s ON s.library_id=m.library_id AND s.source_id=m.source_id
                 WHERE m.library_id=?1 AND m.state='active' AND s.source_kind<>'managed'
                   AND NOT EXISTS(SELECT 1 FROM cloud_bindings b WHERE b.account_id=?2 AND b.media_id=m.media_id)
                   AND NOT EXISTS(SELECT 1 FROM cloud_uploads u WHERE u.account_id=?2 AND u.media_id=m.media_id)
                   AND (?3=1 OR EXISTS(SELECT 1 FROM cloud_upload_albums a WHERE a.account_id=?2 AND a.folder=m.parent_uri)))",
                params![library, account_id, all_albums],
                |r| r.get(0),
            )
            .map_err(error)
        })
    }

    pub(crate) fn cloud_scope_candidates(
        &self,
        account_id: String,
        all_albums: bool,
    ) -> Result<Vec<CloudScopeCandidate>, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let mut statement = c
                .prepare(
                    "SELECT m.media_id,m.source_uri,m.display_name,m.mime_type,m.content_version,m.size_bytes,m.modified_ns,m.sort_time_ms,m.parent_uri,s.root_uri
                     FROM media m JOIN sources s ON s.library_id=m.library_id AND s.source_id=m.source_id
                     WHERE m.library_id=?1 AND m.state='active' AND s.source_kind<>'managed'
                       AND NOT EXISTS(SELECT 1 FROM cloud_bindings b WHERE b.account_id=?2 AND b.media_id=m.media_id)
                       AND NOT EXISTS(SELECT 1 FROM cloud_uploads u WHERE u.account_id=?2 AND u.media_id=m.media_id)
                       AND (?3=1 OR EXISTS(SELECT 1 FROM cloud_upload_albums a WHERE a.account_id=?2 AND a.folder=m.parent_uri))
                     ORDER BY m.sort_time_ms,m.media_id",
                )
                .map_err(error)?;
            statement
                .query_map(params![library, account_id, all_albums], |r| {
                    Ok(CloudScopeCandidate {
                        media_id: r.get(0)?,
                        path: r.get(1)?,
                        name: r.get(2)?,
                        mime_type: r.get(3)?,
                        content_version: sql_u64(r, 4)?,
                        size_bytes: sql_u64(r, 5)?,
                        modified_ns: r.get(6)?,
                        sort_time_ms: r.get(7)?,
                        parent: r.get(8)?,
                        root: r.get(9)?,
                    })
                })
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }

    /// Choose the real directory this account's downloads mirror into.
    ///
    /// The directory is created when missing and registered as an ordinary
    /// linked source, so the downloaded albums are real albums the scanner and
    /// the album UI already understand. The private data root is refused: a
    /// download root inside it would be invisible to the user and skipped by
    /// every scan.
    pub(crate) fn set_cloud_download_root(
        &self,
        account_id: &str,
        path: &str,
    ) -> Result<String, String> {
        let requested = PathBuf::from(path);
        if !requested.is_absolute() {
            return Err("DownloadRootMustBeAbsolute".into());
        }
        fs::create_dir_all(&requested).map_err(|_| "DownloadRootUnavailable".to_owned())?;
        let directory = requested
            .canonicalize()
            .map_err(|_| "DownloadRootUnavailable".to_owned())?;
        if directory == self.root || directory.starts_with(&self.root) {
            return Err("DownloadRootInsideDataRoot".into());
        }
        let path = directory
            .to_str()
            .ok_or("UnsupportedPathEncoding")?
            .to_owned();
        let source_id = self.add_source(&directory)?;
        let account = account_id.to_owned();
        self.execute(move |c| {
            let changed = c
                .execute(
                    "UPDATE cloud_accounts SET download_root=?2 WHERE account_id=?1",
                    params![account, path],
                )
                .map_err(error)?;
            if changed == 0 {
                return Err("AccountNotFound".into());
            }
            Ok(())
        })?;
        Ok(source_id)
    }

    /// Every real root the downloaded photos live under: the accounts' chosen
    /// download directories plus the managed directories older libraries
    /// still use.
    pub(crate) fn cloud_download_roots(&self) -> Result<Vec<PathBuf>, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let mut statement = c
                .prepare(
                    "SELECT DISTINCT root_uri FROM sources WHERE library_id=?1 AND source_kind='managed'
                     UNION SELECT DISTINCT download_root FROM cloud_accounts WHERE download_root IS NOT NULL",
                )
                .map_err(error)?;
            statement
                .query_map([&library], |r| r.get::<_, String>(0))
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
        .map(|roots| roots.into_iter().map(PathBuf::from).collect())
    }

    /// The bytes the app downloaded from the cloud.
    ///
    /// The setting shows this next to the thumbnail cache, because the
    /// cleanup removes both, and the downloaded photos are the bigger part.
    /// The originals live as real files under the accounts' download roots;
    /// the thumbnails, the session tokens and older managed copies stay in
    /// the private data root.
    pub fn cloud_usage(&self) -> Result<u64, String> {
        let roots = self.cloud_download_roots()?;
        let legacy = self.root.join("cloud");
        let originals = self.execute(move |c| {
            let mut statement = c
                .prepare(
                    "SELECT DISTINCT m.source_uri FROM cloud_bindings b \
                     JOIN media m ON m.library_id=b.library_id AND m.media_id=b.media_id \
                     WHERE b.thumbnail_path IS NOT NULL",
                )
                .map_err(error)?;
            statement
                .query_map([], |r| r.get::<_, String>(0))
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })?;
        let mut total: u64 = originals
            .into_iter()
            .filter(|uri| {
                // Legacy managed originals are counted by the directory walk
                // below; counting them here again would double the usage.
                let path = Path::new(uri);
                roots.iter().any(|root| path.starts_with(root)) && !path.starts_with(&legacy)
            })
            .filter_map(|uri| fs::metadata(uri).ok())
            .map(|meta| meta.len())
            .sum();
        for directory in [legacy, self.root.join("cache").join("cloud")] {
            total += walkdir::WalkDir::new(directory)
                .follow_links(false)
                .into_iter()
                .flatten()
                .filter(|entry| entry.file_type().is_file())
                .filter_map(|entry| entry.metadata().ok())
                .map(|meta| meta.len())
                .sum::<u64>();
        }
        Ok(total)
    }

    /// Remove everything the app downloaded from the cloud.
    ///
    /// The bytes, the session token and the catalog rows go together: a half
    /// state would show photos the library no longer knows, and a session
    /// without its catalog would sync into nothing. Only photos the cloud
    /// delivered are deleted: rows are selected through their binding before
    /// the cloud tables go, and files are only removed under the accounts'
    /// download roots or the legacy managed directories, so the user's own
    /// photos that happen to live in the same real folders stay untouched.
    ///
    /// The rows go first and the bytes second, and the rows go in the order
    /// the foreign keys demand: the metadata operations point at the
    /// bindings, and the bindings and the uploads point at the media of the
    /// library without a cascade.
    ///
    /// Returns the number of removed cloud photos.
    pub fn clear_cloud_state(&self) -> Result<usize, String> {
        let library = self.library_id.clone();
        let root = self.root.clone();
        let roots = self.cloud_download_roots()?;
        // The bindings with a downloaded thumbnail are the only proof that a
        // media row came from the cloud; uploaded photos keep their file even
        // when the user picked their folder as the download root.
        let targets: Vec<(String, String)> = self.execute(move |c| {
            let mut statement = c
                .prepare(
                    "SELECT DISTINCT b.media_id,m.source_uri FROM cloud_bindings b \
                     JOIN media m ON m.library_id=b.library_id AND m.media_id=b.media_id \
                     WHERE b.thumbnail_path IS NOT NULL",
                )
                .map_err(error)?;
            statement
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })?;
        let targets: Vec<(String, String)> = targets
            .into_iter()
            .filter(|(_, uri)| roots.iter().any(|root| Path::new(uri).starts_with(root)))
            .collect();
        let media_ids: Vec<String> = targets.iter().map(|(id, _)| id.clone()).collect();
        let removed = self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            let accounts: Vec<String> = {
                let mut statement = tx
                    .prepare("SELECT account_id FROM cloud_accounts")
                    .map_err(error)?;
                statement
                    .query_map([], |r| r.get(0))
                    .map_err(error)?
                    .collect::<rusqlite::Result<Vec<_>>>()
                    .map_err(error)?
            };
            // The cloud rows of the account. The metadata operations point at
            // the bindings, so they have to go before them.
            for account_id in &accounts {
                for table in [
                    "cloud_metadata_operations",
                    "cloud_content_operations",
                    "cloud_delete_operations",
                    "cloud_bindings",
                    "cloud_uploads",
                    "cloud_account_scope",
                    "cloud_sync_state",
                    "cloud_records",
                    "cloud_upload_albums",
                ] {
                    tx.execute(
                        &format!("DELETE FROM {table} WHERE account_id=?1"),
                        params![account_id],
                    )
                    .map_err(error)?;
                }
                tx.execute(
                    "DELETE FROM cloud_accounts WHERE account_id=?1",
                    params![account_id],
                )
                .map_err(error)?;
            }
            // The photos that came from the cloud.
            for media_id in &media_ids {
                tx.execute(
                    "DELETE FROM file_publications WHERE library_id=?1 AND operation_id IN \
                     (SELECT operation_id FROM file_operations WHERE library_id=?1 AND media_id=?2)",
                    params![library, media_id],
                )
                .map_err(error)?;
                for table in [
                    "thumbnails",
                    "album_members",
                    "file_operations",
                    "edit_projects",
                    "library_memberships",
                ] {
                    if table == "edit_projects" {
                        tx.execute(
                            "DELETE FROM edit_steps WHERE library_id=?1 AND edit_id IN \
                             (SELECT edit_id FROM edit_projects WHERE library_id=?1 AND media_id=?2)",
                            params![library, media_id],
                        )
                        .map_err(error)?;
                    }
                    tx.execute(
                        &format!("DELETE FROM {table} WHERE library_id=?1 AND media_id=?2"),
                        params![library, media_id],
                    )
                    .map_err(error)?;
                }
                tx.execute(
                    "DELETE FROM media WHERE library_id=?1 AND media_id=?2",
                    params![library, media_id],
                )
                .map_err(error)?;
            }
            // The pending cloud work of the photos the user owns is meaningless
            // now: the queue and the bindings are gone, so a stale marker would
            // swallow the next edit instead of sending it up.
            tx.execute(
                "DELETE FROM media_sync_state WHERE library_id=?1",
                params![library],
            )
            .map_err(error)?;
            // Legacy managed sources disappear with their rows; a download
            // root stays a normal source the user manages themselves.
            tx.execute(
                "DELETE FROM scan_runs WHERE library_id=?1 AND source_id IN \
                 (SELECT source_id FROM sources WHERE library_id=?1 AND source_kind='managed')",
                params![library],
            )
            .map_err(error)?;
            tx.execute(
                "DELETE FROM sources WHERE library_id=?1 AND source_kind='managed'",
                params![library],
            )
            .map_err(error)?;
            super::tools::recount(&tx, &library)?;
            tx.commit().map_err(error)?;
            Ok(media_ids.len())
        })?;
        // The bytes: the downloaded originals, then the empty album folders
        // they leaves behind, then the private cloud state.
        for (_, uri) in &targets {
            let _ = fs::remove_file(uri);
            let mut directory = Path::new(uri).parent().map(Path::to_path_buf);
            while let Some(folder) = directory {
                if roots.contains(&folder) || !folder.is_dir() {
                    break;
                }
                // A folder that still holds anything is a user folder now.
                let empty = match fs::read_dir(&folder) {
                    Ok(mut entries) => entries.next().is_none(),
                    Err(_) => false,
                };
                directory = if empty {
                    let _ = fs::remove_dir(&folder);
                    folder.parent().map(Path::to_path_buf)
                } else {
                    None
                };
            }
        }
        let _ = fs::remove_dir_all(root.join("cache").join("cloud"));
        let cloud = root.join("cloud");
        if cloud.is_dir() {
            fs::remove_dir_all(&cloud).map_err(error)?;
        }
        Ok(removed)
    }

    /// Move bound photo files so they keep mirroring their cloud relative
    /// path inside the download root.
    ///
    /// A rename, an album move or a path swap on the cloud side changes the
    /// binding's relative path; the local file follows so the album layout
    /// stays an exact mirror. Photos with a pending local path edit keep
    /// their file where it is until the edit is uploaded, and files outside
    /// the download root (legacy managed copies or user-moved files) are left
    /// alone.
    pub(crate) fn cloud_sync_remote_paths(
        &self,
        account_id: String,
        download_root: PathBuf,
    ) -> Result<usize, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let rows: Vec<(String, String, String, String)> = {
                let mut statement = c
                    .prepare(
                        "SELECT b.media_id,b.relative_path,m.source_uri,m.mime_type FROM cloud_bindings b \
                         JOIN media m ON m.library_id=b.library_id AND m.media_id=b.media_id \
                         LEFT JOIN media_sync_state s ON s.library_id=m.library_id AND s.media_id=m.media_id \
                         WHERE b.account_id=?1 AND b.thumbnail_path IS NOT NULL \
                         AND b.relative_path NOT LIKE '/%' \
                         AND m.state<>'trashed' AND COALESCE(s.path_dirty,0)=0",
                    )
                    .map_err(error)?;
                statement
                    .query_map([&account_id], |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, String>(1)?,
                            r.get::<_, String>(2)?,
                            r.get::<_, String>(3)?,
                        ))
                    })
                    .map_err(error)?
                    .collect::<rusqlite::Result<Vec<_>>>()
                    .map_err(error)?
            };
            let mut queue: Vec<(String, PathBuf, PathBuf)> = Vec::new();
            for (media_id, relative_path, source_uri, mime_type) in rows {
                let current = PathBuf::from(&source_uri);
                if !current.starts_with(&download_root) || !current.is_file() {
                    continue;
                }
                let Some(extension) =
                    crate::cloud::paths::download_extension(&relative_path, &mime_type)
                else {
                    continue;
                };
                let placement =
                    crate::cloud::paths::download_placement(&download_root, &relative_path);
                let target = placement.directory.join(format!("{}.{extension}", placement.stem));
                if target != current && !settled_under_suffix(&current, &target) {
                    queue.push((media_id, current, target));
                }
            }
            let mut moved = 0;
            // A move whose target is still occupied by another pending move
            // waits for that move to free the name; an exact swap never
            // unblocks, so the final pass gives the blocked side a suffixed
            // name instead of losing the rename.
            let rounds = queue.len() + 1;
            for round in 0..rounds {
                if queue.is_empty() {
                    break;
                }
                let forced = round + 1 == rounds;
                let round_moves = std::mem::take(&mut queue);
                let mut occupied: std::collections::HashSet<PathBuf> =
                    round_moves.iter().map(|(_, current, _)| current.clone()).collect();
                for (media_id, current, target) in round_moves {
                    if target.is_file() && occupied.contains(&target) && !forced {
                        queue.push((media_id, current, target));
                        continue;
                    }
                    let destination = unique_move_target(&current, &target)?;
                    if let Some(parent) = destination.parent() {
                        fs::create_dir_all(parent).map_err(error)?;
                    }
                    move_file(&current, &destination).map_err(error)?;
                    let display_name = destination
                        .file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    let parent_uri = destination
                        .parent()
                        .map(|parent| parent.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    c.execute(
                        "UPDATE media SET source_uri=?3,parent_uri=?4,display_name=?5 WHERE library_id=?1 AND media_id=?2",
                        params![
                            library,
                            media_id,
                            destination.to_string_lossy().into_owned(),
                            parent_uri,
                            display_name
                        ],
                    )
                    .map_err(error)?;
                    occupied.remove(&current);
                    moved += 1;
                }
            }
            if moved > 0 {
                c.execute(
                    "UPDATE libraries SET revision=revision+1 WHERE library_id=?1",
                    params![library],
                )
                .map_err(error)?;
            }
            Ok(moved)
        })
    }

    /// The album of a local photo relative to the root of its source.
    ///
    /// The cloud record carries this path, so the photo keeps its album when
    /// it is downloaded again. `None` means the album cannot be expressed
    /// relative to the source, and the upload falls back to a flat path.
    pub(crate) fn cloud_album_relative_path(
        &self,
        media_id: &str,
    ) -> Result<Option<String>, String> {
        let library = self.library_id.clone();
        let media = media_id.to_owned();
        self.execute(move |c| {
            c.query_row(
                "SELECT m.parent_uri, s.root_uri FROM media m \
                 JOIN sources s ON s.library_id=m.library_id AND s.source_id=m.source_id \
                 WHERE m.library_id=?1 AND m.media_id=?2",
                params![library, media],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()
            .map(|row| {
                row.and_then(|(parent, root)| {
                    let relative = Path::new(&parent)
                        .strip_prefix(&root)
                        .ok()
                        .map(|path| path.to_string_lossy().replace('\\', "/"))?;
                    if relative.is_empty() {
                        None
                    } else {
                        Some(relative)
                    }
                })
            })
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
                upload_scope: "none".into(),
                is_active: true,
                download_root: None,
            })
            .unwrap();
        library.cloud_set_active_account(ACCOUNT.into()).unwrap();
        (root, library)
    }

    /// The pending-operation state of a binding lives in `media_sync_state`;
    /// the binding projection only carries what the sync engine consumes.
    fn binding_dirty(library: &LocalLibrary, photo_id: &str) -> u8 {
        let photo_id = photo_id.to_owned();
        library
            .execute(move |c| {
                c.query_row(
                    "SELECT COALESCE((SELECT s.dirty FROM media_sync_state s JOIN cloud_bindings b ON b.library_id=s.library_id AND b.media_id=s.media_id WHERE b.photo_id=?1),0)",
                    params![photo_id],
                    |r| r.get(0),
                )
                .map_err(error)
            })
            .unwrap()
    }

    /// The remote path of a binding stays in `cloud_bindings`; the binding
    /// projection only carries what the sync engine consumes.
    fn binding_path(library: &LocalLibrary, photo_id: &str) -> String {
        let photo_id = photo_id.to_owned();
        library
            .execute(move |c| {
                c.query_row(
                    "SELECT relative_path FROM cloud_bindings WHERE photo_id=?1",
                    params![photo_id],
                    |r| r.get(0),
                )
                .map_err(error)
            })
            .unwrap()
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

    /// A binding whose original was downloaded by this client: only these
    /// carry a private thumbnail and may be moved or removed by cloud sync.
    fn downloaded_input(
        source_id: &str,
        photo_id: &str,
        relative_path: &str,
        path: &Path,
        favorite: bool,
    ) -> RemoteMediaInput {
        let mut input = remote_input(source_id, photo_id, relative_path, path, favorite);
        input.thumbnail_path = Some(format!("/private/cloud/{photo_id}/thumbnail.jpg"));
        input.thumbnail_sha256 = Some("0".repeat(64));
        input
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
                vec![
                    record("A", false, Some("{\"v\":1}")),
                    record("B", false, Some("{\"v\":2}")),
                ],
            )
            .unwrap();
        library
            .cloud_apply_record_changes(
                ACCOUNT.into(),
                vec![
                    record("A", true, None),
                    record("B", false, Some("{\"v\":3}")),
                ],
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

    #[tokio::test]
    async fn a_cached_cloud_thumbnail_displays_without_decoding_the_original() {
        let (root, library) = open_library();
        let folder = root.path().join("photos");
        fs::create_dir_all(&folder).unwrap();
        let (source, media) = seed_photo(&library, &folder, "cloud.jpg");
        let original = library.photo(media).unwrap();
        let thumbnail = root.path().join("cloud-preview.jpg");
        image::RgbImage::from_pixel(32, 24, image::Rgb([20, 40, 80]))
            .save(&thumbnail)
            .unwrap();
        let mut input = remote_input(
            &source,
            "cloud-photo",
            "cloud.jpg",
            Path::new(&original.path),
            false,
        );
        input.thumbnail_path = Some(thumbnail.to_string_lossy().into());
        let media = library
            .cloud_publish_remote_media(ACCOUNT.into(), input)
            .unwrap();
        fs::remove_file(&original.path).unwrap();
        let loader = crate::thumbnail_loader::ThumbnailLoader::new(library.clone(), 1);
        let path = loader
            .request(media, None, 256, "cloud-preview".into(), 0)
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        assert_eq!(Path::new(&path), thumbnail);
        assert_eq!(loader.progress().unwrap().metrics.generated, 0);
        loader.close();
    }

    #[test]
    fn a_favorite_confirmed_by_one_account_stays_pending_for_another() {
        let (_root, library, media) = metadata_binding();
        library.set_favorite(media.clone(), true).unwrap();
        let zone = syncserver_client::ZoneId::new("PrimarySync");
        let issued = library
            .cloud_issue_metadata(ACCOUNT.into(), metadata_photo(), zone.clone())
            .unwrap()
            .unwrap();
        library
            .cloud_confirm_metadata(ACCOUNT.into(), issued.clone(), confirmed_metadata(&issued))
            .unwrap();
        assert_eq!(binding_dirty(&library, "photo-1"), 0);

        library
            .cloud_upsert_account(CloudAccount {
                account_id: "acct-2".into(),
                endpoint: "http://127.0.0.1:8791".into(),
                username: "bob".into(),
                user_id: Some("user-2".into()),
                token_file: "cloud/acct-2/session.token".into(),
                token_expires_at_ms: None,
                device_id: "device-2".into(),
                created_at_ms: 2,
                last_sync_ms: None,
                upload_scope: "none".into(),
                is_active: false,
                download_root: None,
            })
            .unwrap();
        let photo = library.photo(media).unwrap();
        let source = library.sources().unwrap()[0].id.clone();
        library
            .cloud_publish_remote_media(
                "acct-2".into(),
                remote_input(&source, "photo-1", "a.jpg", Path::new(&photo.path), false),
            )
            .unwrap();
        library
            .cloud_apply_remote_metadata("acct-2".into(), "photo-1".into(), false, None)
            .unwrap();

        assert!(library.photo(photo.id.clone()).unwrap().favorite);
        assert_eq!(binding_dirty(&library, "photo-1"), 2);
        let counts = library.cloud_counts("acct-2".into()).unwrap();
        assert_eq!(counts.pending_favorites, 1);

        let issued = library
            .cloud_issue_metadata("acct-2".into(), metadata_photo(), zone)
            .unwrap()
            .unwrap();
        assert!(issued.mutation.metadata.is_favorite);
        library
            .cloud_confirm_metadata("acct-2".into(), issued.clone(), confirmed_metadata(&issued))
            .unwrap();
        assert_eq!(binding_dirty(&library, "photo-1"), 0);
        assert!(library.photo(photo.id).unwrap().favorite);
    }

    #[test]
    fn metadata_batch_of_100_is_bounded_and_identical_replays_do_no_writes() {
        let (root, library) = open_library();
        let folder = root.path().join("media");
        fs::create_dir_all(&folder).unwrap();
        let source = library.add_source(&folder).unwrap();
        let mut input = Vec::new();
        for index in 0..100 {
            let photo = format!("photo-{index}");
            let name = format!("{index}.jpg");
            let path = folder.join(&name);
            fs::write(&path, b"cloud fixture").unwrap();
            library
                .cloud_publish_remote_media(
                    ACCOUNT.into(),
                    remote_input(&source, &photo, &name, &path, false),
                )
                .unwrap();
            input.push((photo, true, None));
        }
        let started = std::time::Instant::now();
        assert_eq!(
            library
                .cloud_apply_remote_metadata_batch(ACCOUNT.into(), input.clone())
                .unwrap(),
            100
        );
        assert!(
            started.elapsed() < std::time::Duration::from_secs(1),
            "100-record metadata batch took {:?}",
            started.elapsed()
        );
        let counts = library_favorite_counts(&library);
        assert_eq!(counts, (100, 100));
        let changes = |library: &LocalLibrary| {
            library
                .execute(|c| {
                    c.query_row("SELECT total_changes()", [], |r| r.get::<_, i64>(0))
                        .map_err(error)
                })
                .unwrap()
        };
        let before = changes(&library);
        let revision = library.info().unwrap().revision;
        assert_eq!(
            library
                .cloud_apply_remote_metadata_batch(ACCOUNT.into(), input.clone())
                .unwrap(),
            0
        );
        assert_eq!(changes(&library), before);
        assert_eq!(library.info().unwrap().revision, revision);
        input.push(("too-many".into(), true, None));
        assert!(
            library
                .cloud_apply_remote_metadata_batch(ACCOUNT.into(), input)
                .is_err()
        );
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
        assert_eq!(binding_dirty(&library, "photo-1"), 2);
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
        assert_eq!(binding_dirty(&library, "photo-1"), 2);
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
        assert_eq!(binding_dirty(&library, "photo-1"), 0);
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
                binding_dirty(&library, "photo-1"),
                if keep_local { 2 } else { 0 }
            );
            if keep_local && local_time.is_none() {
                let issued = library
                    .cloud_issue_metadata(
                        ACCOUNT.into(),
                        metadata_photo(),
                        syncserver_client::ZoneId::primary(),
                    )
                    .unwrap()
                    .unwrap();
                assert_eq!(issued.mutation.event.edited_at_ms, 0);
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
        // Managed sources only exist as rows of libraries that downloaded
        // into the private cloud folder before the real download root; they
        // keep their protected handling until the cleanup removes them.
        let (root, library) = open_library();
        let managed_dir = root.path().join("cloud").join(ACCOUNT);
        fs::create_dir_all(&managed_dir).unwrap();
        let managed = library.add_source(&managed_dir).unwrap();
        let source_id = managed.clone();
        library
            .execute(move |c| {
                c.execute(
                    "UPDATE sources SET source_kind='managed',recursive=0 WHERE source_id=?1",
                    params![source_id],
                )
                .map_err(error)
            })
            .unwrap();
        let source = library
            .sources()
            .unwrap()
            .into_iter()
            .find(|s| s.id == managed)
            .unwrap();
        assert_eq!(source.kind, "managed");
        assert_eq!(library.remove_source(managed).unwrap_err(), "ManagedSource");
    }

    #[test]
    fn bound_media_stays_editable() {
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

        library
            .rename_media(media_id.clone(), "renamed.jpg".into())
            .unwrap();
        assert!(folder.join("renamed.jpg").is_file());
        assert!(!path.exists());
        assert_eq!(library.photo(media_id.clone()).unwrap().name, "renamed.jpg");

        library.trash_media(vec![media_id.clone()]).unwrap();
        assert_eq!(library.photo(media_id).unwrap().state, "trashed");
        assert_eq!(library.cloud_bound_media_ids().unwrap().len(), 1);
    }

    fn path_binding_fixture() -> (
        tempfile::TempDir,
        tempfile::TempDir,
        LocalLibrary,
        String,
        Vec<String>,
    ) {
        let root = tempfile::TempDir::new().unwrap();
        let downloads = tempfile::TempDir::new().unwrap();
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
                upload_scope: "none".into(),
                is_active: true,
                download_root: None,
            })
            .unwrap();
        library.cloud_set_active_account(ACCOUNT.into()).unwrap();
        let source = library
            .set_cloud_download_root(ACCOUNT, downloads.path().to_str().unwrap())
            .unwrap();
        let mut media_ids = Vec::new();
        // A flat cloud path publishes into the Cloud album of the root, so
        // the fixture mirrors what a download would have written.
        let cloud_album = downloads.path().join("Cloud");
        fs::create_dir_all(&cloud_album).unwrap();
        for name in ["one", "two"] {
            let path = cloud_album.join(format!("{name}.jpg"));
            fs::write(&path, b"cloud fixture").unwrap();
            media_ids.push(
                library
                    .cloud_publish_remote_media(
                        ACCOUNT.into(),
                        downloaded_input(&source, name, &format!("{name}.jpg"), &path, false),
                    )
                    .unwrap(),
            );
        }
        (root, downloads, library, source, media_ids)
    }

    #[test]
    fn binding_paths_swap_atomically_without_changing_media_identity() {
        let (_root, _downloads, library, _source, media_ids) = path_binding_fixture();
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
        assert_eq!(binding_path(&library, "one"), "two.jpg");
        assert_eq!(binding_path(&library, "two"), "one.jpg");
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
    fn a_cloud_rename_moves_the_file_into_the_new_album() {
        let (_root, downloads, library, _source, media_ids) = path_binding_fixture();
        library
            .cloud_refresh_binding_paths(
                ACCOUNT.into(),
                vec![
                    ("one".into(), "Camera/moved.jpg".into()),
                    ("two".into(), "two.jpg".into()),
                ],
            )
            .unwrap();
        let moved = library
            .cloud_sync_remote_paths(ACCOUNT.into(), downloads.path().to_path_buf())
            .unwrap();
        assert_eq!(moved, 1);
        let expected = downloads.path().join("Camera").join("moved.jpg");
        assert!(expected.is_file(), "the file must follow its cloud path");
        assert!(!downloads.path().join("one.jpg").exists());
        let photo = library.photo(media_ids[0].clone()).unwrap();
        assert_eq!(photo.path, expected.to_string_lossy());
        assert_eq!(photo.name, "moved.jpg");
        // The photo the cloud did not touch keeps its file.
        assert!(downloads.path().join("Cloud").join("two.jpg").is_file());
    }

    #[test]
    fn a_download_root_must_be_absolute_and_outside_the_data_root() {
        let (root, library) = open_library();
        let inside = root.path().join("nested");
        fs::create_dir_all(&inside).unwrap();
        assert_eq!(
            library
                .set_cloud_download_root(ACCOUNT, inside.to_str().unwrap())
                .unwrap_err(),
            "DownloadRootInsideDataRoot"
        );
        assert_eq!(
            library
                .set_cloud_download_root(ACCOUNT, "not/absolute")
                .unwrap_err(),
            "DownloadRootMustBeAbsolute"
        );
    }

    fn count_rows(library: &LocalLibrary, table: &str) -> i64 {
        let table = table.to_owned();
        library
            .execute(move |c| {
                c.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                    .map_err(error)
            })
            .unwrap()
    }

    #[test]
    fn clearing_the_cloud_state_removes_the_downloads_and_the_catalog() {
        let (root, downloads, library, _source, media_ids) = path_binding_fixture();
        // The session token lives under the private cloud folder of the data
        // root; the user never has to find it by hand.
        let cloud = root.path().join("cloud").join(ACCOUNT);
        fs::create_dir_all(cloud.join("media")).unwrap();
        fs::write(cloud.join("session.token"), b"token").unwrap();
        // A file the user dropped into the download root is not a download.
        let user_file = downloads.path().join("user-file.jpg");
        fs::write(&user_file, b"user owned").unwrap();
        assert_eq!(library.cloud_bindings(ACCOUNT.into()).unwrap().len(), 2);
        assert_eq!(library.cloud_bound_media_ids().unwrap().len(), 2);
        assert!(count_rows(&library, "cloud_accounts") > 0);

        let removed = library.clear_cloud_state().unwrap();
        assert_eq!(removed, 2, "the downloaded photos were not removed");
        // The downloaded bytes and the session are gone; the download root
        // itself and the user's own file in it stay.
        assert!(!downloads.path().join("Cloud").join("one.jpg").exists());
        assert!(!downloads.path().join("Cloud").join("two.jpg").exists());
        assert!(downloads.path().is_dir(), "the download root was removed");
        assert!(
            user_file.is_file(),
            "a user file inside the root was deleted"
        );
        assert!(!cloud.exists(), "the cloud folder survived the cleanup");
        // The catalog rows are gone with them.
        assert!(library.cloud_bindings(ACCOUNT.into()).unwrap().is_empty());
        assert!(library.cloud_bound_media_ids().unwrap().is_empty());
        for table in [
            "cloud_accounts",
            "cloud_bindings",
            "cloud_uploads",
            "cloud_records",
            "cloud_sync_state",
            "cloud_account_scope",
            "cloud_metadata_operations",
        ] {
            assert_eq!(
                count_rows(&library, table),
                0,
                "{table} survived the cleanup"
            );
        }
        // The photos the cloud brought in are gone from the library itself.
        assert_eq!(
            library
                .query(PhotoFilter::default(), None, 10)
                .unwrap()
                .total,
            0
        );
        assert_eq!(media_ids.len(), 2);
    }

    #[test]
    fn cloud_moves_and_cleanup_keep_uploaded_photos_in_the_download_root() {
        let (_root, library) = open_library();
        let downloads = tempfile::TempDir::new().unwrap();
        library
            .set_cloud_download_root(ACCOUNT, downloads.path().to_str().unwrap())
            .unwrap();
        let folder = downloads.path().join("Camera");
        fs::create_dir_all(&folder).unwrap();
        let (source, media_id) = seed_photo(&library, &folder, "mine.jpg");
        let path = folder.join("mine.jpg");
        library
            .cloud_publish_remote_media(
                ACCOUNT.into(),
                remote_input(&source, "uploaded", "Camera/mine.jpg", &path, false),
            )
            .unwrap();

        // A cloud rename never rearranges a file this client uploaded; only
        // downloaded originals mirror the remote path.
        library
            .cloud_refresh_binding_paths(
                ACCOUNT.into(),
                vec![("uploaded".into(), "Other/renamed.jpg".into())],
            )
            .unwrap();
        assert_eq!(
            library
                .cloud_sync_remote_paths(ACCOUNT.into(), downloads.path().to_path_buf(),)
                .unwrap(),
            0
        );
        assert!(path.is_file());
        assert!(!downloads.path().join("Other").join("renamed.jpg").exists());

        assert_eq!(library.clear_cloud_state().unwrap(), 0);
        assert!(path.is_file(), "an uploaded original was deleted");
        assert_eq!(
            library.photo(media_id).unwrap().path,
            path.to_str().unwrap()
        );
        assert!(library.cloud_bound_media_ids().unwrap().is_empty());
    }

    #[test]
    fn orphan_binding_releases_its_path_and_can_later_return() {
        let (_root, downloads, library, source, media_ids) = path_binding_fixture();
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
        let path = downloads.path().join("Cloud").join("three.jpg");
        fs::write(&path, b"cloud fixture").unwrap();
        library
            .cloud_publish_remote_media(
                ACCOUNT.into(),
                downloaded_input(&source, "three", "one.jpg", &path, false),
            )
            .unwrap();
        let bindings = library.cloud_bindings(ACCOUNT.into()).unwrap();
        let orphan = bindings.iter().find(|b| b.photo_id == "one").unwrap();
        assert!(binding_path(&library, "one").starts_with('/'));
        assert_eq!(orphan.media_id, media_ids[0]);
        assert_eq!(library.cloud_bound_media_ids().unwrap().len(), 3);
        assert!(downloads.path().join("Cloud").join("one.jpg").is_file());
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
        assert_eq!(binding_path(&library, "one"), "restored.jpg");
        assert_eq!(restored.media_id, media_ids[0]);
    }

    #[test]
    fn binding_path_conflict_rolls_back_the_entire_remap() {
        let (_root, _downloads, library, _source, _ids) = path_binding_fixture();
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
        assert_eq!(binding_path(&library, "one"), "one.jpg");
        assert_eq!(binding_path(&library, "two"), "two.jpg");
    }
    #[test]
    fn cloud_scope_pin_rejects_changed_namespace_or_database_generation() {
        let (_root, library) = open_library();
        let namespace = syncserver_client::Namespace {
            tenant: "user".into(),
            container: "photos".into(),
            environment: "production".into(),
            database: "private".into(),
        };
        assert!(
            library
                .cloud_pin_scope(ACCOUNT.into(), namespace.clone(), "generation-1".into())
                .unwrap()
        );
        assert!(
            library
                .cloud_pin_scope(ACCOUNT.into(), namespace.clone(), "generation-1".into())
                .unwrap()
        );
        assert!(
            !library
                .cloud_pin_scope(ACCOUNT.into(), namespace.clone(), "generation-2".into())
                .unwrap()
        );
        let mut other = namespace.clone();
        other.tenant = "another-user".into();
        assert!(
            !library
                .cloud_pin_scope(ACCOUNT.into(), other, "generation-1".into())
                .unwrap()
        );
        assert!(
            library
                .cloud_pin_scope(ACCOUNT.into(), namespace, "generation-1".into())
                .unwrap()
        );
    }

    #[test]
    fn account_switch_keeps_each_account_scope_and_removes_one_at_a_time() {
        let (_root, library) = open_library();
        library
            .cloud_upsert_account(CloudAccount {
                account_id: "acct-2".into(),
                endpoint: "http://127.0.0.1:8791".into(),
                username: "bob".into(),
                user_id: Some("user-2".into()),
                token_file: "cloud/acct-2/session.token".into(),
                token_expires_at_ms: None,
                device_id: "device-2".into(),
                created_at_ms: 2,
                last_sync_ms: None,
                upload_scope: "none".into(),
                is_active: false,
                download_root: None,
            })
            .unwrap();
        library.cloud_set_active_account("acct-2".into()).unwrap();
        assert_eq!(
            library.cloud_account().unwrap().unwrap().account_id,
            "acct-2"
        );
        library
            .cloud_set_upload_scope(
                "acct-2".into(),
                "selected".into(),
                vec!["/photos/A".into(), "/photos/A".into(), " ".into()],
            )
            .unwrap();
        let active = library.cloud_account().unwrap().unwrap();
        assert_eq!(active.upload_scope, "selected");
        assert_eq!(
            library.cloud_upload_albums("acct-2".into()).unwrap(),
            vec!["/photos/A"]
        );
        let accounts = library.cloud_accounts().unwrap();
        assert_eq!(accounts.len(), 2);
        assert!(accounts.iter().filter(|account| account.is_active).count() == 1);

        library.cloud_remove_account("acct-2".into()).unwrap();
        assert!(library.cloud_account().unwrap().is_none());
        assert_eq!(library.cloud_accounts().unwrap().len(), 1);
        library.cloud_set_active_account(ACCOUNT.into()).unwrap();
        assert_eq!(
            library.cloud_account().unwrap().unwrap().account_id,
            ACCOUNT
        );
    }
}
