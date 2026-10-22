//! Durable content-replacement and permanent-deletion requests.
//!
//! The local catalogue freezes the logical request before the network sees it,
//! so a lost response, a restart or a rebase never loses the user's intent.
use super::*;
use syncserver_client as sdk;

#[derive(Clone, Debug)]
pub(crate) struct IssuedContent {
    pub operation_id: String,
    pub photo_id: String,
    pub content_generation: String,
    pub base_generation: String,
    pub asset_revision: String,
    pub master_revision: String,
    pub library_id: String,
    pub media_id: String,
    pub captured_content_version: i64,
    pub captured_media_version: u64,
    pub original_sha256: String,
    pub thumbnail_sha256: String,
}

#[derive(Clone, Debug)]
pub(crate) struct IssuedDelete {
    pub operation_id: String,
    pub zone: sdk::ZoneId,
    pub photo_id: String,
    pub master_id: String,
    pub asset_revision: String,
    pub master_revision: String,
    pub media_id: String,
    pub captured_deletion_version: i64,
    pub event: sdk::EditEvent,
}

fn issued_content(
    c: &Connection,
    account: &str,
    photo: &str,
) -> Result<Option<IssuedContent>, String> {
    c.query_row("SELECT operation_id,photo_id,content_generation,base_generation,asset_revision,master_revision,library_id,media_id,captured_content_version,captured_media_version,original_sha256,thumbnail_sha256 FROM cloud_content_operations WHERE account_id=?1 AND photo_id=?2", params![account,photo], |r| {
        Ok(IssuedContent {
            operation_id: r.get(0)?,
            photo_id: r.get(1)?,
            content_generation: r.get(2)?,
            base_generation: r.get(3)?,
            asset_revision: r.get(4)?,
            master_revision: r.get(5)?,
            library_id: r.get(6)?,
            media_id: r.get(7)?,
            captured_content_version: r.get(8)?,
            captured_media_version: sql_u64(r, 9)?,
            original_sha256: r.get(10)?,
            thumbnail_sha256: r.get(11)?,
        })
    }).optional().map_err(error)
}

fn issued_delete(
    c: &Connection,
    account: &str,
    photo: &str,
) -> Result<Option<IssuedDelete>, String> {
    c.query_row("SELECT d.operation_id,d.zone_name,d.asset_revision,d.master_revision,d.media_id,d.captured_deletion_version,d.edited_at_ms,d.source,d.event_id,d.photo_id,b.master_id FROM cloud_delete_operations d JOIN cloud_bindings b USING(account_id,photo_id) WHERE d.account_id=?1 AND d.photo_id=?2", params![account,photo], |r| {
        Ok(IssuedDelete {
            operation_id: r.get(0)?,
            zone: sdk::ZoneId::new(r.get::<_, String>(1)?),
            asset_revision: r.get(2)?,
            master_revision: r.get(3)?,
            media_id: r.get(4)?,
            captured_deletion_version: r.get(5)?,
            event: sdk::EditEvent { edited_at_ms: r.get(6)?, source: r.get(7)?, event_id: r.get(8)? },
            photo_id: r.get(9)?,
            master_id: r.get(10)?,
        })
    }).optional().map_err(error)
}

impl LocalLibrary {
    pub(crate) fn cloud_issued_content(
        &self,
        account: String,
        photo: String,
    ) -> Result<Option<IssuedContent>, String> {
        self.execute(move |c| issued_content(c, &account, &photo))
    }

