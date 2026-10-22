-- Content replacement and permanent deletion are independent obligations.
-- Metadata and content share dirty=2 but advance separate versions/events;
-- delete uses dirty=4 and keeps the local row until the cloud confirms.
ALTER TABLE media_sync_state ADD COLUMN path_dirty INTEGER NOT NULL DEFAULT 0;
ALTER TABLE media_sync_state ADD COLUMN content_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE media_sync_state ADD COLUMN acked_content_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE media_sync_state ADD COLUMN content_edited_at_ms INTEGER;
ALTER TABLE media_sync_state ADD COLUMN content_source TEXT;
ALTER TABLE media_sync_state ADD COLUMN content_event_id TEXT;
ALTER TABLE media_sync_state ADD COLUMN deletion_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE media_sync_state ADD COLUMN acked_deletion_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE media_sync_state ADD COLUMN deletion_edited_at_ms INTEGER;
ALTER TABLE media_sync_state ADD COLUMN deletion_source TEXT;
ALTER TABLE media_sync_state ADD COLUMN deletion_event_id TEXT;
ALTER TABLE cloud_metadata_operations ADD COLUMN is_trashed INTEGER NOT NULL DEFAULT 0;
CREATE TABLE cloud_content_operations (
 account_id TEXT NOT NULL, photo_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 zone_name TEXT NOT NULL, content_generation TEXT NOT NULL, base_generation TEXT NOT NULL,
 asset_revision TEXT NOT NULL, master_revision TEXT NOT NULL,
 library_id TEXT NOT NULL, media_id TEXT NOT NULL,
 captured_content_version INTEGER NOT NULL CHECK(captured_content_version>=0),
 captured_media_version INTEGER NOT NULL CHECK(captured_media_version>=0),
 original_sha256 TEXT NOT NULL, thumbnail_sha256 TEXT NOT NULL,
 edited_at_ms INTEGER NOT NULL, source TEXT NOT NULL, event_id TEXT NOT NULL,
 created_at_ms INTEGER NOT NULL,
 PRIMARY KEY(account_id,photo_id), UNIQUE(account_id,operation_id),
 FOREIGN KEY(account_id,photo_id) REFERENCES cloud_bindings(account_id,photo_id)
) STRICT;
CREATE TABLE cloud_delete_operations (
 account_id TEXT NOT NULL, photo_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 zone_name TEXT NOT NULL, asset_revision TEXT NOT NULL, master_revision TEXT NOT NULL,
 library_id TEXT NOT NULL, media_id TEXT NOT NULL,
 captured_deletion_version INTEGER NOT NULL CHECK(captured_deletion_version>=0),
 edited_at_ms INTEGER NOT NULL, source TEXT NOT NULL, event_id TEXT NOT NULL,
 created_at_ms INTEGER NOT NULL,
 PRIMARY KEY(account_id,photo_id), UNIQUE(account_id,operation_id),
 FOREIGN KEY(account_id,photo_id) REFERENCES cloud_bindings(account_id,photo_id)
) STRICT;
