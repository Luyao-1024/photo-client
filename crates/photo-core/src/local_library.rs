//! Account-free local catalog. All SQLite work belongs to one bounded actor.
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
const SCHEMA_VERSION: i64 = 1;
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
    pub folder: Option<String>,
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
                changed+=tx.execute("INSERT INTO media(library_id,media_id,source_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,media_kind,mime_type,width,height,orientation,capture_time_ms,sort_time_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,'image',?9,?10,?11,?12,?13,?14) ON CONFLICT(library_id,source_uri) DO UPDATE SET source_id=excluded.source_id,display_name=excluded.display_name,parent_uri=excluded.parent_uri,size_bytes=excluded.size_bytes,modified_ns=excluded.modified_ns,mime_type=excluded.mime_type,width=COALESCE(excluded.width,media.width),height=COALESCE(excluded.height,media.height),orientation=excluded.orientation,capture_time_ms=excluded.capture_time_ms,sort_time_ms=excluded.sort_time_ms,content_version=media.content_version+CASE WHEN media.size_bytes<>excluded.size_bytes OR media.modified_ns<>excluded.modified_ns THEN 1 ELSE 0 END,state='active',error_code=NULL WHERE media.size_bytes<>excluded.size_bytes OR media.modified_ns<>excluded.modified_ns OR media.source_id<>excluded.source_id OR media.state<>'active'",params![library,Uuid::new_v4().to_string(),source_id,m.path,m.name,m.parent,size,m.modified_ns,m.mime_type,m.width,m.height,m.orientation,m.capture_time_ms,m.capture_time_ms.unwrap_or(m.modified_ns/1_000_000)]).map_err(error)?;
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
        self.execute(move|c|c.query_row("SELECT media_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,content_version,width,height,favorite FROM media WHERE library_id=?1 AND media_id=?2 AND state='active'",params![library,media_id],decode_photo).optional().map_err(error)?.ok_or("PhotoNotFound".into()))
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
        let parsed: Option<Cursor> = cursor
            .map(|s| serde_json::from_str::<Cursor>(&s).map_err(|_| "InvalidCursor".to_owned()))
            .transpose()?;
        if parsed.as_ref().is_some_and(|c| c.filter != filter) {
            return Err("StaleCursor".into());
        }
        let library = self.library_id.clone();
        self.execute(move|c|{
            let mut clause="library_id=? AND state='active'".to_owned();let mut values=vec![Value::Text(library.clone())];
            if filter.favorites_only{clause.push_str(" AND favorite=1");}
            if !filter.search.is_empty(){clause.push_str(" AND instr(lower(display_name),lower(?))>0");values.push(Value::Text(filter.search.clone()));}
            if let Some(folder)=&filter.folder{clause.push_str(" AND parent_uri=?");values.push(Value::Text(folder.clone()));}
            let total:i64=if filter.search.is_empty()&&filter.folder.is_none(){c.query_row(if filter.favorites_only{"SELECT favorite_count FROM libraries WHERE library_id=?1"}else{"SELECT media_count FROM libraries WHERE library_id=?1"},[&library],|r|r.get(0)).map_err(error)?}else{c.query_row(&format!("SELECT COUNT(*) FROM media WHERE {clause}"),rusqlite::params_from_iter(values.iter()),|r|r.get(0)).map_err(error)?};
            if let Some(cursor)=parsed{clause.push_str(" AND (sort_time_ms,media_id)<(?,?)");values.push(Value::Integer(cursor.sort_time_ms));values.push(Value::Text(cursor.id));}
            values.push(Value::Integer(i64::from(limit)+1));
            let mut statement=c.prepare(&format!("SELECT media_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,content_version,width,height,favorite,sort_time_ms FROM media WHERE {clause} ORDER BY sort_time_ms DESC,media_id DESC LIMIT ?")).map_err(error)?;
            let rows=statement.query_map(rusqlite::params_from_iter(values.iter()),|r|Ok((decode_photo(r)?,r.get::<_,i64>(10)?))).map_err(error)?.collect::<rusqlite::Result<Vec<_>>>().map_err(error)?;
            let more=rows.len()>limit as usize;let mut rows=rows;rows.truncate(limit as usize);
            let next_cursor=if more {rows.last().map(|(p,time)|serde_json::to_string(&Cursor{sort_time_ms:*time,id:p.id.clone(),filter:filter.clone()}).map_err(error)).transpose()?}else{None};
            let revision:u64=c.query_row("SELECT revision FROM libraries WHERE library_id=?1",[&library],|r|sql_u64(r,0)).map_err(error)?;
            Ok(LocalPage{items:rows.into_iter().map(|r|r.0).collect(),next_cursor,total:total as u64,revision})
        })
    }
}

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
    })
}

fn sql_u64(row: &rusqlite::Row<'_>, column: usize) -> rusqlite::Result<u64> {
    let value: i64 = row.get(column)?;
    u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(column, value))
}
