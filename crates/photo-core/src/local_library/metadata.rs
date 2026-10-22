//! Metadata changes and confirmations share the catalog transaction. Dirty is
//! general state (0 clean, 1 new, 2 modified); versions identify what a callback
//! may acknowledge. Edit stamps survive retries and process restarts.
use super::*;
use syncserver_client as sdk;

#[derive(Clone, Debug)]
pub(crate) struct IssuedMetadata {
    pub mutation: sdk::MetadataMutation,
    pub library_id: String,
    pub media_id: String,
    pub local_version: i64,
    pub metadata_version: i64,
}

struct DesiredMetadata {
    library: String,
    media: String,
    local_version: i64,
    metadata_version: i64,
    favorite: bool,
    relative_path: String,
    is_trashed: bool,
    edited_at_ms: i64,
    source: String,
    event_id: String,
}

pub(super) fn note_local_edit(c: &Connection, library: &str, media: &str) -> Result<(), String> {
    let source: String = c
        .query_row(
            "SELECT installation_id FROM app_meta WHERE singleton=1",
            [],
            |r| r.get(0),
        )
        .map_err(error)?;
    c.execute(
        "INSERT INTO media_sync_state(library_id,media_id,dirty,local_version,metadata_version,edited_at_ms,source,event_id) VALUES(?1,?2,2,1,1,?3,?4,?5) ON CONFLICT(library_id,media_id) DO UPDATE SET dirty=CASE WHEN dirty=1 THEN 1 ELSE 2 END,local_version=local_version+1,metadata_version=metadata_version+1,edited_at_ms=excluded.edited_at_ms,source=excluded.source,event_id=excluded.event_id",
        params![library,media,now_ms(),source,Uuid::new_v4().to_string()],
    ).map_err(error)?;
    Ok(())
}

pub(super) fn note_local_path_edit(
    c: &Connection,
    library: &str,
    media: &str,
) -> Result<(), String> {
    note_local_edit(c, library, media)?;
    c.execute(
        "UPDATE media_sync_state SET path_dirty=1 WHERE library_id=?1 AND media_id=?2",
        params![library, media],
    )
    .map_err(error)?;
    Ok(())
}

pub(super) fn note_local_content_edit(
    c: &Connection,
    library: &str,
    media: &str,
) -> Result<(), String> {
    let source: String = c
        .query_row(
            "SELECT installation_id FROM app_meta WHERE singleton=1",
            [],
            |r| r.get(0),
        )
        .map_err(error)?;
    c.execute(
        "INSERT INTO media_sync_state(library_id,media_id,dirty,content_version,content_edited_at_ms,content_source,content_event_id) VALUES(?1,?2,2,1,?3,?4,?5) ON CONFLICT(library_id,media_id) DO UPDATE SET dirty=CASE WHEN dirty=1 THEN 1 ELSE 2 END,content_version=content_version+1,content_edited_at_ms=excluded.content_edited_at_ms,content_source=excluded.content_source,content_event_id=excluded.content_event_id",
        params![library,media,now_ms(),source,Uuid::new_v4().to_string()],
    ).map_err(error)?;
    Ok(())
}

pub(super) fn note_local_delete(c: &Connection, library: &str, media: &str) -> Result<(), String> {
    let source: String = c
        .query_row(
            "SELECT installation_id FROM app_meta WHERE singleton=1",
            [],
            |r| r.get(0),
        )
        .map_err(error)?;
    c.execute(
        "INSERT INTO media_sync_state(library_id,media_id,dirty,deletion_version,deletion_edited_at_ms,deletion_source,deletion_event_id) VALUES(?1,?2,4,1,?3,?4,?5) ON CONFLICT(library_id,media_id) DO UPDATE SET dirty=4,deletion_version=deletion_version+1,deletion_edited_at_ms=excluded.deletion_edited_at_ms,deletion_source=excluded.deletion_source,deletion_event_id=excluded.deletion_event_id",
        params![library,media,now_ms(),source,Uuid::new_v4().to_string()],
    ).map_err(error)?;
    c.execute(
        "DELETE FROM cloud_metadata_operations WHERE library_id=?1 AND media_id=?2",
        params![library, media],
    )
    .map_err(error)?;
    c.execute(
        "DELETE FROM cloud_content_operations WHERE library_id=?1 AND media_id=?2",
        params![library, media],
    )
    .map_err(error)?;
    Ok(())
}

