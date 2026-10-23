-- Downloads mirror the cloud relative path inside a real directory the user
-- chose when enabling sync; the account row remembers which directory it is.
ALTER TABLE cloud_accounts ADD COLUMN download_root TEXT;
