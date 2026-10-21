//! Account-free local catalog. All SQLite work belongs to one bounded actor.
use crate::edit::EditAdjustments;
use fs2::FileExt;
use rusqlite::{Connection, OptionalExtension, params, types::Value};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, mpsc},
    thread,
};
use uuid::Uuid;

const SCHEMA: &str = include_str!("storage/local-schema.sql");
const SCHEMA_VERSION: i64 = 2;
type Job = Box<dyn FnOnce(&mut Connection) + Send>;
enum Message {
    Execute(Job),
    Close,
}

#[derive(Debug, Clone)]
pub struct LibraryInfo {
    pub library_id: String,
    pub count: u64,
    pub revision: u64,
}
#[derive(Debug, Clone)]
pub struct LocalPhoto {
    pub id: String,
    pub path: String,
    pub name: String,
    pub parent: String,
    pub size_bytes: u64,
    pub modified_ms: i64,
    pub content_version: u64,
    pub modified_ns: i64,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub favorite: bool,
    pub media_kind: String,
    pub mime_type: String,
    pub orientation: u8,
    pub capture_time_ms: Option<i64>,
    pub sort_time_ms: i64,
    pub state: String,
    pub trashed_at_ms: Option<i64>,
}
#[derive(Debug, Clone)]
pub struct AlbumInfo {
    pub path: String,
    pub name: String,
    pub count: u64,
    pub cover_media_id: Option<String>,
}
#[derive(Debug, Clone)]
pub struct LocalPage {
    pub items: Vec<LocalPhoto>,
    pub next_cursor: Option<String>,
    pub total: u64,
    pub revision: u64,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct PhotoFilter {
    pub favorites_only: bool,
    pub search: String,
    /// `all`, `name`, or `date`.
    pub search_scope: String,
    pub folder: Option<String>,
    /// `image` or `video`, when a media-type view is active.
    pub media_kind: Option<String>,
    pub trashed: bool,
}
#[derive(Serialize, Deserialize)]
struct Cursor {
    sort_time_ms: i64,
    id: String,
    filter: PhotoFilter,
}
#[derive(Debug, Clone)]
pub struct MediaInput {
    pub path: String,
    pub name: String,
    pub parent: String,
    pub size_bytes: u64,
    pub modified_ns: i64,
    pub mime_type: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub orientation: u8,
    pub capture_time_ms: Option<i64>,
}

struct Actor {
    sender: mpsc::SyncSender<Message>,
    thread: Mutex<Option<thread::JoinHandle<()>>>,
    _root_lock: File,
}
impl Drop for Actor {
    fn drop(&mut self) {
        let _ = self.sender.send(Message::Close);
        if let Ok(thread) = self.thread.get_mut()
            && let Some(handle) = thread.take()
        {
            let _ = handle.join();
        }
    }
}
#[derive(Clone)]
pub struct LocalLibrary {
    actor: Arc<Actor>,
    pub root: PathBuf,
    pub library_id: String,
}

fn error<T: std::fmt::Display>(value: T) -> String {
    format!("LocalStorage: {value}")
}
fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

impl LocalLibrary {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, String> {
        let root = root.as_ref();
        fs::create_dir_all(root).map_err(error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(root, fs::Permissions::from_mode(0o700)).map_err(error)?;
        }
        let root = root.canonicalize().map_err(error)?;
        let root_lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(root.join("engine.lock"))
            .map_err(error)?;
        root_lock
            .try_lock_exclusive()
            .map_err(|_| "LibraryAlreadyOpen".to_owned())?;
        let mut connection = Connection::open(root.join("library.sqlite")).map_err(error)?;
        connection
            .busy_timeout(std::time::Duration::from_millis(250))
            .map_err(error)?;
        connection
            .execute_batch(
                "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;",
            )
            .map_err(error)?;
        let current: i64 = connection
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .map_err(error)?;
        if current > SCHEMA_VERSION {
            return Err("SchemaTooNew".into());
        }
        if current == 0 {
            let transaction = connection.transaction().map_err(error)?;
            transaction.execute_batch(SCHEMA).map_err(error)?;
            let installation_id = Uuid::new_v4().to_string();
            let library_id = Uuid::new_v4().to_string();
            transaction
                .execute(
                    "INSERT INTO app_meta VALUES(1,?1,?2,0)",
                    params![SCHEMA_VERSION, installation_id],
                )
                .map_err(error)?;
            transaction.execute("INSERT INTO libraries(library_id,name,created_at_ms) VALUES(?1,'Local library',?2)",params![library_id,now_ms()]).map_err(error)?;
            transaction
                .execute(
                    "INSERT INTO app_settings(singleton,selected_library_id) VALUES(1,?1)",
                    [&library_id],
                )
                .map_err(error)?;
            transaction
                .execute(
                    "INSERT INTO schema_migrations VALUES(?1,?2,?3)",
                    params![
                        SCHEMA_VERSION,
                        format!("{:x}", Sha256::digest(SCHEMA.as_bytes())),
                        now_ms()
                    ],
                )
                .map_err(error)?;
            transaction
                .pragma_update(None, "user_version", SCHEMA_VERSION)
                .map_err(error)?;
            transaction.commit().map_err(error)?;
        } else if current < SCHEMA_VERSION {
            return Err("SchemaUpgradeRequired".into());
        }
        let library_id: String = connection
            .query_row(
                "SELECT selected_library_id FROM app_settings WHERE singleton=1",
                [],
                |r| r.get(0),
            )
            .map_err(error)?;
        let violation: Option<String> = connection
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
        connection
            .execute(
                "UPDATE scan_runs SET state='interrupted' WHERE state='running'",
                [],
            )
            .map_err(error)?;
        let (sender, receiver) = mpsc::sync_channel::<Message>(256);
        let worker = thread::Builder::new()
            .name("photo-local-db".into())
            .spawn(move || {
                for message in receiver {
                    match message {
                        Message::Execute(job) => job(&mut connection),
                        Message::Close => break,
                    }
                }
            })
            .map_err(error)?;
        Ok(Self {
            actor: Arc::new(Actor {
                sender,
                thread: Mutex::new(Some(worker)),
                _root_lock: root_lock,
            }),
            root,
            library_id,
        })
    }

