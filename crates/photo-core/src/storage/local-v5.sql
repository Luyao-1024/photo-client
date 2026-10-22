-- One metadata history per media item; a field value is never an operation ID.
CREATE TABLE media_sync_state (
 library_id TEXT NOT NULL, media_id TEXT NOT NULL,
 dirty INTEGER NOT NULL DEFAULT 0 CHECK(dirty IN (0,1,2,4)),
 local_version INTEGER NOT NULL DEFAULT 0 CHECK(local_version>=0),
 metadata_version INTEGER NOT NULL DEFAULT 0 CHECK(metadata_version>=0),
 acked_metadata_version INTEGER NOT NULL DEFAULT 0 CHECK(acked_metadata_version>=0 AND acked_metadata_version<=metadata_version),
 edited_at_ms INTEGER, source TEXT, event_id TEXT,
 remote_edited_at_ms INTEGER, remote_source TEXT, remote_event_id TEXT,
 PRIMARY KEY(library_id,media_id),
 FOREIGN KEY(library_id,media_id) REFERENCES media(library_id,media_id) ON DELETE CASCADE
) STRICT;
-- v4 has no original edit stamp. Retain its last recorded dirty time and
-- assign a migration event; never claim this is a recovered exact edit time.
INSERT INTO media_sync_state(library_id,media_id,dirty,local_version,metadata_version,acked_metadata_version,edited_at_ms,source,event_id)
 SELECT b.library_id,b.media_id,CASE WHEN b.favorite_dirty<>0 THEN 2 ELSE 0 END,
 CASE WHEN b.favorite_dirty<>0 THEN 1 ELSE 0 END,CASE WHEN b.favorite_dirty<>0 THEN 1 ELSE 0 END,0,
 CASE WHEN b.favorite_dirty<>0 THEN b.updated_at_ms END,
 CASE WHEN b.favorite_dirty<>0 THEN (SELECT installation_id FROM app_meta WHERE singleton=1) END,
 CASE WHEN b.favorite_dirty<>0 THEN 'migration-'||lower(hex(randomblob(16))) END
 FROM cloud_bindings b;
INSERT OR IGNORE INTO media_sync_state(library_id,media_id,dirty)
 SELECT library_id,media_id,1 FROM cloud_uploads WHERE state IN ('pending','publishing');
ALTER TABLE cloud_bindings DROP COLUMN favorite_dirty;
CREATE TABLE cloud_metadata_operations (
 account_id TEXT NOT NULL, photo_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 library_id TEXT NOT NULL, media_id TEXT NOT NULL,
 zone_name TEXT NOT NULL, record_revision TEXT NOT NULL,
 captured_local_version INTEGER NOT NULL, captured_metadata_version INTEGER NOT NULL,
 relative_path TEXT NOT NULL, is_favorite INTEGER NOT NULL CHECK(is_favorite IN (0,1)),
 is_hidden INTEGER NOT NULL CHECK(is_hidden IN (0,1)), asset_date_ms INTEGER,
 edited_at_ms INTEGER NOT NULL, source TEXT NOT NULL, event_id TEXT NOT NULL,
 created_at_ms INTEGER NOT NULL,
 PRIMARY KEY(account_id,photo_id), UNIQUE(account_id,operation_id),
 FOREIGN KEY(account_id,photo_id) REFERENCES cloud_bindings(account_id,photo_id)
) STRICT;
CREATE TABLE cloud_account_scope (
 account_id TEXT PRIMARY KEY,
 tenant TEXT NOT NULL, container TEXT NOT NULL, environment TEXT NOT NULL,
 database_name TEXT NOT NULL, database_generation TEXT NOT NULL,
 FOREIGN KEY(account_id) REFERENCES cloud_accounts(account_id)
) STRICT;