    /// Freeze the exact content replacement before any bytes are sent.
    pub(crate) fn cloud_issue_content(
        &self,
        account: String,
        remote: &sdk::RemotePhoto,
        zone: sdk::ZoneId,
        content_generation: String,
        original_sha256: String,
        thumbnail_sha256: String,
    ) -> Result<Option<IssuedContent>, String> {
        let remote = remote.clone();
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            if let Some(existing) = issued_content(&tx, &account, &remote.photo_id)? {
                return Ok(Some(existing));
            }
            tx.execute("UPDATE media_sync_state SET content_edited_at_ms=COALESCE(content_edited_at_ms,0),content_source=COALESCE(content_source,(SELECT installation_id FROM app_meta WHERE singleton=1)),content_event_id=COALESCE(content_event_id,?3) WHERE (library_id,media_id)=(SELECT library_id,media_id FROM cloud_bindings WHERE account_id=?1 AND photo_id=?2) AND dirty=2 AND content_version>acked_content_version",params![account,remote.photo_id,format!("unknown-{}",Uuid::new_v4())]).map_err(error)?;
            let state = tx.query_row(
                "SELECT b.library_id,b.media_id,s.content_version,s.content_edited_at_ms,s.content_source,s.content_event_id,m.state,m.content_version FROM cloud_bindings b JOIN media_sync_state s ON s.library_id=b.library_id AND s.media_id=b.media_id JOIN media m ON m.library_id=b.library_id AND m.media_id=b.media_id WHERE b.account_id=?1 AND b.photo_id=?2 AND s.dirty=2 AND s.content_version>s.acked_content_version",
                params![account,remote.photo_id],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?, r.get::<_, i64>(3)?, r.get::<_, String>(4)?, r.get::<_, String>(5)?, r.get::<_, String>(6)?, sql_u64(r, 7)?)),
            ).optional().map_err(error)?;
            let Some((library, media, version, time, source, event, state, media_version)) = state else {
                return Ok(None);
            };
            if state != "active" {
                return Ok(None);
            }
            tx.execute(
                "INSERT INTO cloud_content_operations(account_id,photo_id,operation_id,zone_name,content_generation,base_generation,asset_revision,master_revision,library_id,media_id,captured_content_version,captured_media_version,original_sha256,thumbnail_sha256,edited_at_ms,source,event_id,created_at_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)",
                params![account,remote.photo_id,format!("photo-content-{}",Uuid::new_v4()),zone.zone_name,content_generation,remote.content_generation,remote.asset_revision,remote.master_revision,library,media,version,media_version as i64,original_sha256,thumbnail_sha256,time,source,event,now_ms()],
            ).map_err(error)?;
            let operation = issued_content(&tx, &account, &remote.photo_id)?;
            tx.commit().map_err(error)?;
            Ok(operation)
        })
    }

    /// Clear the captured version only after the server confirmed this exact
    /// generation. A newer local edit keeps its own obligation.
    pub(crate) fn cloud_confirm_content(
        &self,
        account: String,
        operation: IssuedContent,
        remote_generation: String,
    ) -> Result<(), String> {
        if remote_generation != operation.content_generation {
            return Err("ContentConfirmationMismatch".into());
        }
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            let current = issued_content(&tx, &account, &operation.photo_id)?;
            let Some(current) = current else {
                return Ok(());
            };
            if current.operation_id != operation.operation_id {
                return Ok(());
            }
            tx.execute("UPDATE media_sync_state SET acked_content_version=MAX(acked_content_version,?3) WHERE library_id=?1 AND media_id=?2", params![operation.library_id,operation.media_id,operation.captured_content_version]).map_err(error)?;
            tx.execute("UPDATE media_sync_state SET dirty=CASE WHEN deletion_version>acked_deletion_version THEN 4 WHEN metadata_version>acked_metadata_version OR content_version>acked_content_version THEN 2 ELSE 0 END WHERE library_id=?1 AND media_id=?2", params![operation.library_id,operation.media_id]).map_err(error)?;
            tx.execute(
                "UPDATE cloud_bindings SET content_generation=?3,content_stale=0,updated_at_ms=?4 WHERE account_id=?1 AND photo_id=?2",
                params![account, operation.photo_id, operation.content_generation, now_ms()],
            ).map_err(error)?;
            tx.execute(
                "DELETE FROM cloud_content_operations WHERE account_id=?1 AND operation_id=?2",
                params![account, operation.operation_id],
            ).map_err(error)?;
            tx.commit().map_err(error)
        })
    }

    pub(crate) fn cloud_forget_content(
        &self,
        account: String,
        operation_id: String,
    ) -> Result<(), String> {
        self.execute(move |c| {
            c.execute(
                "DELETE FROM cloud_content_operations WHERE account_id=?1 AND operation_id=?2",
                params![account, operation_id],
            )
            .map_err(error)?;
            Ok(())
        })
    }

    pub(crate) fn cloud_issued_delete(
        &self,
        account: String,
        photo: String,
    ) -> Result<Option<IssuedDelete>, String> {
        self.execute(move |c| issued_delete(c, &account, &photo))
    }

    pub(crate) fn cloud_issue_delete(
        &self,
        account: String,
        remote: &sdk::RemotePhoto,
        zone: sdk::ZoneId,
    ) -> Result<Option<IssuedDelete>, String> {
        let remote = remote.clone();
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            if let Some(existing) = issued_delete(&tx, &account, &remote.photo_id)? {
                return Ok(Some(existing));
            }
            tx.execute("UPDATE media_sync_state SET deletion_edited_at_ms=COALESCE(deletion_edited_at_ms,0),deletion_source=COALESCE(deletion_source,(SELECT installation_id FROM app_meta WHERE singleton=1)),deletion_event_id=COALESCE(deletion_event_id,?3) WHERE (library_id,media_id)=(SELECT library_id,media_id FROM cloud_bindings WHERE account_id=?1 AND photo_id=?2) AND dirty=4",params![account,remote.photo_id,format!("unknown-{}",Uuid::new_v4())]).map_err(error)?;
            let state = tx.query_row(
                "SELECT b.library_id,b.media_id,s.deletion_version,s.deletion_edited_at_ms,s.deletion_source,s.deletion_event_id FROM cloud_bindings b JOIN media_sync_state s ON s.library_id=b.library_id AND s.media_id=b.media_id WHERE b.account_id=?1 AND b.photo_id=?2 AND s.dirty=4",
                params![account,remote.photo_id],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?, r.get::<_, i64>(3)?, r.get::<_, String>(4)?, r.get::<_, String>(5)?)),
            ).optional().map_err(error)?;
            let Some((library, media, version, time, source, event)) = state else {
                return Ok(None);
            };
            tx.execute(
                "INSERT INTO cloud_delete_operations(account_id,photo_id,operation_id,zone_name,asset_revision,master_revision,library_id,media_id,captured_deletion_version,edited_at_ms,source,event_id,created_at_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
                params![account,remote.photo_id,sdk::delete_operation_id(&remote),zone.zone_name,remote.asset_revision,remote.master_revision,library,media,version,time,source,event,now_ms()],
            ).map_err(error)?;
            let operation = issued_delete(&tx, &account, &remote.photo_id)?;
            tx.commit().map_err(error)?;
            Ok(operation)
        })
    }

    pub(crate) fn cloud_forget_delete(
        &self,
        account: String,
        operation_id: String,
    ) -> Result<(), String> {
        self.execute(move |c| {
            c.execute(
                "DELETE FROM cloud_delete_operations WHERE account_id=?1 AND operation_id=?2",
                params![account, operation_id],
            )
            .map_err(error)?;
            Ok(())
        })
    }

    /// The remote photo is already gone. Finish the local tombstone without an
    /// operation row; the user's deletion still wins over a stale binding.
    pub(crate) fn cloud_confirm_absent_delete(
        &self,
        account: String,
        photo: String,
    ) -> Result<(), String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            let row: Option<(String, i64, i64)> = tx.query_row(
                "SELECT b.media_id,s.deletion_version,s.acked_deletion_version FROM cloud_bindings b JOIN media_sync_state s ON s.library_id=b.library_id AND s.media_id=b.media_id WHERE b.account_id=?1 AND b.photo_id=?2 AND s.dirty=4",
                params![account, photo],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            ).optional().map_err(error)?;
            let Some((media, deletion_version, acked)) = row else {
                return Err("DeleteOperationNotIssued".into());
            };
            if deletion_version <= acked {
                return Err("DeleteOperationChanged".into());
            }
            tx.execute(
                "DELETE FROM cloud_delete_operations WHERE account_id=?1 AND photo_id=?2",
                params![account, photo],
            ).map_err(error)?;
            tx.execute(
                "DELETE FROM cloud_metadata_operations WHERE account_id=?1 AND photo_id=?2",
                params![account, photo],
            ).map_err(error)?;
            tx.execute(
                "DELETE FROM cloud_content_operations WHERE account_id=?1 AND photo_id=?2",
                params![account, photo],
            ).map_err(error)?;
            tx.execute(
                "DELETE FROM cloud_uploads WHERE account_id=?1 AND media_id=?2",
                params![account, media],
            ).map_err(error)?;
            tx.execute(
                "DELETE FROM cloud_bindings WHERE account_id=?1 AND photo_id=?2",
                params![account, photo],
            ).map_err(error)?;
            let remaining: bool = tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM cloud_bindings WHERE library_id=?1 AND media_id=?2)",
                    params![library, media],
                    |r| r.get(0),
                )
                .map_err(error)?;
            if !remaining {
                tx.execute(
                    "DELETE FROM media WHERE library_id=?1 AND media_id=?2",
                    params![library, media],
                )
                .map_err(error)?;
            }
            tools::recount(&tx, &library)?;
            tx.commit().map_err(error)
        })
    }

    /// The cloud delete was acknowledged. Remove the hidden local tombstone.
    pub(crate) fn cloud_confirm_delete(
        &self,
        account: String,
        operation: IssuedDelete,
    ) -> Result<(), String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            let current: Option<(String, i64, String, i64)> = tx.query_row(
                "SELECT d.operation_id,s.dirty,s.media_id,d.captured_deletion_version FROM cloud_delete_operations d JOIN media_sync_state s ON s.library_id=d.library_id AND s.media_id=d.media_id WHERE d.account_id=?1 AND d.photo_id=?2",
                params![account, operation.photo_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            ).optional().map_err(error)?;
            let Some((operation_id, dirty, media_id, captured_deletion_version)) = current else {
                return Err("DeleteOperationNotIssued".into());
            };
            if operation_id != operation.operation_id
                || dirty != 4
                || media_id != operation.media_id
                || captured_deletion_version != operation.captured_deletion_version
            {
                return Err("DeleteOperationChanged".into());
            }
            tx.execute(
                "DELETE FROM cloud_delete_operations WHERE account_id=?1 AND photo_id=?2",
                params![account, operation.photo_id],
            ).map_err(error)?;
            tx.execute(
                "DELETE FROM cloud_metadata_operations WHERE account_id=?1 AND photo_id=?2",
                params![account, operation.photo_id],
            ).map_err(error)?;
            tx.execute(
                "DELETE FROM cloud_content_operations WHERE account_id=?1 AND photo_id=?2",
                params![account, operation.photo_id],
            ).map_err(error)?;
            tx.execute(
                "DELETE FROM cloud_uploads WHERE account_id=?1 AND media_id=?2",
                params![account, operation.media_id],
            ).map_err(error)?;
            tx.execute(
                "DELETE FROM cloud_bindings WHERE account_id=?1 AND photo_id=?2",
                params![account, operation.photo_id],
            ).map_err(error)?;
            let remaining: bool = tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM cloud_bindings WHERE library_id=?1 AND media_id=?2)",
                    params![library, operation.media_id],
                    |r| r.get(0),
                )
                .map_err(error)?;
            if !remaining {
                tx.execute(
                    "DELETE FROM media WHERE library_id=?1 AND media_id=?2",
                    params![library, operation.media_id],
                )
                .map_err(error)?;
            }
            tools::recount(&tx, &library)?;
            tx.commit().map_err(error)
        })
    }
}