pub(super) fn settle_create(
    c: &Connection,
    library: &str,
    media: &str,
    value_changed: bool,
) -> Result<(), String> {
    if value_changed {
        let pending: bool = c.query_row("SELECT EXISTS(SELECT 1 FROM media_sync_state WHERE library_id=?1 AND media_id=?2 AND metadata_version>acked_metadata_version)", params![library,media], |r| r.get(0)).map_err(error)?;
        if !pending {
            note_local_edit(c, library, media)?;
        }
    }
    c.execute("UPDATE media_sync_state SET dirty=CASE WHEN metadata_version>acked_metadata_version THEN 2 ELSE 0 END WHERE library_id=?1 AND media_id=?2", params![library,media]).map_err(error)?;
    Ok(())
}

fn issued(c: &Connection, account: &str, photo: &str) -> Result<Option<IssuedMetadata>, String> {
    c.query_row("SELECT operation_id,zone_name,record_revision,captured_local_version,captured_metadata_version,relative_path,is_favorite,is_hidden,asset_date_ms,edited_at_ms,source,event_id,library_id,media_id,is_trashed FROM cloud_metadata_operations WHERE account_id=?1 AND photo_id=?2", params![account,photo], |r| {
        Ok(IssuedMetadata {
            mutation: sdk::MetadataMutation {
                operation_id: r.get(0)?, zone: sdk::ZoneId::new(r.get::<_,String>(1)?),
                photo_id: photo.into(), record_revision: r.get(2)?,
                metadata: sdk::PhotoMetadata { relative_path: r.get(5)?, is_favorite:r.get(6)?, is_hidden:r.get(7)?, asset_date_ms:r.get(8)? },
                is_trashed: r.get(14)?,
                event: sdk::EditEvent {edited_at_ms:r.get(9)?,source:r.get(10)?,event_id:r.get(11)?},
            },
            local_version:r.get(3)?,metadata_version:r.get(4)?,library_id:r.get(12)?,media_id:r.get(13)?,
        })
    }).optional().map_err(error)
}

fn desired_metadata(
    c: &Connection,
    account: &str,
    photo: &str,
) -> Result<Option<DesiredMetadata>, String> {
    let row = c
        .query_row(
            "SELECT b.library_id,b.media_id,s.local_version,s.metadata_version,m.favorite,m.display_name,m.state,m.source_uri,m.parent_uri,sr.root_uri,sr.source_kind,b.relative_path,s.edited_at_ms,s.source,s.event_id,s.path_dirty
             FROM cloud_bindings b
             JOIN media_sync_state s ON s.library_id=b.library_id AND s.media_id=b.media_id
             JOIN media m ON m.library_id=b.library_id AND m.media_id=b.media_id
             JOIN sources sr ON sr.library_id=m.library_id AND sr.source_id=m.source_id
             WHERE b.account_id=?1 AND b.photo_id=?2 AND s.dirty=2 AND s.metadata_version>s.acked_metadata_version",
            params![account, photo],
            |r| Ok((
                r.get::<_, String>(0)?, r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?, r.get::<_, i64>(3)?,
                r.get::<_, bool>(4)?, r.get::<_, String>(5)?,
                r.get::<_, String>(6)?, r.get::<_, String>(7)?,
                r.get::<_, String>(8)?, r.get::<_, String>(9)?,
                r.get::<_, String>(10)?, r.get::<_, String>(11)?,
                r.get::<_, i64>(12)?, r.get::<_, String>(13)?,
                r.get::<_, String>(14)?, r.get::<_, bool>(15)?,
            )),
        )
        .optional()
        .map_err(error)?;
    let Some((
        library,
        media,
        local_version,
        metadata_version,
        favorite,
        name,
        state,
        source_uri,
        parent_uri,
        root,
        source_kind,
        current_path,
        edited_at_ms,
        source,
        event_id,
        path_dirty,
    )) = row
    else {
        return Ok(None);
    };
    let is_trashed = state == "trashed";
    let relative_path = if path_dirty {
        desired_cloud_path(
            &name,
            &state,
            &source_uri,
            &parent_uri,
            &root,
            &source_kind,
            &current_path,
        )
    } else {
        current_path
    };
    Ok(Some(DesiredMetadata {
        library,
        media,
        local_version,
        metadata_version,
        favorite,
        relative_path,
        is_trashed,
        edited_at_ms,
        source,
        event_id,
    }))
}

