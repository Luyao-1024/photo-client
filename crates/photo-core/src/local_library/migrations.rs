//! Additive catalog upgrades. Originals and catalog identities stay intact.
use super::{
    ACCOUNT_SCHEMA, CLOUD_SCHEMA, EXTENSIONS, METADATA_SCHEMA, SCHEMA, SCHEMA_VERSION,
    SYNC_OBLIGATION_SCHEMA, error, now_ms,
};
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};
use std::{fs, path::Path};
use uuid::Uuid;

fn has_column(connection: &Connection, table: &str, column: &str) -> Result<bool, String> {
    let mut statement = connection
        .prepare("SELECT 1 FROM pragma_table_info(?1) WHERE name=?2")
        .map_err(error)?;
    Ok(statement
        .query_row(params![table, column], |_| Ok(()))
        .optional()
        .map_err(error)?
        .is_some())
}

fn backup(connection: &Connection, root: &Path, version: i64) -> Result<(), String> {
    let directory = root.join("backups");
    fs::create_dir_all(&directory).map_err(error)?;
    let path = directory.join(format!(
        "library-v{version}-before-v{SCHEMA_VERSION}-{}-{}.sqlite",
        now_ms(),
        Uuid::new_v4()
    ));
    // SQLite's backup API includes committed WAL content in one consistent file.
    connection
        .backup(rusqlite::MAIN_DB, &path, None)
        .map_err(error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(error)?;
    }
    fs::File::open(&path)
        .and_then(|file| file.sync_all())
        .map_err(error)?;
    fs::File::open(&directory)
        .and_then(|file| file.sync_all())
        .map_err(error)?;
    Ok(())
}

pub(super) fn upgrade(
    connection: &mut Connection,
    root: &Path,
    version: i64,
) -> Result<(), String> {
    if !matches!(version, 1 | 2 | 3 | 4 | 5 | 6) {
        return Err("SchemaUpgradeRequired".into());
    }
    backup(connection, root, version)?;
    let tx = connection.transaction().map_err(error)?;
    // v1 lacks the two fields introduced for system-trash bookkeeping.
    // Check both fields so an already extended v1 database is also accepted.
    for (column, declaration) in [("original_uri", "TEXT"), ("trashed_at_ms", "INTEGER")] {
        if !has_column(&tx, "media", column)? {
            tx.execute_batch(&format!(
                "ALTER TABLE media ADD COLUMN {column} {declaration}"
            ))
            .map_err(error)?;
        }
    }
    tx.execute_batch(EXTENSIONS).map_err(error)?;
    tx.execute_batch(CLOUD_SCHEMA).map_err(error)?;
    if version < 5 {
        tx.execute_batch(METADATA_SCHEMA).map_err(error)?;
    }
    if !has_column(&tx, "cloud_accounts", "is_active")? {
        tx.execute_batch(ACCOUNT_SCHEMA).map_err(error)?;
    }
    if !has_column(&tx, "media_details", "hdr")? {
        tx.execute_batch("ALTER TABLE media_details ADD COLUMN hdr INTEGER NOT NULL DEFAULT 0")
            .map_err(error)?;
    }
    if !has_column(&tx, "media_sync_state", "content_version")? {
        tx.execute_batch(SYNC_OBLIGATION_SCHEMA).map_err(error)?;
    }

    let (theme, glass, locale): (String, String, String) = tx
        .query_row(
            "SELECT theme,glass_mode,locale FROM app_settings WHERE singleton=1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .map_err(error)?;
    let glass = match glass.as_str() {
        "full" | "reduced" => glass.as_str(),
        _ => "auto",
    };
    let language = locale.split(['-', '_']).next().unwrap_or("");
    let mut preferences = vec![("theme", theme.as_str()), ("glassMode", glass)];
    if matches!(language, "zh" | "en") {
        preferences.push(("locale", language));
    }
    for (key, value) in preferences {
        tx.execute(
            "INSERT INTO local_preferences(key,value) VALUES(?1,?2) ON CONFLICT(key) DO NOTHING",
            params![key, serde_json::to_string(value).map_err(error)?],
        )
        .map_err(error)?;
    }
    let violation: Option<String> = tx
        .query_row(
            "SELECT \"table\" FROM pragma_foreign_key_check LIMIT 1",
            [],
            |r| r.get(0),
        )
        .optional()
        .map_err(error)?;
    if violation.is_some() {
        return Err("CatalogIntegrityError".into());
    }
    tx.execute("UPDATE app_meta SET schema_version=?1", [SCHEMA_VERSION])
        .map_err(error)?;
    tx.execute(
        "INSERT OR REPLACE INTO schema_migrations VALUES(?1,?2,?3)",
        params![
            SCHEMA_VERSION,
            format!(
                "{:x}",
                Sha256::digest(
                    [
                        SCHEMA,
                        EXTENSIONS,
                        CLOUD_SCHEMA,
                        METADATA_SCHEMA,
                        ACCOUNT_SCHEMA,
                        SYNC_OBLIGATION_SCHEMA
                    ]
                    .concat()
                    .as_bytes()
                )
            ),
            now_ms()
        ],
    )
    .map_err(error)?;
    tx.pragma_update(None, "user_version", SCHEMA_VERSION)
        .map_err(error)?;
    tx.commit().map_err(error)
}