    fn execute<R: Send + 'static>(
        &self,
        job: impl FnOnce(&mut Connection) -> Result<R, String> + Send + 'static,
    ) -> Result<R, String> {
        let (reply, result) = mpsc::sync_channel(1);
        self.actor
            .sender
            .try_send(Message::Execute(Box::new(move |connection| {
                let _ = reply.send(job(connection));
            })))
            .map_err(|e| {
                match e {
                    mpsc::TrySendError::Full(_) => "LibraryBusy",
                    mpsc::TrySendError::Disconnected(_) => "LibraryClosed",
                }
                .to_owned()
            })?;
        result.recv().map_err(|_| "LibraryClosed".to_owned())?
    }

    pub fn info(&self) -> Result<LibraryInfo, String> {
        let id = self.library_id.clone();
        self.execute(move |c| {
            c.query_row(
                "SELECT media_count,revision FROM libraries WHERE library_id=?1",
                [&id],
                |r| {
                    Ok(LibraryInfo {
                        library_id: id.clone(),
                        count: sql_u64(r, 0)?,
                        revision: sql_u64(r, 1)?,
                    })
                },
            )
            .map_err(error)
        })
    }

    pub fn add_source(&self, path: &Path) -> Result<String, String> {
        let path = path.canonicalize().map_err(error)?;
        let kind = if path.is_dir() {
            "linked_directory"
        } else if path.is_file() {
            "linked_file"
        } else {
            return Err("UnsupportedSource".into());
        };
        let path = path.to_str().ok_or("UnsupportedPathEncoding")?.to_owned();
        let library = self.library_id.clone();
        self.execute(move|c|{
            c.execute("INSERT INTO sources(library_id,source_id,root_uri,source_kind) VALUES(?1,?2,?3,?4) ON CONFLICT(library_id,root_uri) DO UPDATE SET enabled=1,availability='available'",params![library,Uuid::new_v4().to_string(),path,kind]).map_err(error)?;
            c.query_row("SELECT source_id FROM sources WHERE library_id=?1 AND root_uri=?2",params![library,path],|r|r.get(0)).map_err(error)
        })
    }

