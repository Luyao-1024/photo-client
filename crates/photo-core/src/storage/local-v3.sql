CREATE TABLE IF NOT EXISTS local_preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
CREATE TABLE IF NOT EXISTS album_preferences (
 library_id TEXT NOT NULL, folder TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0,
 cover_media_id TEXT, PRIMARY KEY(library_id,folder),
 FOREIGN KEY(library_id) REFERENCES libraries(library_id)
) STRICT;
CREATE TABLE IF NOT EXISTS media_details (
 library_id TEXT NOT NULL, media_id TEXT NOT NULL, duration_ms INTEGER,
 camera_make TEXT, camera_model TEXT, lens TEXT, exposure TEXT, aperture TEXT,
 iso TEXT, focal_length TEXT, motion_offset INTEGER, animated INTEGER NOT NULL DEFAULT 0, hdr INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(library_id,media_id),
 FOREIGN KEY(library_id,media_id) REFERENCES media(library_id,media_id) ON DELETE CASCADE
) STRICT;
CREATE INDEX IF NOT EXISTS idx_sources_enabled ON sources(library_id,enabled,root_uri);

CREATE TABLE IF NOT EXISTS file_publications (
 library_id TEXT NOT NULL, operation_id TEXT NOT NULL, expected_sha256 TEXT NOT NULL,
 PRIMARY KEY(library_id,operation_id),
 FOREIGN KEY(library_id,operation_id) REFERENCES file_operations(library_id,operation_id) ON DELETE CASCADE
) STRICT;
CREATE TABLE IF NOT EXISTS excluded_paths (
 library_id TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY(library_id,path),
 FOREIGN KEY(library_id) REFERENCES libraries(library_id)
) STRICT;
CREATE TABLE IF NOT EXISTS pending_purges (
 library_id TEXT NOT NULL, operation_id TEXT NOT NULL, media_id TEXT NOT NULL,
 source_uri TEXT NOT NULL, staged_uri TEXT NOT NULL, committed INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(library_id,operation_id), FOREIGN KEY(library_id) REFERENCES libraries(library_id)
) STRICT;