/// Derive the cloud path from the local album/name while a photo is visible.
/// A trashed photo keeps the path it had; restore recomputes it from the file
/// that returned to the library.
fn desired_cloud_path(
    name: &str,
    state: &str,
    source_uri: &str,
    parent_uri: &str,
    root: &str,
    source_kind: &str,
    current_path: &str,
) -> String {
    if state != "active" {
        return current_path.to_owned();
    }
    let album = if source_kind == "managed" {
        relative_album(Path::new(parent_uri), Path::new(root))
    } else {
        Path::new(source_uri)
            .parent()
            .and_then(|parent| relative_album(parent, Path::new(root)))
            .or_else(|| relative_album(Path::new(parent_uri), Path::new(root)))
    };
    let file_name = safe_file_name(name).or_else(|| {
        Path::new(current_path)
            .file_name()
            .and_then(|name| safe_file_name(&name.to_string_lossy()))
    });
    let Some(file_name) = file_name else {
        return current_path.to_owned();
    };
    let album = album
        .or_else(|| {
            current_path
                .rsplit_once('/')
                .map(|(parent, _)| parent.to_owned())
        })
        .unwrap_or_default();
    let candidate = if album.is_empty() {
        file_name
    } else {
        format!("{album}/{file_name}")
    };
    if syncserver_client::photo::is_safe_relative_path(&candidate) {
        candidate
    } else {
        current_path.to_owned()
    }
}

fn relative_album(path: &Path, root: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    let mut parts = Vec::new();
    for component in relative.components() {
        let std::path::Component::Normal(segment) = component else {
            return None;
        };
        let segment = segment.to_str()?;
        if segment.is_empty() || segment == "." || segment == ".." || segment.contains('\\') {
            return None;
        }
        parts.push(segment);
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("/"))
    }
}

fn safe_file_name(name: &str) -> Option<String> {
    let name = name.trim();
    if name.is_empty() || name == "." || name == ".." {
        return None;
    }
    let name = name.replace(['/', '\\', '\0'], "-");
    let name = name.trim_matches('.').trim();
    if name.is_empty() || name.len() > 255 {
        None
    } else {
        Some(name.to_owned())
    }
}

impl LocalLibrary {
    pub(crate) fn cloud_issued_metadata(
        &self,
        account: String,
        photo: String,
    ) -> Result<Option<IssuedMetadata>, String> {
        self.execute(move |c| issued(c, &account, &photo))
    }