    pub fn upsert_batch(&self, source_id: String, items: Vec<MediaInput>) -> Result<usize, String> {
        if items.len() > 100 {
            return Err("BatchTooLarge".into());
        }
        let library = self.library_id.clone();
        self.execute(move|c|{
            let tx=c.transaction().map_err(error)?;let mut changed=0;let mut active_delta=0_i64;let mut favorite_delta=0_i64;
            for m in items {
                let previous:Option<(String,bool)>=tx.query_row("SELECT state,favorite FROM media WHERE library_id=?1 AND source_uri=?2",params![library,m.path],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(error)?;
                if previous.as_ref().is_none_or(|p|p.0!="active") {active_delta+=1; if previous.as_ref().is_some_and(|p|p.1){favorite_delta+=1;}}
                let size=i64::try_from(m.size_bytes).map_err(|_|"FileTooLarge")?;
                changed+=tx.execute("INSERT INTO media(library_id,media_id,source_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,media_kind,mime_type,width,height,orientation,capture_time_ms,sort_time_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,'image',?9,?10,?11,?12,?13,?14) ON CONFLICT(library_id,source_uri) DO UPDATE SET source_id=excluded.source_id,display_name=excluded.display_name,parent_uri=excluded.parent_uri,size_bytes=excluded.size_bytes,modified_ns=excluded.modified_ns,mime_type=excluded.mime_type,width=COALESCE(excluded.width,media.width),height=COALESCE(excluded.height,media.height),orientation=excluded.orientation,capture_time_ms=excluded.capture_time_ms,sort_time_ms=excluded.sort_time_ms,content_version=media.content_version+CASE WHEN media.size_bytes<>excluded.size_bytes OR media.modified_ns<>excluded.modified_ns THEN 1 ELSE 0 END,state='active',error_code=NULL,original_uri=NULL,trashed_at_ms=NULL WHERE media.size_bytes<>excluded.size_bytes OR media.modified_ns<>excluded.modified_ns OR media.source_id<>excluded.source_id OR media.state<>'active'",params![library,Uuid::new_v4().to_string(),source_id,m.path,m.name,m.parent,size,m.modified_ns,m.mime_type,m.width,m.height,m.orientation,m.capture_time_ms,m.capture_time_ms.unwrap_or(m.modified_ns/1_000_000)]).map_err(error)?;
            }
            if changed>0 {
                tx.execute("UPDATE libraries SET revision=revision+1,media_count=media_count+?2,favorite_count=favorite_count+?3 WHERE library_id=?1",params![library,active_delta,favorite_delta]).map_err(error)?;
            }
            tx.commit().map_err(error)?;Ok(changed)
        })
    }

    pub fn set_favorite(&self, media_id: String, favorite: bool) -> Result<bool, String> {
        let library = self.library_id.clone();
        self.execute(move|c|{
            let tx=c.transaction().map_err(error)?;
            let exists:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM media WHERE library_id=?1 AND media_id=?2 AND state='active')",params![library,media_id],|r|r.get(0)).map_err(error)?;
            if !exists{return Err("PhotoNotFound".into());}
            let changed=tx.execute("UPDATE media SET favorite=?3 WHERE library_id=?1 AND media_id=?2 AND favorite<>?3",params![library,media_id,favorite]).map_err(error)?>0;
            if changed{tx.execute("UPDATE libraries SET revision=revision+1,favorite_count=favorite_count+?2 WHERE library_id=?1",params![library,if favorite{1}else{-1}]).map_err(error)?;}
            tx.commit().map_err(error)?;Ok(changed)
        })
    }

