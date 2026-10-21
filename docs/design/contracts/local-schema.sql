-- Photo Client schema design v1. Documentation contract, NOT an application migration.
-- Validate only in an in-memory or disposable database. No user photos or credentials.
PRAGMA foreign_keys = ON;

CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY CHECK(version > 0),
  checksum TEXT NOT NULL CHECK(length(checksum)=64),
  applied_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE app_meta (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  schema_version INTEGER NOT NULL CHECK(schema_version>0),
  db_revision INTEGER NOT NULL DEFAULT 0 CHECK(db_revision>=0),
  device_id TEXT NOT NULL UNIQUE
) STRICT;
CREATE TABLE accounts (
  account_id TEXT PRIMARY KEY,
  endpoint_origin TEXT NOT NULL,
  remote_user_id TEXT NOT NULL,
  username TEXT NOT NULL,
  credential_ref TEXT UNIQUE,
  session_expires_at_ms INTEGER,
  auth_state TEXT NOT NULL CHECK(auth_state IN ('signed_out','authenticated','expired','revoked','capability_blocked')),
  library_revision INTEGER NOT NULL DEFAULT 0 CHECK(library_revision>=0),
  created_at_ms INTEGER NOT NULL,
  UNIQUE(endpoint_origin,remote_user_id)
) STRICT;
CREATE TABLE app_settings (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  selected_account_id TEXT REFERENCES accounts(account_id),
  sync_enabled INTEGER NOT NULL DEFAULT 1 CHECK(sync_enabled IN (0,1)),
  locale TEXT NOT NULL DEFAULT 'zh-CN',
  theme TEXT NOT NULL DEFAULT 'system' CHECK(theme IN ('system','light','dark')),
  glass_mode TEXT NOT NULL DEFAULT 'auto' CHECK(glass_mode IN ('auto','full','reduced')),
  transparency_strength REAL NOT NULL DEFAULT 0.5 CHECK(transparency_strength>=0 AND transparency_strength<=1),
  motion_preference TEXT NOT NULL DEFAULT 'system' CHECK(motion_preference IN ('system','reduced')),
  contrast_preference TEXT NOT NULL DEFAULT 'system' CHECK(contrast_preference IN ('system','high'))
) STRICT;
CREATE TABLE credential_intents (
  intent_id TEXT PRIMARY KEY,
  account_id TEXT REFERENCES accounts(account_id),
  credential_ref TEXT NOT NULL UNIQUE,
  operation TEXT NOT NULL CHECK(operation IN ('store','delete')),
  state TEXT NOT NULL CHECK(state IN ('registered','secret_written','bound','cleanup_pending','settled')),
  created_at_ms INTEGER NOT NULL,
  error_code TEXT
) STRICT;
CREATE TABLE jobs (
  account_id TEXT NOT NULL,
  job_id TEXT NOT NULL,
  namespace_container TEXT NOT NULL,
  namespace_environment TEXT NOT NULL,
  namespace_database TEXT NOT NULL,
  zone_name TEXT NOT NULL,
  owner_name TEXT NOT NULL,
  database_generation TEXT NOT NULL,
  protocol_version INTEGER NOT NULL CHECK(protocol_version>0),
  config_generation INTEGER NOT NULL DEFAULT 1 CHECK(config_generation>0),
  paused INTEGER NOT NULL DEFAULT 0 CHECK(paused IN (0,1)),
  upload_scope TEXT NOT NULL DEFAULT 'none' CHECK(upload_scope IN ('none','selected_sources','all_managed')),
  scope_state TEXT NOT NULL DEFAULT 'valid' CHECK(scope_state IN ('valid','changed','blocked')),
  last_error_code TEXT,
  PRIMARY KEY(account_id,job_id),
  FOREIGN KEY(account_id) REFERENCES accounts(account_id),
  UNIQUE(account_id,namespace_container,namespace_environment,namespace_database,zone_name,owner_name)
) STRICT;
CREATE TABLE job_capabilities (
  account_id TEXT NOT NULL, job_id TEXT NOT NULL, capability TEXT NOT NULL,
  supported INTEGER NOT NULL CHECK(supported IN (0,1)),
  PRIMARY KEY(account_id,job_id,capability),
  FOREIGN KEY(account_id,job_id) REFERENCES jobs(account_id,job_id)
) STRICT;
CREATE TABLE job_limits (
  account_id TEXT NOT NULL, job_id TEXT NOT NULL, limit_name TEXT NOT NULL,
  value_integer INTEGER NOT NULL CHECK(value_integer>=0),
  PRIMARY KEY(account_id,job_id,limit_name),
  FOREIGN KEY(account_id,job_id) REFERENCES jobs(account_id,job_id)
) STRICT;
CREATE TABLE media_sources (
  account_id TEXT NOT NULL, source_id TEXT NOT NULL,
  adapter_id TEXT NOT NULL, locator TEXT NOT NULL, display_name TEXT NOT NULL,
  grant_state TEXT NOT NULL CHECK(grant_state IN ('valid','expired','unavailable')),
  PRIMARY KEY(account_id,source_id),
  FOREIGN KEY(account_id) REFERENCES accounts(account_id)
) STRICT;
CREATE TABLE job_scope_sources (
  account_id TEXT NOT NULL, job_id TEXT NOT NULL, source_id TEXT NOT NULL,
  PRIMARY KEY(account_id,job_id,source_id),
  FOREIGN KEY(account_id,job_id) REFERENCES jobs(account_id,job_id),
  FOREIGN KEY(account_id,source_id) REFERENCES media_sources(account_id,source_id)
) STRICT;
CREATE TABLE job_config_intents (
  account_id TEXT NOT NULL, intent_id TEXT NOT NULL, job_id TEXT NOT NULL,
  base_generation INTEGER NOT NULL CHECK(base_generation>0),
  target_generation INTEGER NOT NULL CHECK(target_generation>base_generation),
  upload_scope TEXT NOT NULL CHECK(upload_scope IN ('none','selected_sources','all_managed')),
  state TEXT NOT NULL CHECK(state IN ('accepted','quiescing','applied','superseded','failed')),
  accepted_at_ms INTEGER NOT NULL,
  PRIMARY KEY(account_id,intent_id),
  FOREIGN KEY(account_id,job_id) REFERENCES jobs(account_id,job_id)
) STRICT;
CREATE UNIQUE INDEX uq_pending_config ON job_config_intents(account_id,job_id) WHERE state IN ('accepted','quiescing');
CREATE TABLE job_config_sources (
  account_id TEXT NOT NULL, intent_id TEXT NOT NULL, source_id TEXT NOT NULL,
  PRIMARY KEY(account_id,intent_id,source_id),
  FOREIGN KEY(account_id,intent_id) REFERENCES job_config_intents(account_id,intent_id),
  FOREIGN KEY(account_id,source_id) REFERENCES media_sources(account_id,source_id)
) STRICT;
CREATE TABLE sync_entries (
  account_id TEXT NOT NULL, entry_id TEXT NOT NULL, job_id TEXT NOT NULL,
  cloud_photo_id TEXT, cloud_master_id TEXT,
  logical_path TEXT,
  desired_favorite INTEGER NOT NULL DEFAULT 0 CHECK(desired_favorite IN (0,1)),
  desired_hidden INTEGER NOT NULL DEFAULT 0 CHECK(desired_hidden IN (0,1)),
  desired_trashed INTEGER NOT NULL DEFAULT 0 CHECK(desired_trashed IN (0,1)),
  desired_deleted INTEGER NOT NULL DEFAULT 0 CHECK(desired_deleted IN (0,1)),
  asset_date_ms INTEGER,
  upload_enrolled INTEGER NOT NULL DEFAULT 0 CHECK(upload_enrolled IN (0,1)),
  retired INTEGER NOT NULL DEFAULT 0 CHECK(retired IN (0,1)),
  retired_photo_revision TEXT, retired_master_revision TEXT,
  retired_event_ms INTEGER, retired_event_source TEXT, retired_event_id TEXT,
  dirty_kind TEXT NOT NULL DEFAULT 'clean' CHECK(dirty_kind IN ('clean','create','modify','delete')),
  metadata_version INTEGER NOT NULL DEFAULT 0 CHECK(metadata_version>=0),
  ack_metadata_version INTEGER NOT NULL DEFAULT 0 CHECK(ack_metadata_version>=0 AND ack_metadata_version<=metadata_version),
  content_version INTEGER NOT NULL DEFAULT 0 CHECK(content_version>=0),
  ack_content_version INTEGER NOT NULL DEFAULT 0 CHECK(ack_content_version>=0 AND ack_content_version<=content_version),
  delete_version INTEGER NOT NULL DEFAULT 0 CHECK(delete_version>=0),
  ack_delete_version INTEGER NOT NULL DEFAULT 0 CHECK(ack_delete_version>=0 AND ack_delete_version<=delete_version),
  metadata_event_ms INTEGER, metadata_event_source TEXT, metadata_event_id TEXT,
  content_event_ms INTEGER, content_event_source TEXT, content_event_id TEXT,
  delete_event_ms INTEGER, delete_event_source TEXT, delete_event_id TEXT,
  upload_error_code TEXT, upload_error_run_id TEXT,
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY(account_id,entry_id),
  UNIQUE(account_id,job_id,entry_id),
  FOREIGN KEY(account_id,job_id) REFERENCES jobs(account_id,job_id)
) STRICT;
CREATE UNIQUE INDEX uq_entry_photo ON sync_entries(account_id,job_id,cloud_photo_id) WHERE cloud_photo_id IS NOT NULL;
CREATE UNIQUE INDEX uq_entry_master ON sync_entries(account_id,job_id,cloud_master_id) WHERE cloud_master_id IS NOT NULL;
CREATE UNIQUE INDEX uq_entry_path ON sync_entries(account_id,job_id,logical_path) WHERE retired=0 AND logical_path IS NOT NULL;
CREATE INDEX idx_entry_dirty ON sync_entries(account_id,job_id,dirty_kind,entry_id);
CREATE TABLE asset_descriptors (
  account_id TEXT NOT NULL, asset_id TEXT NOT NULL,
  sha256_hex TEXT NOT NULL CHECK(length(sha256_hex)=64 AND sha256_hex NOT GLOB '*[^0-9a-f]*'),
  size_bytes INTEGER NOT NULL CHECK(size_bytes>0), mime_type TEXT NOT NULL,
  width INTEGER CHECK(width>0), height INTEGER CHECK(height>0),
  thumbnail_validated INTEGER NOT NULL DEFAULT 0 CHECK(thumbnail_validated IN (0,1)),
  PRIMARY KEY(account_id,asset_id),
  FOREIGN KEY(account_id) REFERENCES accounts(account_id)
) STRICT;
CREATE TABLE media_versions (
  account_id TEXT NOT NULL, entry_id TEXT NOT NULL, version_id TEXT NOT NULL,
  cloud_content_generation TEXT,
  original_relpath TEXT NOT NULL, thumbnail_relpath TEXT NOT NULL,
  original_sha256 TEXT NOT NULL CHECK(length(original_sha256)=64 AND original_sha256 NOT GLOB '*[^0-9a-f]*'),
  original_size INTEGER NOT NULL CHECK(original_size>0),
  thumbnail_sha256 TEXT NOT NULL CHECK(length(thumbnail_sha256)=64 AND thumbnail_sha256 NOT GLOB '*[^0-9a-f]*'),
  thumbnail_size INTEGER NOT NULL CHECK(thumbnail_size>0),
  original_mime TEXT NOT NULL, thumbnail_mime TEXT NOT NULL CHECK(thumbnail_mime IN ('image/jpeg','image/png')),
  width INTEGER NOT NULL CHECK(width>0), height INTEGER NOT NULL CHECK(height>0),
  orientation INTEGER NOT NULL DEFAULT 1 CHECK(orientation BETWEEN 1 AND 8),
  state TEXT NOT NULL CHECK(state IN ('prepared','published','conflict','retired','repair_required')),
  created_at_ms INTEGER NOT NULL, verified_at_ms INTEGER, retired_at_ms INTEGER, cleanup_error_code TEXT,
  CHECK(state='prepared' OR verified_at_ms IS NOT NULL),
  PRIMARY KEY(account_id,entry_id,version_id),
  FOREIGN KEY(account_id,entry_id) REFERENCES sync_entries(account_id,entry_id)
) STRICT;
CREATE TABLE media_items (
  account_id TEXT NOT NULL, entry_id TEXT NOT NULL, current_version_id TEXT NOT NULL,
  sort_time_ms INTEGER NOT NULL,
  availability TEXT NOT NULL CHECK(availability IN ('ready','repair_required')),
  PRIMARY KEY(account_id,entry_id),
  FOREIGN KEY(account_id,entry_id) REFERENCES sync_entries(account_id,entry_id),
  FOREIGN KEY(account_id,entry_id,current_version_id) REFERENCES media_versions(account_id,entry_id,version_id)
) STRICT;
CREATE INDEX idx_library_order ON media_items(account_id,sort_time_ms DESC,entry_id DESC);
CREATE INDEX idx_version_gc ON media_versions(account_id,state,retired_at_ms);
-- Rebuildable read projection; canonical truth remains entries + media_items.
CREATE TABLE library_groups (
  account_id TEXT NOT NULL, group_path TEXT NOT NULL, parent_path TEXT,
  total_count INTEGER NOT NULL DEFAULT 0 CHECK(total_count>=0),
  favorite_count INTEGER NOT NULL DEFAULT 0 CHECK(favorite_count>=0 AND favorite_count<=total_count),
  PRIMARY KEY(account_id,group_path),
  FOREIGN KEY(account_id) REFERENCES accounts(account_id),
  FOREIGN KEY(account_id,parent_path) REFERENCES library_groups(account_id,group_path)
) STRICT;
CREATE INDEX idx_group_children ON library_groups(account_id,parent_path,group_path);
CREATE TABLE library_memberships (
  account_id TEXT NOT NULL, group_path TEXT NOT NULL, entry_id TEXT NOT NULL,
  sort_time_ms INTEGER NOT NULL,
  favorite INTEGER NOT NULL CHECK(favorite IN (0,1)),
  PRIMARY KEY(account_id,group_path,entry_id),
  FOREIGN KEY(account_id,group_path) REFERENCES library_groups(account_id,group_path),
  FOREIGN KEY(account_id,entry_id) REFERENCES media_items(account_id,entry_id)
) STRICT;
CREATE INDEX idx_membership_order ON library_memberships(account_id,group_path,sort_time_ms DESC,entry_id DESC);
CREATE INDEX idx_membership_favorite_order ON library_memberships(account_id,group_path,favorite,sort_time_ms DESC,entry_id DESC);
CREATE TABLE entry_confirmed (
  account_id TEXT NOT NULL, entry_id TEXT NOT NULL,
  photo_revision TEXT NOT NULL, master_revision TEXT NOT NULL,
  cloud_content_generation TEXT NOT NULL,
  logical_path TEXT NOT NULL, favorite INTEGER NOT NULL CHECK(favorite IN (0,1)),
  hidden INTEGER NOT NULL CHECK(hidden IN (0,1)), trashed INTEGER NOT NULL CHECK(trashed IN (0,1)),
  asset_date_ms INTEGER,
  original_asset_id TEXT NOT NULL, thumbnail_asset_id TEXT NOT NULL,
  local_version_id TEXT,
  metadata_event_ms INTEGER, metadata_event_source TEXT, metadata_event_id TEXT,
  content_event_ms INTEGER, content_event_source TEXT, content_event_id TEXT,
  delete_event_ms INTEGER, delete_event_source TEXT, delete_event_id TEXT,
  PRIMARY KEY(account_id,entry_id),
  FOREIGN KEY(account_id,entry_id) REFERENCES sync_entries(account_id,entry_id),
  FOREIGN KEY(account_id,original_asset_id) REFERENCES asset_descriptors(account_id,asset_id),
  FOREIGN KEY(account_id,thumbnail_asset_id) REFERENCES asset_descriptors(account_id,asset_id),
  FOREIGN KEY(account_id,entry_id,local_version_id) REFERENCES media_versions(account_id,entry_id,version_id)
) STRICT;
CREATE TABLE source_assets (
  account_id TEXT NOT NULL, source_id TEXT NOT NULL, source_key TEXT NOT NULL,
  entry_id TEXT NOT NULL, observed_size INTEGER CHECK(observed_size>=0),
  observed_mtime_ms INTEGER, observed_platform_version TEXT,
  imported_sha256 TEXT NOT NULL CHECK(length(imported_sha256)=64),
  PRIMARY KEY(account_id,source_id,source_key),
  FOREIGN KEY(account_id,source_id) REFERENCES media_sources(account_id,source_id),
  FOREIGN KEY(account_id,entry_id) REFERENCES sync_entries(account_id,entry_id)
) STRICT;
CREATE TABLE import_batches (
  account_id TEXT NOT NULL, batch_id TEXT NOT NULL, job_id TEXT NOT NULL, source_id TEXT,
  state TEXT NOT NULL CHECK(state IN ('accepted','enumerating','preparing','completed','partial','cancelled','interrupted')),
  enumeration_complete INTEGER NOT NULL DEFAULT 0 CHECK(enumeration_complete IN (0,1)),
  allow_upload INTEGER NOT NULL CHECK(allow_upload IN (0,1)),
  config_generation INTEGER NOT NULL CHECK(config_generation>0),
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY(account_id,batch_id),
  FOREIGN KEY(account_id,job_id) REFERENCES jobs(account_id,job_id),
  FOREIGN KEY(account_id,source_id) REFERENCES media_sources(account_id,source_id)
) STRICT;
CREATE TABLE import_items (
  account_id TEXT NOT NULL, batch_id TEXT NOT NULL, item_id TEXT NOT NULL,
  source_key TEXT NOT NULL, proposed_logical_path TEXT NOT NULL,
  entry_id TEXT, version_id TEXT, staging_id TEXT,
  observed_size INTEGER CHECK(observed_size>=0), observed_mtime_ms INTEGER, observed_platform_version TEXT,
  state TEXT NOT NULL CHECK(state IN ('accepted','copying','inspecting','thumbnailing','publishing','ready','failed','cancelled','already_imported')),
  error_code TEXT,
  PRIMARY KEY(account_id,batch_id,item_id),
  UNIQUE(account_id,batch_id,source_key),
  FOREIGN KEY(account_id,batch_id) REFERENCES import_batches(account_id,batch_id),
  FOREIGN KEY(account_id,entry_id) REFERENCES sync_entries(account_id,entry_id),
  FOREIGN KEY(account_id,entry_id,version_id) REFERENCES media_versions(account_id,entry_id,version_id)
) STRICT;
CREATE TABLE record_sets (
  account_id TEXT NOT NULL, set_id TEXT NOT NULL, job_id TEXT NOT NULL,
  purpose TEXT NOT NULL CHECK(purpose IN ('receive','issued_request','issued_result','conflict')),
  PRIMARY KEY(account_id,set_id),
  UNIQUE(account_id,job_id,set_id),
  FOREIGN KEY(account_id,job_id) REFERENCES jobs(account_id,job_id)
) STRICT;
CREATE TABLE sync_records (
  account_id TEXT NOT NULL, record_row_id TEXT NOT NULL, set_id TEXT NOT NULL,
  record_name TEXT NOT NULL, record_type TEXT, revision TEXT,
  deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)),
  photo_id TEXT, master_id TEXT, logical_path TEXT, content_generation TEXT,
  PRIMARY KEY(account_id,record_row_id),
  UNIQUE(account_id,set_id,record_row_id),
  FOREIGN KEY(account_id,set_id) REFERENCES record_sets(account_id,set_id),
  CHECK(deleted=1 OR record_type IS NOT NULL)
) STRICT;
CREATE INDEX idx_record_photo ON sync_records(account_id,set_id,photo_id);
CREATE INDEX idx_record_master ON sync_records(account_id,set_id,master_id);
CREATE INDEX idx_record_identity ON sync_records(account_id,set_id,record_name,revision);
CREATE TABLE record_fields (
  account_id TEXT NOT NULL, record_row_id TEXT NOT NULL, field_name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('STRING','INT64','DOUBLE','TIMESTAMP','BYTES','REFERENCE','ASSETID','DELETE_FIELD','STRING_LIST','INT64_LIST','DOUBLE_LIST','TIMESTAMP_LIST','BYTES_LIST','REFERENCE_LIST')),
  text_value TEXT, integer_value INTEGER, real_value REAL, bytes_base64 TEXT,
  reference_record_name TEXT, reference_zone TEXT, reference_owner TEXT, reference_action TEXT,
  PRIMARY KEY(account_id,record_row_id,field_name),
  UNIQUE(account_id,record_row_id,field_name,kind),
  FOREIGN KEY(account_id,record_row_id) REFERENCES sync_records(account_id,record_row_id),
  CHECK((text_value IS NOT NULL)+(integer_value IS NOT NULL)+(real_value IS NOT NULL)+(bytes_base64 IS NOT NULL)+(reference_record_name IS NOT NULL)=CASE WHEN kind LIKE '%_LIST' OR kind IN ('ASSETID','DELETE_FIELD') THEN 0 ELSE 1 END),
  CHECK(CASE kind WHEN 'STRING' THEN text_value IS NOT NULL WHEN 'INT64' THEN integer_value IS NOT NULL WHEN 'TIMESTAMP' THEN integer_value IS NOT NULL WHEN 'DOUBLE' THEN real_value IS NOT NULL WHEN 'BYTES' THEN bytes_base64 IS NOT NULL WHEN 'REFERENCE' THEN reference_record_name IS NOT NULL ELSE 1 END),
  CHECK(kind='REFERENCE' OR (reference_zone IS NULL AND reference_owner IS NULL AND reference_action IS NULL))
) STRICT;
CREATE TABLE record_events (
  account_id TEXT NOT NULL, record_row_id TEXT NOT NULL,
  category TEXT NOT NULL CHECK(category IN ('metadata','content','delete')),
  event_time_ms INTEGER NOT NULL, event_source TEXT NOT NULL, event_id TEXT NOT NULL,
  PRIMARY KEY(account_id,record_row_id,category),
  FOREIGN KEY(account_id,record_row_id) REFERENCES sync_records(account_id,record_row_id)
) STRICT;
CREATE TABLE record_list_values (
  account_id TEXT NOT NULL, record_row_id TEXT NOT NULL, field_name TEXT NOT NULL,
  list_kind TEXT NOT NULL, position INTEGER NOT NULL CHECK(position>=0),
  item_kind TEXT NOT NULL CHECK(item_kind IN ('STRING','INT64','DOUBLE','TIMESTAMP','BYTES','REFERENCE')),
  text_value TEXT, integer_value INTEGER, real_value REAL, bytes_base64 TEXT,
  reference_record_name TEXT, reference_zone TEXT, reference_owner TEXT, reference_action TEXT,
  PRIMARY KEY(account_id,record_row_id,field_name,position),
  FOREIGN KEY(account_id,record_row_id,field_name,list_kind) REFERENCES record_fields(account_id,record_row_id,field_name,kind),
  CHECK(list_kind=item_kind||'_LIST'),
  CHECK((text_value IS NOT NULL)+(integer_value IS NOT NULL)+(real_value IS NOT NULL)+(bytes_base64 IS NOT NULL)+(reference_record_name IS NOT NULL)=1),
  CHECK(CASE item_kind WHEN 'STRING' THEN text_value IS NOT NULL WHEN 'INT64' THEN integer_value IS NOT NULL WHEN 'TIMESTAMP' THEN integer_value IS NOT NULL WHEN 'DOUBLE' THEN real_value IS NOT NULL WHEN 'BYTES' THEN bytes_base64 IS NOT NULL WHEN 'REFERENCE' THEN reference_record_name IS NOT NULL ELSE 0 END),
  CHECK(item_kind='REFERENCE' OR (reference_zone IS NULL AND reference_owner IS NULL AND reference_action IS NULL))
) STRICT;
CREATE TABLE record_assets (
  account_id TEXT NOT NULL, record_row_id TEXT NOT NULL, field_name TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'ASSETID' CHECK(kind='ASSETID'),
  asset_id TEXT NOT NULL,
  PRIMARY KEY(account_id,record_row_id,field_name),
  FOREIGN KEY(account_id,record_row_id,field_name,kind) REFERENCES record_fields(account_id,record_row_id,field_name,kind),
  FOREIGN KEY(account_id,asset_id) REFERENCES asset_descriptors(account_id,asset_id)
) STRICT;
CREATE TABLE receive_rounds (
  account_id TEXT NOT NULL, round_id TEXT NOT NULL, job_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('bootstrap','delta')),
  state TEXT NOT NULL CHECK(state IN ('created','receiving','projecting','resources_pending','applying','applied','interrupted','blocked','superseded')),
  config_generation INTEGER NOT NULL CHECK(config_generation>0),
  database_generation TEXT NOT NULL,
  input_token TEXT, snapshot_token TEXT, target_token TEXT,
  created_at_ms INTEGER NOT NULL, error_code TEXT,
  PRIMARY KEY(account_id,round_id),
  UNIQUE(account_id,round_id,job_id),
  FOREIGN KEY(account_id,job_id) REFERENCES jobs(account_id,job_id)
) STRICT;
CREATE UNIQUE INDEX uq_active_receive ON receive_rounds(account_id,job_id) WHERE state IN ('created','receiving','projecting','resources_pending','applying');
CREATE TABLE receive_streams (
  account_id TEXT NOT NULL, round_id TEXT NOT NULL, stream_id TEXT NOT NULL,
  record_type TEXT, continuation_marker TEXT,
  complete INTEGER NOT NULL DEFAULT 0 CHECK(complete IN (0,1)),
  PRIMARY KEY(account_id,round_id,stream_id),
  FOREIGN KEY(account_id,round_id) REFERENCES receive_rounds(account_id,round_id)
) STRICT;
CREATE TABLE receive_pages (
  account_id TEXT NOT NULL, round_id TEXT NOT NULL, stream_id TEXT NOT NULL,
  page_no INTEGER NOT NULL CHECK(page_no>=0), job_id TEXT NOT NULL, request_cursor_digest TEXT NOT NULL,
  request_cursor TEXT, response_cursor TEXT, target_token TEXT, set_id TEXT NOT NULL,
  PRIMARY KEY(account_id,round_id,stream_id,page_no),
  UNIQUE(account_id,round_id,stream_id,page_no,set_id),
  UNIQUE(account_id,round_id,stream_id,request_cursor_digest),
  FOREIGN KEY(account_id,round_id,job_id) REFERENCES receive_rounds(account_id,round_id,job_id),
  FOREIGN KEY(account_id,round_id,stream_id) REFERENCES receive_streams(account_id,round_id,stream_id),
  FOREIGN KEY(account_id,job_id,set_id) REFERENCES record_sets(account_id,job_id,set_id)
) STRICT;
CREATE TABLE inbox_events (
  account_id TEXT NOT NULL, event_id TEXT NOT NULL, round_id TEXT NOT NULL, stream_id TEXT NOT NULL,
  page_no INTEGER NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0), set_id TEXT NOT NULL, record_row_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','projected','blocked','superseded')), error_code TEXT,
  PRIMARY KEY(account_id,event_id), UNIQUE(account_id,round_id,stream_id,page_no,ordinal),
  FOREIGN KEY(account_id,round_id,stream_id,page_no,set_id) REFERENCES receive_pages(account_id,round_id,stream_id,page_no,set_id),
  FOREIGN KEY(account_id,set_id,record_row_id) REFERENCES sync_records(account_id,set_id,record_row_id)
) STRICT;
CREATE INDEX idx_inbox_pending ON inbox_events(account_id,round_id,state,event_id);
CREATE TABLE sync_progress (
  account_id TEXT NOT NULL, job_id TEXT NOT NULL, ingest_token TEXT, applied_token TEXT,
  PRIMARY KEY(account_id,job_id),
  FOREIGN KEY(account_id,job_id) REFERENCES jobs(account_id,job_id)
) STRICT;
CREATE TABLE runs (
  account_id TEXT NOT NULL, run_id TEXT NOT NULL, job_id TEXT NOT NULL,
  process_id TEXT NOT NULL, epoch INTEGER NOT NULL CHECK(epoch>=0),
  config_generation INTEGER NOT NULL CHECK(config_generation>0),
  trigger_kind TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('running','completed','partial','deferred','aborted','interrupted','cancelled')),
  started_at_ms INTEGER NOT NULL, finished_at_ms INTEGER, error_code TEXT,
  succeeded_count INTEGER NOT NULL DEFAULT 0 CHECK(succeeded_count>=0),
  failed_count INTEGER NOT NULL DEFAULT 0 CHECK(failed_count>=0),
  deferred_count INTEGER NOT NULL DEFAULT 0 CHECK(deferred_count>=0),
  PRIMARY KEY(account_id,run_id),
  UNIQUE(account_id,job_id,run_id),
  FOREIGN KEY(account_id,job_id) REFERENCES jobs(account_id,job_id)
) STRICT;
CREATE UNIQUE INDEX uq_active_run ON runs(account_id,job_id) WHERE state='running';
CREATE TABLE resource_work (
  account_id TEXT NOT NULL, work_id TEXT NOT NULL, job_id TEXT NOT NULL, entry_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('original','thumbnail')),
  direction TEXT NOT NULL CHECK(direction IN ('download','upload','local_repair')),
  cloud_content_generation TEXT, target_version_id TEXT, round_id TEXT,
  asset_id TEXT, upload_session_id TEXT, operation_id TEXT, staging_id TEXT,
  expected_sha256 TEXT NOT NULL CHECK(length(expected_sha256)=64),
  expected_size INTEGER NOT NULL CHECK(expected_size>0),
  state TEXT NOT NULL CHECK(state IN ('needed','transferring','verified','published','failed','interrupted','excluded_policy','superseded')),
  bytes_done INTEGER NOT NULL DEFAULT 0 CHECK(bytes_done>=0 AND bytes_done<=expected_size),
  config_generation INTEGER NOT NULL CHECK(config_generation>0), error_code TEXT,
  PRIMARY KEY(account_id,work_id),
  FOREIGN KEY(account_id,job_id,entry_id) REFERENCES sync_entries(account_id,job_id,entry_id),
  FOREIGN KEY(account_id,entry_id,target_version_id) REFERENCES media_versions(account_id,entry_id,version_id),
  FOREIGN KEY(account_id,round_id,job_id) REFERENCES receive_rounds(account_id,round_id,job_id),
  FOREIGN KEY(account_id,asset_id) REFERENCES asset_descriptors(account_id,asset_id),
  FOREIGN KEY(account_id,operation_id) REFERENCES issued_operations(account_id,operation_id)
) STRICT;
CREATE INDEX idx_resource_pending ON resource_work(account_id,job_id,state,entry_id);
CREATE TABLE issued_operations (
  account_id TEXT NOT NULL, operation_id TEXT NOT NULL, job_id TEXT NOT NULL, entry_id TEXT NOT NULL,
  issued_run_id TEXT NOT NULL, config_generation INTEGER NOT NULL CHECK(config_generation>0),
  phase TEXT NOT NULL CHECK(phase IN ('delete','modify','create')),
  state TEXT NOT NULL CHECK(state IN ('preparing_assets','prepared','dispatched','unknown','server_committed','confirmed','failed','abandoned_unissued')),
  captured_metadata_version INTEGER NOT NULL CHECK(captured_metadata_version>=0),
  captured_content_version INTEGER NOT NULL CHECK(captured_content_version>=0),
  captured_delete_version INTEGER NOT NULL CHECK(captured_delete_version>=0),
  prepared_version_id TEXT,
  request_set_id TEXT, result_set_id TEXT,
  request_finalized INTEGER NOT NULL DEFAULT 0 CHECK(request_finalized IN (0,1)),
  atomic_batch INTEGER NOT NULL DEFAULT 1 CHECK(atomic_batch=1),
  request_sha256 TEXT CHECK(length(request_sha256)=64),
  server_result_code TEXT, created_at_ms INTEGER NOT NULL,
  PRIMARY KEY(account_id,operation_id),
  UNIQUE(account_id,operation_id,request_set_id),
  UNIQUE(account_id,operation_id,result_set_id),
  CHECK(request_finalized=0 OR (request_set_id IS NOT NULL AND request_sha256 IS NOT NULL)),
  CHECK(state NOT IN ('prepared','dispatched','unknown','server_committed','confirmed') OR request_finalized=1),
  FOREIGN KEY(account_id,job_id,entry_id) REFERENCES sync_entries(account_id,job_id,entry_id),
  FOREIGN KEY(account_id,job_id,issued_run_id) REFERENCES runs(account_id,job_id,run_id),
  FOREIGN KEY(account_id,entry_id,prepared_version_id) REFERENCES media_versions(account_id,entry_id,version_id),
  FOREIGN KEY(account_id,job_id,request_set_id) REFERENCES record_sets(account_id,job_id,set_id),
  FOREIGN KEY(account_id,job_id,result_set_id) REFERENCES record_sets(account_id,job_id,set_id)
) STRICT;
CREATE UNIQUE INDEX uq_unsettled_operation ON issued_operations(account_id,entry_id) WHERE state IN ('preparing_assets','prepared','dispatched','unknown','server_committed');
CREATE TABLE issued_record_actions (
  account_id TEXT NOT NULL, operation_id TEXT NOT NULL, position INTEGER NOT NULL CHECK(position>=0),
  request_set_id TEXT NOT NULL, record_row_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('create','update','delete')),
  expected_revision TEXT,
  PRIMARY KEY(account_id,operation_id,position),
  UNIQUE(account_id,operation_id,record_row_id),
  FOREIGN KEY(account_id,operation_id,request_set_id) REFERENCES issued_operations(account_id,operation_id,request_set_id),
  FOREIGN KEY(account_id,request_set_id,record_row_id) REFERENCES sync_records(account_id,set_id,record_row_id),
  CHECK((action='create' AND expected_revision IS NULL) OR (action IN ('update','delete') AND expected_revision IS NOT NULL))
) STRICT;
CREATE TABLE issued_item_results (
  account_id TEXT NOT NULL, operation_id TEXT NOT NULL, position INTEGER NOT NULL,
  result_set_id TEXT, result_record_row_id TEXT, server_error_code TEXT,
  PRIMARY KEY(account_id,operation_id,position),
  FOREIGN KEY(account_id,operation_id,position) REFERENCES issued_record_actions(account_id,operation_id,position),
  FOREIGN KEY(account_id,operation_id,result_set_id) REFERENCES issued_operations(account_id,operation_id,result_set_id),
  FOREIGN KEY(account_id,result_set_id,result_record_row_id) REFERENCES sync_records(account_id,set_id,record_row_id),
  CHECK(result_record_row_id IS NULL OR result_set_id IS NOT NULL),
  CHECK((result_record_row_id IS NOT NULL)+(server_error_code IS NOT NULL)=1)
) STRICT;
CREATE TABLE publication_intents (
  account_id TEXT NOT NULL, publication_id TEXT NOT NULL, job_id TEXT NOT NULL, entry_id TEXT NOT NULL,
  new_version_id TEXT NOT NULL, old_version_id TEXT, round_id TEXT,
  source_kind TEXT NOT NULL CHECK(source_kind IN ('download','import','repair')),
  config_generation INTEGER NOT NULL CHECK(config_generation>0),
  captured_metadata_version INTEGER NOT NULL CHECK(captured_metadata_version>=0),
  captured_content_version INTEGER NOT NULL CHECK(captured_content_version>=0),
  captured_delete_version INTEGER NOT NULL CHECK(captured_delete_version>=0),
  state TEXT NOT NULL CHECK(state IN ('prepared','files_ready','promoted','committed','retryable','conflict_protected')),
  created_at_ms INTEGER NOT NULL, error_code TEXT,
  PRIMARY KEY(account_id,publication_id),
  FOREIGN KEY(account_id,job_id,entry_id) REFERENCES sync_entries(account_id,job_id,entry_id),
  FOREIGN KEY(account_id,entry_id,new_version_id) REFERENCES media_versions(account_id,entry_id,version_id),
  FOREIGN KEY(account_id,entry_id,old_version_id) REFERENCES media_versions(account_id,entry_id,version_id),
  FOREIGN KEY(account_id,round_id,job_id) REFERENCES receive_rounds(account_id,round_id,job_id)
) STRICT;
CREATE INDEX idx_publication_entry_state ON publication_intents(account_id,entry_id,state);
CREATE UNIQUE INDEX uq_active_publication ON publication_intents(account_id,entry_id) WHERE state IN ('prepared','files_ready','promoted','retryable');
CREATE TABLE conflicts (
  account_id TEXT NOT NULL, conflict_id TEXT NOT NULL, job_id TEXT NOT NULL, entry_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('content','delete_edit','path_identity','unsupported','publication_race')),
  state TEXT NOT NULL CHECK(state IN ('pending','automatic_resolved','protected','blocked','acknowledged')),
  local_version_id TEXT, remote_version_id TEXT, remote_set_id TEXT,
  decision TEXT CHECK(decision IN ('local_wins','remote_wins','keep_both','blocked')),
  error_code TEXT, created_at_ms INTEGER NOT NULL,
  PRIMARY KEY(account_id,conflict_id),
  FOREIGN KEY(account_id,job_id,entry_id) REFERENCES sync_entries(account_id,job_id,entry_id),
  FOREIGN KEY(account_id,entry_id,local_version_id) REFERENCES media_versions(account_id,entry_id,version_id),
  FOREIGN KEY(account_id,entry_id,remote_version_id) REFERENCES media_versions(account_id,entry_id,version_id),
  FOREIGN KEY(account_id,job_id,remote_set_id) REFERENCES record_sets(account_id,job_id,set_id)
) STRICT;
CREATE INDEX idx_conflict_entry_state ON conflicts(account_id,entry_id,state);
CREATE TABLE command_receipts (
  account_id TEXT NOT NULL, command_id TEXT NOT NULL, command_kind TEXT NOT NULL,
  input_sha256 TEXT NOT NULL CHECK(length(input_sha256)=64),
  entry_id TEXT, result_code TEXT NOT NULL, result_bool INTEGER CHECK(result_bool IN (0,1)),
  committed_revision INTEGER NOT NULL CHECK(committed_revision>=0), created_at_ms INTEGER NOT NULL,
  PRIMARY KEY(account_id,command_id),
  FOREIGN KEY(account_id) REFERENCES accounts(account_id),
  FOREIGN KEY(account_id,entry_id) REFERENCES sync_entries(account_id,entry_id)
) STRICT;
-- Actor-enforced constraints: canonical dirty derivation, safe paths, proof validation,
-- generation/phase checks, complete pair before media_items, and no stale callback ack.
-- These are not claimed to be enforced by SQL CHECK alone.