    /// Freeze one generic metadata request before asking the SDK to send it.
    /// The favorite value and version/event are read together inside the actor.
    pub(crate) fn cloud_issue_metadata(
        &self,
        account: String,
        photo: sdk::RemotePhoto,
        zone: sdk::ZoneId,
    ) -> Result<Option<IssuedMetadata>, String> {
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            if let Some(existing) = issued(&tx, &account, &photo.photo_id)? { return Ok(Some(existing)); }
            // Unknown legacy event time remains unknown (epoch sentinel), not
            // the current upload time. Persist a stable fallback before capture
            // so missing old stamps cannot block or change a retry's identity.
            tx.execute("UPDATE media_sync_state SET edited_at_ms=COALESCE(edited_at_ms,0),source=COALESCE(source,(SELECT installation_id FROM app_meta WHERE singleton=1)),event_id=COALESCE(event_id,?3) WHERE (library_id,media_id)=(SELECT library_id,media_id FROM cloud_bindings WHERE account_id=?1 AND photo_id=?2) AND dirty=2 AND metadata_version>acked_metadata_version",params![account,photo.photo_id,format!("unknown-{}",Uuid::new_v4())]).map_err(error)?;
            let Some(desired) = desired_metadata(&tx, &account, &photo.photo_id)? else { return Ok(None); };
            tx.execute("INSERT INTO cloud_metadata_operations(account_id,photo_id,operation_id,zone_name,record_revision,captured_local_version,captured_metadata_version,relative_path,is_favorite,is_hidden,asset_date_ms,edited_at_ms,source,event_id,created_at_ms,library_id,media_id,is_trashed) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)",
                params![account,photo.photo_id,format!("photo-op-{}",Uuid::new_v4()),zone.zone_name,photo.asset_revision,desired.local_version,desired.metadata_version,desired.relative_path,desired.favorite,photo.is_hidden,photo.asset_date_ms,desired.edited_at_ms,desired.source,desired.event_id,now_ms(),desired.library,desired.media,desired.is_trashed],
            ).map_err(error)?;
            let operation = issued(&tx,&account,&photo.photo_id)?;
            tx.commit().map_err(error)?;
            Ok(operation)
        })
    }

    /// A stale callback settles only its captured versions. In particular,
    /// true -> false -> true while a request is in flight remains dirty.
    pub(crate) fn cloud_confirm_metadata(
        &self,
        account: String,
        operation: IssuedMetadata,
        record: sdk::RemoteRecord,
    ) -> Result<bool, String> {
        sdk::validate_metadata_confirmation(&operation.mutation, record)
            .map_err(|_| "InvalidMetadataConfirmation".to_owned())?;
        self.execute(move |c| {
            let tx=c.transaction().map_err(error)?;
            let Some(current)=issued(&tx,&account,&operation.mutation.photo_id)? else { return Ok(false); };
            if current.mutation.operation_id!=operation.mutation.operation_id { return Ok(false); }
            let event=&operation.mutation.event;
            tx.execute("UPDATE media_sync_state SET acked_metadata_version=MAX(acked_metadata_version,?3),path_dirty=CASE WHEN metadata_version=?3 THEN 0 ELSE path_dirty END,remote_edited_at_ms=?4,remote_source=?5,remote_event_id=?6 WHERE library_id=?1 AND media_id=?2", params![operation.library_id,operation.media_id,operation.metadata_version,event.edited_at_ms,event.source,event.event_id]).map_err(error)?;
            tx.execute("UPDATE media_sync_state SET dirty=CASE WHEN deletion_version>acked_deletion_version THEN 4 WHEN local_version<>?3 OR metadata_version>acked_metadata_version OR content_version>acked_content_version THEN 2 ELSE 0 END WHERE library_id=?1 AND media_id=?2", params![operation.library_id,operation.media_id,operation.local_version]).map_err(error)?;
            tx.execute("UPDATE cloud_bindings SET relative_path=?10,is_trashed=?11,cloud_favorite=?3,remote_edited_at_ms=?7,remote_source=?8,remote_event_id=?9,updated_at_ms=?4 WHERE account_id=?1 AND photo_id=?2 AND library_id=?5 AND media_id=?6", params![account,operation.mutation.photo_id,operation.mutation.metadata.is_favorite,now_ms(),operation.library_id,operation.media_id,event.edited_at_ms,event.source,event.event_id,operation.mutation.metadata.relative_path,operation.mutation.is_trashed]).map_err(error)?;
            tx.execute("DELETE FROM cloud_metadata_operations WHERE account_id=?1 AND photo_id=?2 AND operation_id=?3", params![account,operation.mutation.photo_id,operation.mutation.operation_id]).map_err(error)?;
            let dirty=tx.query_row("SELECT dirty<>0 FROM media_sync_state WHERE library_id=?1 AND media_id=?2",params![operation.library_id,operation.media_id],|r|r.get(0)).map_err(error)?;
            tx.commit().map_err(error)?;
            Ok(dirty)
        })
    }

    /// Rebase a definitively rejected request at the next observed revision;
    /// retain the user's event and versions. Unknown outcomes never use this.
    pub(crate) fn cloud_forget_rejected_metadata(
        &self,
        account: String,
        operation_id: String,
    ) -> Result<(), String> {
        self.execute(move |c| {
            c.execute(
                "DELETE FROM cloud_metadata_operations WHERE account_id=?1 AND operation_id=?2",
                params![account, operation_id],
            )
            .map_err(error)?;
            Ok(())
        })
    }

    pub(crate) fn cloud_metadata_operation_photos(
        &self,
        account: String,
    ) -> Result<Vec<String>, String> {
        self.execute(move |c| {
            let mut statement=c.prepare("SELECT photo_id FROM cloud_metadata_operations WHERE account_id=?1 ORDER BY created_at_ms").map_err(error)?;
            statement.query_map([account], |r| r.get(0)).map_err(error)?.collect::<rusqlite::Result<Vec<_>>>().map_err(error)
        })
    }

    /// Apply category-event arbitration. Pending exact requests are resolved
    /// first; unknown outcomes must not erase a local obligation.
    pub(crate) fn cloud_apply_remote_metadata(
        &self,
        account: String,
        photo: String,
        favorite: bool,
        event: Option<sdk::EditEvent>,
    ) -> Result<bool, String> {
        self.cloud_apply_remote_metadata_batch(account, vec![(photo, favorite, event)])
            .map(|count| count > 0)
    }
    pub(crate) fn cloud_apply_remote_metadata_batch(
        &self,
        account: String,
        items: Vec<(String, bool, Option<sdk::EditEvent>)>,
    ) -> Result<u32, String> {
        if items.len() > 100 {
            return Err("InvalidBatchSize".into());
        }
        let library = self.library_id.clone();
        let cache = self.browse_index.clone();
        self.execute(move |c| {
            let before = c
                .query_row(
                    "SELECT revision FROM libraries WHERE library_id=?1",
                    [&library],
                    |r| sql_u64(r, 0),
                )
                .map_err(error)?;
            let tx = c.transaction().map_err(error)?;
            let mut changed = 0;
            let mut libraries = std::collections::HashSet::new();
            for (photo, favorite, event) in items {
                if let Some(library) =
                    apply_remote_metadata(&tx, &account, &photo, favorite, event)?
                {
                    changed += 1;
                    libraries.insert(library);
                }
            }
            for library in libraries {
                tools::recount(&tx, &library)?;
            }
            tx.commit().map_err(error)?;
            let after = c
                .query_row(
                    "SELECT revision FROM libraries WHERE library_id=?1",
                    [&library],
                    |r| sql_u64(r, 0),
                )
                .map_err(error)?;
            tools::retain_order_after_favorite(&cache, before, after);
            Ok(changed)
        })
    }
}