    pub fn photo(&self, media_id: String) -> Result<LocalPhoto, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            c.query_row(
                "SELECT media_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,content_version,width,height,favorite,sort_time_ms,media_kind,mime_type,orientation,capture_time_ms,state,trashed_at_ms FROM media WHERE library_id=?1 AND media_id=?2 AND state IN ('active','trashed')",
                params![library, media_id],
                decode_photo,
            )
            .optional()
            .map_err(error)?
            .ok_or("PhotoNotFound".into())
        })
    }

    pub fn list_albums(&self) -> Result<Vec<AlbumInfo>, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let mut statement = c
                .prepare(
                    "SELECT m.parent_uri, COUNT(*), (
                        SELECT m2.media_id FROM media m2
                        WHERE m2.library_id=m.library_id AND m2.parent_uri=m.parent_uri
                          AND m2.state='active'
                        ORDER BY m2.sort_time_ms DESC, m2.media_id DESC LIMIT 1
                     )
                     FROM media m
                     WHERE m.library_id=?1 AND m.state='active' AND m.parent_uri<>''
                     GROUP BY m.parent_uri
                     ORDER BY MAX(m.sort_time_ms) DESC, m.parent_uri ASC",
                )
                .map_err(error)?;
            let rows = statement
                .query_map([&library], |r| {
                    let path: String = r.get(0)?;
                    let name = Path::new(&path)
                        .file_name()
                        .map(|v| v.to_string_lossy().into_owned())
                        .filter(|v| !v.is_empty())
                        .unwrap_or_else(|| path.clone());
                    Ok(AlbumInfo {
                        path,
                        name,
                        count: sql_u64(r, 1)?,
                        cover_media_id: r.get(2)?,
                    })
                })
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)?;
            Ok(rows)
        })
    }

    pub fn query(
        &self,
        filter: PhotoFilter,
        cursor: Option<String>,
        limit: u32,
    ) -> Result<LocalPage, String> {
        if limit == 0 || limit > 200 || filter.search.len() > 1024 {
            return Err("InvalidQuery".into());
        }
        let scope = if filter.search_scope.is_empty() {
            "all".to_owned()
        } else {
            filter.search_scope.clone()
        };
        if !matches!(scope.as_str(), "all" | "name" | "date") {
            return Err("InvalidSearchScope".into());
        }
        if filter
            .media_kind
            .as_deref()
            .is_some_and(|kind| !matches!(kind, "image" | "video"))
        {
            return Err("InvalidMediaKind".into());
        }
        let parsed: Option<Cursor> = cursor
            .map(|s| serde_json::from_str::<Cursor>(&s).map_err(|_| "InvalidCursor".to_owned()))
            .transpose()?;
        if parsed.as_ref().is_some_and(|c| c.filter != filter) {
            return Err("StaleCursor".into());
        }

        let library = self.library_id.clone();
        self.execute(move |c| {
            let state = if filter.trashed { "trashed" } else { "active" };
            let mut clause = "library_id=? AND state=?".to_owned();
            let mut values = vec![Value::Text(library.clone()), Value::Text(state.to_owned())];
            if filter.favorites_only {
                clause.push_str(" AND favorite=1");
            }
            if !filter.search.is_empty() {
                if scope == "date" {
                    clause.push_str(
                        " AND substr(datetime(sort_time_ms/1000,'unixepoch','localtime'),1,10) LIKE ?",
                    );
                } else {
                    clause.push_str(" AND instr(lower(display_name),lower(?))>0");
                }
                values.push(Value::Text(filter.search.clone()));
            }
            if let Some(folder) = &filter.folder {
                clause.push_str(" AND parent_uri=?");
                values.push(Value::Text(folder.clone()));
            }
            if let Some(kind) = &filter.media_kind {
                clause.push_str(" AND media_kind=?");
                values.push(Value::Text(kind.clone()));
            }

            let default_filter = state == "active"
                && !filter.favorites_only
                && filter.search.is_empty()
                && filter.folder.is_none()
                && filter.media_kind.is_none();
            let total: i64 = if default_filter {
                c.query_row(
                    "SELECT media_count FROM libraries WHERE library_id=?1",
                    [&library],
                    |r| r.get(0),
                )
                .map_err(error)?
            } else {
                c.query_row(
                    &format!("SELECT COUNT(*) FROM media WHERE {clause}"),
                    rusqlite::params_from_iter(values.iter()),
                    |r| r.get(0),
                )
                .map_err(error)?
            };

            if let Some(cursor) = parsed {
                clause.push_str(" AND (sort_time_ms,media_id)<(?,?)");
                values.push(Value::Integer(cursor.sort_time_ms));
                values.push(Value::Text(cursor.id));
            }
            values.push(Value::Integer(i64::from(limit) + 1));
            let mut statement = c
                .prepare(&format!(
                    "SELECT media_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,content_version,width,height,favorite,sort_time_ms,media_kind,mime_type,orientation,capture_time_ms,state,trashed_at_ms FROM media WHERE {clause} ORDER BY sort_time_ms DESC,media_id DESC LIMIT ?"
                ))
                .map_err(error)?;
            let rows = statement
                .query_map(rusqlite::params_from_iter(values.iter()), |r| {
                    Ok((decode_photo(r)?, r.get::<_, i64>(10)?))
                })
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)?;
            let more = rows.len() > limit as usize;
            let mut rows = rows;
            rows.truncate(limit as usize);
            let next_cursor = if more {
                rows.last()
                    .map(|(p, time)| {
                        serde_json::to_string(&Cursor {
                            sort_time_ms: *time,
                            id: p.id.clone(),
                            filter: filter.clone(),
                        })
                        .map_err(error)
                    })
                    .transpose()?
            } else {
                None
            };
            let revision: u64 = c
                .query_row(
                    "SELECT revision FROM libraries WHERE library_id=?1",
                    [&library],
                    |r| sql_u64(r, 0),
                )
                .map_err(error)?;
            Ok(LocalPage {
                items: rows.into_iter().map(|r| r.0).collect(),
                next_cursor,
                total: total as u64,
                revision,
            })
        })
    }

    pub fn trash_media(&self, media_ids: Vec<String>) -> Result<u64, String> {
        let library = self.library_id.clone();
        let trash_dir = self.root.join("trash").join("files");
        self.execute(move |c| {
            fs::create_dir_all(&trash_dir).map_err(error)?;
            let tx = c.transaction().map_err(error)?;
            let mut moved = 0_u64;
            let mut favorite_delta = 0_i64;
            for media_id in media_ids {
                let row = tx
                    .query_row(
                        "SELECT source_uri,display_name,favorite,state FROM media WHERE library_id=?1 AND media_id=?2",
                        params![library, media_id],
                        |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, bool>(2)?, r.get::<_, String>(3)?)),
                    )
                    .optional()
                    .map_err(error)?;
                let Some((source_uri, display_name, favorite, state)) = row else {
                    continue;
                };
                if state != "active" {
                    continue;
                }
                let source = PathBuf::from(&source_uri);
                if !source.is_file() {
                    return Err("SourceUnavailable".into());
                }
                let destination = unique_destination(&trash_dir, &display_name)?;
                move_file(&source, &destination)?;
                let parent = destination
                    .parent()
                    .and_then(Path::to_str)
                    .ok_or("UnsupportedPathEncoding")?;
                let destination_uri = destination
                    .to_str()
                    .ok_or("UnsupportedPathEncoding")?;
                tx.execute(
                    "UPDATE media SET original_uri=source_uri,source_uri=?3,parent_uri=?4,state='trashed',trashed_at_ms=?5 WHERE library_id=?1 AND media_id=?2",
                    params![library, media_id, destination_uri, parent, now_ms()],
                )
                .map_err(error)?;
                moved += 1;
                if favorite {
                    favorite_delta += 1;
                }
            }
            if moved > 0 {
                tx.execute(
                    "UPDATE libraries SET revision=revision+1,media_count=media_count-?2,favorite_count=favorite_count-?3 WHERE library_id=?1",
                    params![library, moved as i64, favorite_delta],
                )
                .map_err(error)?;
            }
            tx.commit().map_err(error)?;
            Ok(moved)
        })
    }

    pub fn restore_media(&self, media_ids: Vec<String>) -> Result<u64, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            let mut restored = 0_u64;
            let mut favorite_delta = 0_i64;
            for media_id in media_ids {
                let row = tx
                    .query_row(
                        "SELECT source_uri,original_uri,display_name,favorite,state FROM media WHERE library_id=?1 AND media_id=?2",
                        params![library, media_id],
                        |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, String>(2)?, r.get::<_, bool>(3)?, r.get::<_, String>(4)?)),
                    )
                    .optional()
                    .map_err(error)?;
                let Some((trash_uri, original_uri, display_name, favorite, state)) = row else {
                    continue;
                };
                if state != "trashed" {
                    continue;
                }
                let Some(original_uri) = original_uri else {
                    return Err("RestoreTargetMissing".into());
                };
                let source = PathBuf::from(&trash_uri);
                let original = PathBuf::from(&original_uri);
                let parent = original.parent().ok_or("RestoreTargetMissing")?;
                fs::create_dir_all(parent).map_err(error)?;
                let destination = if original.exists() {
                    unique_destination(parent, &display_name)?
                } else {
                    original
                };
                move_file(&source, &destination)?;
                let parent_uri = destination
                    .parent()
                    .and_then(Path::to_str)
                    .ok_or("UnsupportedPathEncoding")?;
                let destination_uri = destination
                    .to_str()
                    .ok_or("UnsupportedPathEncoding")?;
                tx.execute(
                    "UPDATE media SET source_uri=?3,parent_uri=?4,state='active',original_uri=NULL,trashed_at_ms=NULL WHERE library_id=?1 AND media_id=?2",
                    params![library, media_id, destination_uri, parent_uri],
                )
                .map_err(error)?;
                restored += 1;
                if favorite {
                    favorite_delta += 1;
                }
            }
            if restored > 0 {
                tx.execute(
                    "UPDATE libraries SET revision=revision+1,media_count=media_count+?2,favorite_count=favorite_count+?3 WHERE library_id=?1",
                    params![library, restored as i64, favorite_delta],
                )
                .map_err(error)?;
            }
            tx.commit().map_err(error)?;
            Ok(restored)
        })
    }

    pub fn purge_media(&self, media_ids: Vec<String>) -> Result<u64, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            let mut purged = 0_u64;
            for media_id in media_ids {
                let row = tx
                    .query_row(
                        "SELECT source_uri,state FROM media WHERE library_id=?1 AND media_id=?2",
                        params![library, media_id],
                        |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
                    )
                    .optional()
                    .map_err(error)?;
                let Some((source_uri, state)) = row else {
                    continue;
                };
                if state != "trashed" {
                    return Err("PhotoNotTrashed".into());
                }
                let source = PathBuf::from(&source_uri);
                if source.exists() {
                    fs::remove_file(&source).map_err(error)?;
                }
                tx.execute(
                    "DELETE FROM thumbnails WHERE library_id=?1 AND media_id=?2",
                    params![library, media_id],
                )
                .map_err(error)?;
                tx.execute(
                    "DELETE FROM album_members WHERE library_id=?1 AND media_id=?2",
                    params![library, media_id],
                )
                .map_err(error)?;
                tx.execute(
                    "DELETE FROM file_operations WHERE library_id=?1 AND media_id=?2",
                    params![library, media_id],
                )
                .map_err(error)?;
                tx.execute(
                    "DELETE FROM media WHERE library_id=?1 AND media_id=?2",
                    params![library, media_id],
                )
                .map_err(error)?;
                purged += 1;
            }
            if purged > 0 {
                tx.execute(
                    "UPDATE libraries SET revision=revision+1 WHERE library_id=?1",
                    [&library],
                )
                .map_err(error)?;
            }
            tx.commit().map_err(error)?;
            Ok(purged)
        })
    }

    pub fn empty_trash(&self) -> Result<u64, String> {
        let library = self.library_id.clone();
        let ids = self.execute({
            let library = library.clone();
            move |c| {
                let mut statement = c
                    .prepare("SELECT media_id FROM media WHERE library_id=?1 AND state='trashed'")
                    .map_err(error)?;
                let rows = statement
                    .query_map([&library], |r| r.get::<_, String>(0))
                    .map_err(error)?
                    .collect::<rusqlite::Result<Vec<_>>>()
                    .map_err(error)?;
                Ok(rows)
            }
        })?;
        if ids.is_empty() {
            return Ok(0);
        }
        self.purge_media(ids)
    }

    pub fn add_to_album(
        &self,
        media_ids: Vec<String>,
        target_folder: String,
        move_files: bool,
    ) -> Result<u64, String> {
        let library = self.library_id.clone();
        let target = PathBuf::from(target_folder).canonicalize().map_err(error)?;
        if !target.is_dir() {
            return Err("AlbumTargetUnavailable".into());
        }
        self.execute(move |c| {
            let target_uri = target.to_str().ok_or("UnsupportedPathEncoding")?;
            c.execute(
                "INSERT INTO sources(library_id,source_id,root_uri,source_kind) VALUES(?1,?2,?3,'linked_directory') ON CONFLICT(library_id,root_uri) DO UPDATE SET enabled=1,availability='available'",
                params![library, Uuid::new_v4().to_string(), target_uri],
            )
            .map_err(error)?;
            let target_source: String = c
                .query_row(
                    "SELECT source_id FROM sources WHERE library_id=?1 AND root_uri=?2",
                    params![library, target_uri],
                    |r| r.get(0),
                )
                .map_err(error)?;
            let tx = c.transaction().map_err(error)?;
            let mut changed = 0_u64;
            for media_id in media_ids {
                let row = tx
                    .query_row(
                        "SELECT source_uri,display_name,size_bytes,modified_ns,content_version,width,height,orientation,capture_time_ms,sort_time_ms,media_kind,mime_type,favorite,parent_uri,state FROM media WHERE library_id=?1 AND media_id=?2",
                        params![library, media_id],
                        |r| Ok((
                            r.get::<_, String>(0)?, r.get::<_, String>(1)?, sql_u64(r, 2)?,
                            r.get::<_, i64>(3)?, sql_u64(r, 4)?, r.get::<_, Option<u32>>(5)?,
                            r.get::<_, Option<u32>>(6)?, r.get::<_, u8>(7)?,
                            r.get::<_, Option<i64>>(8)?, r.get::<_, i64>(9)?,
                            r.get::<_, String>(10)?, r.get::<_, String>(11)?,
                            r.get::<_, bool>(12)?, r.get::<_, String>(13)?, r.get::<_, String>(14)?,
                        )),
                    )
                    .optional()
                    .map_err(error)?;
                let Some((source_uri, display_name, size_bytes, modified_ns, content_version, width, height, orientation, capture_time_ms, sort_time_ms, media_kind, mime_type, favorite, parent_uri, state)) = row else {
                    continue;
                };
                if state != "active" {
                    continue;
                }
                if move_files && parent_uri == target_uri {
                    continue;
                }
                let source = PathBuf::from(&source_uri);
                if !source.is_file() {
                    continue;
                }
                let destination = unique_destination(&target, &display_name)?;
                if move_files {
                    move_file(&source, &destination)?;
                } else {
                    copy_file(&source, &destination)?;
                }
                let destination_uri = destination
                    .to_str()
                    .ok_or("UnsupportedPathEncoding")?;
                let destination_name = destination
                    .file_name()
                    .and_then(|v| v.to_str())
                    .ok_or("UnsupportedPathEncoding")?;
                if move_files {
                    tx.execute(
                        "UPDATE media SET source_id=?3,source_uri=?4,display_name=?5,parent_uri=?6 WHERE library_id=?1 AND media_id=?2",
                        params![library, media_id, target_source, destination_uri, destination_name, target_uri],
                    )
                    .map_err(error)?;
                } else {
                    let size = i64::try_from(size_bytes).map_err(|_| "FileTooLarge")?;
                    let content_version = i64::try_from(content_version).map_err(|_| "VersionOutOfRange")?;
                    tx.execute(
                        "INSERT INTO media(library_id,media_id,source_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,content_version,media_kind,mime_type,width,height,orientation,capture_time_ms,sort_time_ms,favorite,state) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,'active')",
                        params![
                            library,
                            Uuid::new_v4().to_string(),
                            target_source,
                            destination_uri,
                            destination_name,
                            target_uri,
                            size,
                            modified_ns,
                            content_version,
                            media_kind,
                            mime_type,
                            width,
                            height,
                            orientation,
                            capture_time_ms,
                            sort_time_ms,
                            favorite,
                        ],
                    )
                    .map_err(error)?;
                }
                changed += 1;
            }
            if changed > 0 {
                let delta = if move_files { 0_i64 } else { changed as i64 };
                let favorite_delta = if move_files { 0_i64 } else { 0_i64 };
                tx.execute(
                    "UPDATE libraries SET revision=revision+1,media_count=media_count+?2,favorite_count=favorite_count+?3 WHERE library_id=?1",
                    params![library, delta, favorite_delta],
                )
                .map_err(error)?;
            }
            tx.commit().map_err(error)?;
            Ok(changed)
        })
    }

    pub fn rename_media(&self, media_id: String, name: String) -> Result<LocalPhoto, String> {
        let library = self.library_id.clone();
        let requested = name.trim().to_owned();
        if requested.is_empty() || requested.contains('/') || requested.contains('\\') {
            return Err("InvalidFileName".into());
        }
        self.execute(move |c| {
            let row = c
                .query_row(
                    "SELECT source_uri FROM media WHERE library_id=?1 AND media_id=?2 AND state='active'",
                    params![library, media_id],
                    |r| r.get::<_, String>(0),
                )
                .optional()
                .map_err(error)?;
            let Some(source_uri) = row else {
                return Err("PhotoNotFound".into());
            };
            let source = PathBuf::from(&source_uri);
            let parent = source.parent().ok_or("SourceUnavailable")?;
            let destination = unique_destination(parent, &requested)?;
            fs::rename(&source, &destination).map_err(error)?;
            let parent_uri = parent.to_str().ok_or("UnsupportedPathEncoding")?;
            let destination_uri = destination
                .to_str()
                .ok_or("UnsupportedPathEncoding")?;
            let display_name = destination
                .file_name()
                .and_then(|v| v.to_str())
                .ok_or("UnsupportedPathEncoding")?;
            let tx = c.transaction().map_err(error)?;
            tx.execute(
                "UPDATE media SET source_uri=?3,display_name=?4,parent_uri=?5 WHERE library_id=?1 AND media_id=?2",
                params![library, media_id, destination_uri, display_name, parent_uri],
            )
            .map_err(error)?;
            tx.execute(
                "UPDATE libraries SET revision=revision+1 WHERE library_id=?1",
                [&library],
            )
            .map_err(error)?;
            tx.commit().map_err(error)?;
            c.query_row(
                "SELECT media_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,content_version,width,height,favorite,sort_time_ms,media_kind,mime_type,orientation,capture_time_ms,state,trashed_at_ms FROM media WHERE library_id=?1 AND media_id=?2",
                params![library, media_id],
                decode_photo,
            )
            .map_err(error)
        })
    }

    /// Apply an editor adjustment set and persist the result either as a new
    /// sibling file (`save_copy`) or over the original, keeping a private
    /// backup outside the scanned tree so nothing is lost irrecoverably.
    pub fn save_edited(
        &self,
        media_id: String,
        adjustments: EditAdjustments,
        save_copy: bool,
    ) -> Result<LocalPhoto, String> {
        if adjustments.is_identity() {
            return Err("NoEdits".into());
        }
        let library = self.library_id.clone();
        let root = self.root.clone();
        self.execute(move |c| {
            let row = c
                .query_row(
                    "SELECT source_uri,source_id,content_version,media_kind,capture_time_ms FROM media WHERE library_id=?1 AND media_id=?2 AND state='active'",
                    params![library, media_id],
                    |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, String>(1)?,
                            r.get::<_, i64>(2)?,
                            r.get::<_, String>(3)?,
                            r.get::<_, Option<i64>>(4)?,
                        ))
                    },
                )
                .optional()
                .map_err(error)?;
            let Some((source_uri, source_id, version, media_kind, capture_time_ms)) = row else {
                return Err("PhotoNotFound".into());
            };
            if media_kind != "image" {
                return Err("UnsupportedEdit".into());
            }
            let source = PathBuf::from(&source_uri);
            if !source.is_file() {
                return Err("SourceUnavailable".into());
            }
            let (format, mime) =
                crate::media::format_for_path(&source).ok_or("UnsupportedFormat")?;
            let decoded = image::open(&source).map_err(|_| "DecodeFailed".to_owned())?;
            let rendered = crate::edit::render(&decoded, adjustments);
            let encoded = crate::edit::encode(&rendered, format)?;
            let width = rendered.width();
            let height = rendered.height();
            let size = encoded.len() as i64;
            let parent = source.parent().ok_or("SourceUnavailable")?.to_path_buf();
            let extension = source
                .extension()
                .and_then(|v| v.to_str())
                .ok_or("UnsupportedPathEncoding")?;
            let modified_ns = now_ms().saturating_mul(1_000_000);

            if save_copy {
                let stem = source
                    .file_stem()
                    .and_then(|v| v.to_str())
                    .ok_or("UnsupportedPathEncoding")?;
                let destination =
                    unique_destination(&parent, &format!("{stem} edited.{extension}"))?;
                fs::write(&destination, &encoded).map_err(error)?;
                let destination_uri = destination
                    .to_str()
                    .ok_or("UnsupportedPathEncoding")?
                    .to_owned();
                let destination_parent = destination
                    .parent()
                    .and_then(Path::to_str)
                    .ok_or("UnsupportedPathEncoding")?
                    .to_owned();
                let name = destination
                    .file_name()
                    .and_then(|v| v.to_str())
                    .ok_or("UnsupportedPathEncoding")?
                    .to_owned();
                let new_id = Uuid::new_v4().to_string();
                let tx = c.transaction().map_err(error)?;
                tx.execute(
                    "INSERT INTO media(library_id,media_id,source_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,content_version,media_kind,mime_type,width,height,orientation,capture_time_ms,sort_time_ms,favorite,state) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,1,'image',?9,?10,?11,1,?12,?13,0,'active')",
                    params![
                        library,
                        new_id,
                        source_id,
                        destination_uri,
                        name,
                        destination_parent,
                        size,
                        modified_ns,
                        mime,
                        width,
                        height,
                        capture_time_ms,
                        modified_ns / 1_000_000
                    ],
                )
                .map_err(error)?;
                tx.execute(
                    "UPDATE libraries SET revision=revision+1,media_count=media_count+1 WHERE library_id=?1",
                    [&library],
                )
                .map_err(error)?;
                tx.commit().map_err(error)?;
                return c
                    .query_row(
                        PHOTO_COLUMNS,
                        params![library, new_id],
                        decode_photo,
                    )
                    .map_err(error);
            }

            let backup_dir = root.join("backups").join(&media_id);
            fs::create_dir_all(&backup_dir).map_err(error)?;
            let backup = backup_dir.join(format!("v{version}.{extension}"));
            if !backup.exists() {
                fs::copy(&source, &backup).map_err(error)?;
            }
            let temp = parent.join(format!(".{media_id}.tmp-{}", Uuid::new_v4()));
            fs::write(&temp, &encoded).map_err(error)?;
            fs::rename(&temp, &source).map_err(error)?;
            let tx = c.transaction().map_err(error)?;
            tx.execute(
                "UPDATE media SET size_bytes=?3,modified_ns=?4,content_version=content_version+1,width=?5,height=?6,orientation=1 WHERE library_id=?1 AND media_id=?2",
                params![library, media_id, size, modified_ns, width, height],
            )
            .map_err(error)?;
            tx.execute(
                "DELETE FROM thumbnails WHERE library_id=?1 AND media_id=?2",
                params![library, media_id],
            )
            .map_err(error)?;
            tx.execute(
                "UPDATE libraries SET revision=revision+1 WHERE library_id=?1",
                [&library],
            )
            .map_err(error)?;
            tx.commit().map_err(error)?;
            let _ = fs::remove_dir_all(root.join("cache").join(&media_id));
            c.query_row(PHOTO_COLUMNS, params![library, media_id], decode_photo)
                .map_err(error)
        })
    }
}

