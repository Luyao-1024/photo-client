-- Local-first design v2. Documentation contract, not an application migration.
PRAGMA foreign_keys=ON;
CREATE TABLE app_meta (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL CHECK(schema_version>0),
  installation_id TEXT NOT NULL, db_revision INTEGER NOT NULL DEFAULT 0 CHECK(db_revision>=0)
) STRICT;
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY CHECK(version>0), checksum TEXT NOT NULL CHECK(length(checksum)=64), applied_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE libraries (
  library_id TEXT PRIMARY KEY, name TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 0 CHECK(revision>=0),
  created_at_ms INTEGER NOT NULL,
  media_count INTEGER NOT NULL DEFAULT 0 CHECK(media_count>=0),
  favorite_count INTEGER NOT NULL DEFAULT 0 CHECK(favorite_count>=0 AND favorite_count<=media_count)
) STRICT;
CREATE TABLE app_settings (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  selected_library_id TEXT REFERENCES libraries(library_id),
  theme TEXT NOT NULL DEFAULT 'system' CHECK(theme IN ('system','light','dark')),
  glass_mode TEXT NOT NULL DEFAULT 'auto' CHECK(glass_mode IN ('auto','full','reduced','plain')),
  locale TEXT NOT NULL DEFAULT 'zh-CN'
) STRICT;
CREATE TABLE sources (
  library_id TEXT NOT NULL, source_id TEXT NOT NULL, root_uri TEXT NOT NULL,
  source_kind TEXT NOT NULL CHECK(source_kind IN ('linked_file','linked_directory','managed')),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
  recursive INTEGER NOT NULL DEFAULT 1 CHECK(recursive IN (0,1)),
  availability TEXT NOT NULL DEFAULT 'available' CHECK(availability IN ('available','unavailable','permission_lost')),
  PRIMARY KEY(library_id,source_id), UNIQUE(library_id,root_uri),
  FOREIGN KEY(library_id) REFERENCES libraries(library_id)
) STRICT;
CREATE TABLE media (
  library_id TEXT NOT NULL, media_id TEXT NOT NULL, source_id TEXT NOT NULL,
  source_uri TEXT NOT NULL, display_name TEXT NOT NULL, parent_uri TEXT NOT NULL,
  size_bytes INTEGER NOT NULL CHECK(size_bytes>=0), modified_ns INTEGER NOT NULL,
  content_version INTEGER NOT NULL DEFAULT 1 CHECK(content_version>0),
  media_kind TEXT NOT NULL CHECK(media_kind IN ('image','video')),
  mime_type TEXT NOT NULL, width INTEGER CHECK(width>0), height INTEGER CHECK(height>0),
  orientation INTEGER NOT NULL DEFAULT 1 CHECK(orientation BETWEEN 1 AND 8),
  capture_time_ms INTEGER, sort_time_ms INTEGER NOT NULL,
  favorite INTEGER NOT NULL DEFAULT 0 CHECK(favorite IN (0,1)),
  state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active','trashed','missing','unsupported')),
  error_code TEXT,
  original_uri TEXT,
  trashed_at_ms INTEGER,
  PRIMARY KEY(library_id,media_id), UNIQUE(library_id,source_uri),
  FOREIGN KEY(library_id,source_id) REFERENCES sources(library_id,source_id)
) STRICT;
CREATE INDEX idx_media_order ON media(library_id,state,sort_time_ms DESC,media_id DESC);
CREATE INDEX idx_media_favorite ON media(library_id,state,favorite,sort_time_ms DESC,media_id DESC);
CREATE INDEX idx_media_folder ON media(library_id,parent_uri,state,sort_time_ms DESC,media_id DESC);
CREATE TABLE thumbnails (
  library_id TEXT NOT NULL, media_id TEXT NOT NULL, content_version INTEGER NOT NULL CHECK(content_version>0),
  size_class INTEGER NOT NULL CHECK(size_class IN (256,512,1024)),
  cache_key TEXT NOT NULL, relative_path TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','ready','failed')),
  error_code TEXT,
  PRIMARY KEY(library_id,media_id,content_version,size_class),
  FOREIGN KEY(library_id,media_id) REFERENCES media(library_id,media_id)
) STRICT;
CREATE TABLE albums (
  library_id TEXT NOT NULL, album_id TEXT NOT NULL, name TEXT NOT NULL,
  position INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(library_id,album_id),
  FOREIGN KEY(library_id) REFERENCES libraries(library_id)
) STRICT;
CREATE TABLE album_members (
  library_id TEXT NOT NULL, album_id TEXT NOT NULL, media_id TEXT NOT NULL,
  PRIMARY KEY(library_id,album_id,media_id),
  FOREIGN KEY(library_id,album_id) REFERENCES albums(library_id,album_id),
  FOREIGN KEY(library_id,media_id) REFERENCES media(library_id,media_id)
) STRICT;
CREATE INDEX idx_album_media ON album_members(library_id,media_id,album_id);
CREATE TABLE scan_runs (
  library_id TEXT NOT NULL, scan_id TEXT NOT NULL, source_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('running','complete','partial','interrupted','cancelled')),
  discovered INTEGER NOT NULL DEFAULT 0 CHECK(discovered>=0),
  started_at_ms INTEGER NOT NULL, completed_at_ms INTEGER, error_code TEXT,
  PRIMARY KEY(library_id,scan_id),
  FOREIGN KEY(library_id,source_id) REFERENCES sources(library_id,source_id)
) STRICT;
CREATE TABLE file_operations (
  library_id TEXT NOT NULL, operation_id TEXT NOT NULL, media_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('trash','restore','purge','export','save_copy')),
  source_uri TEXT NOT NULL, destination_uri TEXT,
  captured_content_version INTEGER NOT NULL CHECK(captured_content_version>0),
  state TEXT NOT NULL CHECK(state IN ('prepared','file_applied','committed','failed','conflict')),
  backup_uri TEXT, error_code TEXT, created_at_ms INTEGER NOT NULL,
  PRIMARY KEY(library_id,operation_id),
  FOREIGN KEY(library_id,media_id) REFERENCES media(library_id,media_id)
) STRICT;
CREATE INDEX idx_file_operation_pending ON file_operations(library_id,state,media_id);
CREATE TABLE edit_projects (
  library_id TEXT NOT NULL, edit_id TEXT NOT NULL, media_id TEXT NOT NULL,
  captured_content_version INTEGER NOT NULL CHECK(captured_content_version>0),
  state TEXT NOT NULL CHECK(state IN ('draft','saving','saved','discarded','conflict')),
  PRIMARY KEY(library_id,edit_id),
  FOREIGN KEY(library_id,media_id) REFERENCES media(library_id,media_id)
) STRICT;
CREATE TABLE edit_steps (
  library_id TEXT NOT NULL, edit_id TEXT NOT NULL, position INTEGER NOT NULL CHECK(position>=0),
  kind TEXT NOT NULL CHECK(kind IN ('crop','rotate','flip_horizontal','flip_vertical','exposure','contrast','saturation')),
  x REAL, y REAL, width REAL, height REAL, scalar REAL,
  PRIMARY KEY(library_id,edit_id,position),
  FOREIGN KEY(library_id,edit_id) REFERENCES edit_projects(library_id,edit_id)
) STRICT;
CREATE TABLE library_groups (
  library_id TEXT NOT NULL, group_id TEXT NOT NULL, parent_id TEXT,
  group_kind TEXT NOT NULL CHECK(group_kind IN ('root','folder','year','month','day')),
  label TEXT NOT NULL, total_count INTEGER NOT NULL DEFAULT 0 CHECK(total_count>=0),
  PRIMARY KEY(library_id,group_id),
  FOREIGN KEY(library_id) REFERENCES libraries(library_id),
  FOREIGN KEY(library_id,parent_id) REFERENCES library_groups(library_id,group_id)
) STRICT;
CREATE TABLE library_memberships (
  library_id TEXT NOT NULL, group_id TEXT NOT NULL, media_id TEXT NOT NULL,
  sort_time_ms INTEGER NOT NULL, favorite INTEGER NOT NULL CHECK(favorite IN (0,1)),
  PRIMARY KEY(library_id,group_id,media_id),
  FOREIGN KEY(library_id,group_id) REFERENCES library_groups(library_id,group_id),
  FOREIGN KEY(library_id,media_id) REFERENCES media(library_id,media_id)
) STRICT;
CREATE INDEX idx_membership_order ON library_memberships(library_id,group_id,sort_time_ms DESC,media_id DESC);
CREATE INDEX idx_membership_favorite ON library_memberships(library_id,group_id,favorite,sort_time_ms DESC,media_id DESC);
CREATE TABLE command_receipts (
  library_id TEXT NOT NULL, command_id TEXT NOT NULL, kind TEXT NOT NULL,
  input_sha256 TEXT NOT NULL CHECK(length(input_sha256)=64),
  result_code TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>=0),
  PRIMARY KEY(library_id,command_id),
  FOREIGN KEY(library_id) REFERENCES libraries(library_id)
) STRICT;
