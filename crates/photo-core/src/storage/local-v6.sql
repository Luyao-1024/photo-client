ALTER TABLE cloud_accounts ADD COLUMN upload_scope TEXT NOT NULL DEFAULT 'none' CHECK(upload_scope IN ('none','selected','all'));
ALTER TABLE cloud_accounts ADD COLUMN is_active INTEGER NOT NULL DEFAULT 0 CHECK(is_active IN (0,1));
CREATE UNIQUE INDEX IF NOT EXISTS idx_cloud_accounts_active ON cloud_accounts(is_active) WHERE is_active=1;
UPDATE cloud_accounts SET is_active=1 WHERE account_id=(SELECT account_id FROM cloud_accounts ORDER BY created_at_ms LIMIT 1);
ALTER TABLE cloud_bindings ADD COLUMN remote_edited_at_ms INTEGER;
ALTER TABLE cloud_bindings ADD COLUMN remote_source TEXT;
ALTER TABLE cloud_bindings ADD COLUMN remote_event_id TEXT;
CREATE TABLE IF NOT EXISTS cloud_upload_albums (
 account_id TEXT NOT NULL, folder TEXT NOT NULL,
 PRIMARY KEY(account_id,folder),
 FOREIGN KEY(account_id) REFERENCES cloud_accounts(account_id) ON DELETE CASCADE
) STRICT;