const PHOTO_COLUMNS: &str = "SELECT media_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,content_version,width,height,favorite,sort_time_ms,media_kind,mime_type,orientation,capture_time_ms,state,trashed_at_ms FROM media WHERE library_id=?1 AND media_id=?2";

fn decode_photo(row: &rusqlite::Row<'_>) -> rusqlite::Result<LocalPhoto> {
    let ns: i64 = row.get(5)?;
    Ok(LocalPhoto {
        id: row.get(0)?,
        path: row.get(1)?,
        name: row.get(2)?,
        parent: row.get(3)?,
        size_bytes: sql_u64(row, 4)?,
        modified_ms: ns / 1_000_000,
        modified_ns: ns,
        content_version: sql_u64(row, 6)?,
        width: row.get(7)?,
        height: row.get(8)?,
        favorite: row.get(9)?,
        sort_time_ms: row.get(10)?,
        media_kind: row.get(11)?,
        mime_type: row.get(12)?,
        orientation: row.get(13)?,
        capture_time_ms: row.get(14)?,
        state: row.get(15)?,
        trashed_at_ms: row.get(16)?,
    })
}

fn sql_u64(row: &rusqlite::Row<'_>, column: usize) -> rusqlite::Result<u64> {
    let value: i64 = row.get(column)?;
    u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(column, value))
}

