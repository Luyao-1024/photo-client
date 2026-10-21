CREATE TABLE IF NOT EXISTS cloud_accounts (
 account_id TEXT PRIMARY KEY, endpoint TEXT NOT NULL, username TEXT NOT NULL, user_id TEXT,
 token_file TEXT NOT NULL, token_expires_at_ms INTEGER, device_id TEXT NOT NULL,
 created_at_ms INTEGER NOT NULL, last_sync_ms INTEGER,
 UNIQUE(endpoint,username)
) STRICT;
CREATE TABLE IF NOT EXISTS cloud_sync_state (
 account_id TEXT PRIMARY KEY, zone_name TEXT, sync_token TEXT, snapshot_token TEXT,
 status TEXT NOT NULL DEFAULT 'logged_out' CHECK(status IN ('logged_out','idle','error','token_expired')),
 error_code TEXT, last_sync_ms INTEGER, updated_at_ms INTEGER NOT NULL,
 FOREIGN KEY(account_id) REFERENCES cloud_accounts(account_id) ON DELETE CASCADE
) STRICT;
CREATE TABLE IF NOT EXISTS cloud_records (
 account_id TEXT NOT NULL, record_name TEXT NOT NULL, record_type TEXT, record_change_tag TEXT,
 deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)), record_json TEXT,
 updated_at_ms INTEGER NOT NULL, PRIMARY KEY(account_id,record_name),
 FOREIGN KEY(account_id) REFERENCES cloud_accounts(account_id) ON DELETE CASCADE
) STRICT;
CREATE INDEX IF NOT EXISTS idx_cloud_records_type ON cloud_records(account_id,record_type,deleted);
CREATE TABLE IF NOT EXISTS cloud_bindings (
 account_id TEXT NOT NULL, photo_id TEXT NOT NULL, master_id TEXT NOT NULL,
 content_generation TEXT NOT NULL, library_id TEXT NOT NULL, media_id TEXT NOT NULL,
 relative_path TEXT NOT NULL, cloud_favorite INTEGER NOT NULL DEFAULT 0 CHECK(cloud_favorite IN (0,1)),
 favorite_dirty INTEGER NOT NULL DEFAULT 0 CHECK(favorite_dirty IN (0,1)),
 asset_date_ms INTEGER, is_hidden INTEGER NOT NULL DEFAULT 0 CHECK(is_hidden IN (0,1)),
 is_trashed INTEGER NOT NULL DEFAULT 0 CHECK(is_trashed IN (0,1)),
 content_stale INTEGER NOT NULL DEFAULT 0 CHECK(content_stale IN (0,1)),
 thumbnail_path TEXT, thumbnail_sha256 TEXT,
 created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
 PRIMARY KEY(account_id,photo_id), UNIQUE(account_id,media_id), UNIQUE(account_id,relative_path),
 FOREIGN KEY(account_id) REFERENCES cloud_accounts(account_id) ON DELETE CASCADE,
 FOREIGN KEY(library_id,media_id) REFERENCES media(library_id,media_id)
) STRICT;
CREATE INDEX IF NOT EXISTS idx_cloud_bindings_media ON cloud_bindings(account_id,library_id,media_id);
CREATE TABLE IF NOT EXISTS cloud_uploads (
 account_id TEXT NOT NULL, library_id TEXT NOT NULL, media_id TEXT NOT NULL,
 content_generation TEXT NOT NULL, photo_id TEXT NOT NULL, master_id TEXT NOT NULL,
 relative_path TEXT NOT NULL, operation_id TEXT NOT NULL,
 content_version INTEGER NOT NULL, size_bytes INTEGER NOT NULL CHECK(size_bytes>=0),
 modified_ns INTEGER NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','publishing','published','failed')),
 attempt INTEGER NOT NULL DEFAULT 0 CHECK(attempt>=0), error_code TEXT,
 created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
 PRIMARY KEY(account_id,media_id,content_generation), UNIQUE(account_id,operation_id),
 UNIQUE(account_id,relative_path),
 FOREIGN KEY(account_id) REFERENCES cloud_accounts(account_id) ON DELETE CASCADE,
 FOREIGN KEY(library_id,media_id) REFERENCES media(library_id,media_id)
) STRICT;
CREATE INDEX IF NOT EXISTS idx_cloud_uploads_state ON cloud_uploads(account_id,state,created_at_ms);