impl LocalLibrary {
    /// The SDK pins a connection; persist the same identity across restarts.
    /// Legacy v4 accounts adopt their first authenticated, validated scope.
    pub(crate) fn cloud_pin_scope(
        &self,
        account: String,
        namespace: sdk::Namespace,
        generation: String,
    ) -> Result<bool, String> {
        self.execute(move |c| {
            let tx=c.transaction().map_err(error)?;
            tx.execute("INSERT OR IGNORE INTO cloud_account_scope(account_id,tenant,container,environment,database_name,database_generation) VALUES(?1,?2,?3,?4,?5,?6)", params![account,namespace.tenant,namespace.container,namespace.environment,namespace.database,generation]).map_err(error)?;
            let matches=tx.query_row("SELECT tenant=?2 AND container=?3 AND environment=?4 AND database_name=?5 AND database_generation=?6 FROM cloud_account_scope WHERE account_id=?1",params![account,namespace.tenant,namespace.container,namespace.environment,namespace.database,generation],|r|r.get(0)).map_err(error)?;
            tx.commit().map_err(error)?;Ok(matches)
        })
    }
}

fn apply_remote_metadata(
    tx: &rusqlite::Connection,
    account: &str,
    photo: &str,
    favorite: bool,
    event: Option<sdk::EditEvent>,
) -> Result<Option<String>, String> {
    let row=tx.query_row("SELECT library_id,media_id,cloud_favorite,remote_edited_at_ms,remote_source,remote_event_id FROM cloud_bindings WHERE account_id=?1 AND photo_id=?2", params![account,photo], |r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,bool>(2)?,r.get::<_,Option<i64>>(3)?,r.get::<_,Option<String>>(4)?,r.get::<_,Option<String>>(5)?))).optional().map_err(error)?;
    let Some((library, media, cloud_favorite, remote_time, remote_source, remote_event)) = row
    else {
        return Ok(None);
    };
    tx.execute(
        "INSERT OR IGNORE INTO media_sync_state(library_id,media_id) VALUES(?1,?2)",
        params![library, media],
    )
    .map_err(error)?;
    let (dirty,local_time,local_source,local_event,acked):(u8,Option<i64>,Option<String>,Option<String>,i64)=tx.query_row("SELECT dirty,edited_at_ms,source,event_id,acked_metadata_version FROM media_sync_state WHERE library_id=?1 AND media_id=?2", params![library,media], |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).map_err(error)?;
    let current_favorite: bool = tx
        .query_row(
            "SELECT favorite FROM media WHERE library_id=?1 AND media_id=?2",
            params![library, media],
            |r| r.get(0),
        )
        .map_err(error)?;
    if dirty == 0 && cloud_favorite == favorite && current_favorite == favorite {
        if let Some(event) = &event {
            tx.execute("UPDATE cloud_bindings SET remote_edited_at_ms=?3,remote_source=?4,remote_event_id=?5 WHERE account_id=?1 AND photo_id=?2",params![account,photo,event.edited_at_ms,event.source,event.event_id]).map_err(error)?;
            tx.execute("UPDATE media_sync_state SET remote_edited_at_ms=?3,remote_source=?4,remote_event_id=?5 WHERE library_id=?1 AND media_id=?2",params![library,media,event.edited_at_ms,event.source,event.event_id]).map_err(error)?;
        }
        return Ok(None);
    }
    let pending = issued(&tx, &account, &photo)?.is_some();
    if pending {
        return Ok(None);
    }
    let own_create:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM cloud_uploads WHERE account_id=?1 AND photo_id=?2 AND state='published')",params![account,photo],|r|r.get(0)).map_err(error)?;
    let remote_wins = event.as_ref().is_some_and(|remote| {
        let later = (
            remote.edited_at_ms,
            remote.source.as_str(),
            remote.event_id.as_str(),
        ) > (
            local_time.unwrap_or(0),
            local_source.as_deref().unwrap_or(""),
            local_event.as_deref().unwrap_or(""),
        );
        let known = remote_time == Some(remote.edited_at_ms)
            && remote_source.as_deref() == Some(remote.source.as_str())
            && remote_event.as_deref() == Some(remote.event_id.as_str());
        later && !known && !(own_create && acked == 0 && remote.source == "server")
    });
    if let Some(event) = &event {
        tx.execute("UPDATE cloud_bindings SET remote_edited_at_ms=?3,remote_source=?4,remote_event_id=?5 WHERE account_id=?1 AND photo_id=?2",params![account,photo,event.edited_at_ms,event.source,event.event_id]).map_err(error)?;
        tx.execute("UPDATE media_sync_state SET remote_edited_at_ms=?3,remote_source=?4,remote_event_id=?5 WHERE library_id=?1 AND media_id=?2",params![library,media,event.edited_at_ms,event.source,event.event_id]).map_err(error)?;
    }
    // A local edit confirmed by another account has no per-account operation
    // yet. Keep the local value and open a metadata obligation for this
    // account instead of letting its older remote value overwrite the edit.
    let local_later = local_time.is_some()
        && (
            remote_time.unwrap_or(0),
            remote_source.as_deref().unwrap_or(""),
            remote_event.as_deref().unwrap_or(""),
        ) < (
            local_time.unwrap_or(0),
            local_source.as_deref().unwrap_or(""),
            local_event.as_deref().unwrap_or(""),
        );
    if dirty == 0 && !remote_wins && local_later {
        tx.execute("UPDATE media_sync_state SET dirty=2,metadata_version=metadata_version+1 WHERE library_id=?1 AND media_id=?2",params![library,media]).map_err(error)?;
        return Ok(None);
    }
    if dirty != 0 && !remote_wins {
        return Ok(None);
    }
    let changed = tx
        .execute(
            "UPDATE media SET favorite=?3 WHERE library_id=?1 AND media_id=?2 AND favorite<>?3",
            params![library, media, favorite],
        )
        .map_err(error)?
        > 0;
    tx.execute("UPDATE cloud_bindings SET cloud_favorite=?3,updated_at_ms=?4 WHERE account_id=?1 AND photo_id=?2",params![account,photo,favorite,now_ms()]).map_err(error)?;
    if let Some(event) = event {
        tx.execute("UPDATE media_sync_state SET dirty=0,acked_metadata_version=metadata_version,edited_at_ms=?3,source=?4,event_id=?5 WHERE library_id=?1 AND media_id=?2",params![library,media,event.edited_at_ms,event.source,event.event_id]).map_err(error)?;
    }

    Ok(changed.then_some(library))
}