fn unique_destination(folder: &Path, requested: &str) -> Result<PathBuf, String> {
    let requested = Path::new(requested);
    let file_name = requested
        .file_name()
        .and_then(|v| v.to_str())
        .filter(|v| !v.is_empty())
        .ok_or("InvalidFileName")?;
    let requested_path = Path::new(file_name);
    let stem = requested_path
        .file_stem()
        .and_then(|v| v.to_str())
        .filter(|v| !v.is_empty())
        .unwrap_or("photo");
    let extension = requested_path.extension().and_then(|v| v.to_str());
    for index in 0..=9999_u32 {
        let name = if index == 0 {
            file_name.to_owned()
        } else if let Some(extension) = extension {
            format!("{stem}_{index}.{extension}")
        } else {
            format!("{stem}_{index}")
        };
        let candidate = folder.join(name);
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err("NoAvailableFileName".into())
}

fn copy_file(source: &Path, destination: &Path) -> Result<(), String> {
    let mut input = File::open(source).map_err(error)?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)
        .map_err(error)?;
    let result = std::io::copy(&mut input, &mut output);
    if let Err(copy_error) = result {
        drop(output);
        let _ = fs::remove_file(destination);
        return Err(error(copy_error));
    }
    output.sync_all().map_err(error)?;
    fs::set_permissions(destination, input.metadata().map_err(error)?.permissions()).map_err(error)
}

fn move_file(source: &Path, destination: &Path) -> Result<(), String> {
    match fs::rename(source, destination) {
        Ok(()) => Ok(()),
        Err(rename_error) if rename_error.raw_os_error() == Some(18) => {
            copy_file(source, destination)?;
            fs::remove_file(source).map_err(error)
        }
        Err(rename_error) => Err(error(rename_error)),
    }
}
