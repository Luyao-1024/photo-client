//! Account-free local library RPC. Blocking SQLite/filesystem work stays off Tokio.
use photo_core::{
    edit::{CropRect, EditAdjustments},
    local_library::{AlbumInfo, LocalLibrary, MediaInput, PhotoFilter},
    media,
};
use std::{
    path::PathBuf,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU8, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::Semaphore;

pub struct LocalLibraryInfo {
    pub library_id: String,
    pub count: u64,
    pub revision: u64,
}
pub struct LocalPhoto {
    pub id: String,
    pub path: String,
    pub name: String,
    pub parent: String,
    pub size_bytes: u64,
    pub modified_ms: i64,
    pub content_version: u64,
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
    pub duration_ms: Option<i64>,
    pub motion_offset: Option<i64>,
}
pub struct LocalAlbum {
    pub path: String,
    pub name: String,
    pub count: u64,
    pub cover_media_id: Option<String>,
}
pub struct LocalPhotoPage {
    pub items: Vec<LocalPhoto>,
    pub next_cursor: Option<String>,
    pub total: u64,
    pub revision: u64,
}
pub struct EditRequest {
    pub rotation_degrees: i32,
    pub flip_horizontal: bool,
    pub flip_vertical: bool,
    pub brightness: i32,
    pub contrast: i32,
    pub saturation: i32,
    pub crop_x: Option<u32>,
    pub crop_y: Option<u32>,
    pub crop_width: Option<u32>,
    pub crop_height: Option<u32>,
    pub save_copy: bool,
    pub expected_content_version: Option<u64>,
}

pub struct LocalScanResult {
    pub discovered: u64,
    pub skipped: u64,
    pub failed: u64,
    pub cancelled: bool,
}

/// Scan slot ownership. A background sweep yields to an explicit user scan.
pub(super) const SCAN_IDLE: u8 = 0;
pub(super) const SCAN_BACKGROUND: u8 = 1;
pub(super) const SCAN_USER: u8 = 2;

pub(super) struct Service {
    pub(super) store: LocalLibrary,
    pub(super) cancel: AtomicBool,
    pub(super) scan_state: AtomicU8,
    pub(super) closed: AtomicBool,
    pub(super) fs_dirty: AtomicBool,
    pub(super) watcher_running: AtomicBool,
    initial_scan: AtomicBool,
    pub(super) watcher: Mutex<Option<notify::RecommendedWatcher>>,
    thumbnails: Semaphore,
}

impl Service {
    /// Claim the single scan slot. Background sweeps never displace a running
    /// user scan; a user scan asks a sweep to stop and takes its place.
    pub(super) fn claim_scan(&self, kind: u8) -> bool {
        self.scan_state
            .compare_exchange(SCAN_IDLE, kind, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }
    pub(super) fn release_scan(&self) {
        self.scan_state.store(SCAN_IDLE, Ordering::Release);
    }
    pub(super) fn scan_is_user(&self) -> bool {
        self.scan_state.load(Ordering::Acquire) == SCAN_USER
    }
}
fn global() -> &'static Mutex<Option<Arc<Service>>> {
    static INSTANCE: OnceLock<Mutex<Option<Arc<Service>>>> = OnceLock::new();
    INSTANCE.get_or_init(|| Mutex::new(None))
}
fn service() -> Result<Arc<Service>, String> {
    let service = global()
        .lock()
        .map_err(|_| "LibraryUnavailable")?
        .clone()
        .ok_or("LibraryNotOpen")?;
    if service.closed.load(Ordering::Acquire) {
        return Err("LibraryClosed".into());
    }
    Ok(service)
}
pub(super) fn changed() {
    let _ = super::bootstrap::runtime().notify("library_changed");
}
fn root_path(override_path: Option<String>) -> Result<PathBuf, String> {
    if let Some(path) = override_path {
        let path = PathBuf::from(path);
        if !path.is_absolute() {
            return Err("DataRootMustBeAbsolute".into());
        }
        return Ok(path);
    }
    let base = if let Some(path) = std::env::var_os("XDG_DATA_HOME").filter(|p| !p.is_empty()) {
        PathBuf::from(path)
    } else {
        PathBuf::from(std::env::var_os("HOME").ok_or("HomeUnavailable")?).join(".local/share")
    };
    if !base.is_absolute() {
        return Err("DataRootMustBeAbsolute".into());
    }
    Ok(base.join("photo-client/library"))
}
fn crop_rect(x: u32, y: u32, width: u32, height: u32) -> CropRect {
    CropRect {
        x,
        y,
        width,
        height,
    }
}

fn join_error(_: tokio::task::JoinError) -> String {
    "LocalWorkerFailed".into()
}

pub async fn open_library(data_root: Option<String>) -> Result<LocalLibraryInfo, String> {
    super::bootstrap::runtime()
        .subscribe()
        .map_err(|e| e.to_string())?;
    let auto_discover = data_root.is_none();
    let root = root_path(data_root)?;
    tokio::task::spawn_blocking(move || {
        let mut slot = global().lock().map_err(|_| "LibraryUnavailable")?;
        if slot.is_none() {
            let store = LocalLibrary::open(&root)?;
            if auto_discover && store.sources()?.is_empty() {
                if let Some(home) = std::env::var_os("HOME") {
                    let home = PathBuf::from(home);
                    let config = std::env::var_os("XDG_CONFIG_HOME")
                        .map(PathBuf::from)
                        .unwrap_or_else(|| home.join(".config"));
                    let dirs =
                        std::fs::read_to_string(config.join("user-dirs.dirs")).unwrap_or_default();
                    for (key, fallback, localized) in [
                        ("XDG_PICTURES_DIR", "Pictures", "图片"),
                        ("XDG_VIDEOS_DIR", "Videos", "视频"),
                    ] {
                        let configured = dirs
                            .lines()
                            .find_map(|line| line.strip_prefix(&format!("{key}=")))
                            .map(|value| {
                                PathBuf::from(
                                    value
                                        .trim_matches('"')
                                        .replace("$HOME", &home.to_string_lossy()),
                                )
                            });
                        let path = configured.unwrap_or_else(|| {
                            if home.join(fallback).is_dir() {
                                home.join(fallback)
                            } else {
                                home.join(localized)
                            }
                        });
                        if path.is_dir() && path != home {
                            let _ = store.add_source(&path);
                        }
                    }
                }
            }
            let workers = serde_json::from_str::<serde_json::Value>(&store.preferences()?)
                .ok()
                .and_then(|p| p["thumbnailWorkers"].as_u64())
                .unwrap_or(2)
                .clamp(1, 4) as usize;
            *slot = Some(Arc::new(Service {
                store,
                cancel: AtomicBool::new(false),
                scan_state: AtomicU8::new(SCAN_IDLE),
                closed: AtomicBool::new(false),
                fs_dirty: AtomicBool::new(false),
                watcher_running: AtomicBool::new(false),
                watcher: Mutex::new(None),
                initial_scan: AtomicBool::new(true),
                thumbnails: Semaphore::new(workers),
            }));
        }
        let active = slot.as_ref().ok_or("LibraryNotOpen")?;
        if active.store.root != root.canonicalize().map_err(|_| "DataRootUnavailable")? {
            return Err("AnotherLibraryAlreadyOpen".into());
        }
        if active
            .watcher
            .lock()
            .map_err(|_| "WatchUnavailable")?
            .is_none()
        {
            let _ = super::local_watcher::install(active);
        }
        if active.initial_scan.swap(false, Ordering::AcqRel) && !active.store.sources()?.is_empty()
        {
            let worker = active.clone();
            // Startup reconciliation is background work: it refreshes the index
            // silently and never asks the user for attention.
            std::thread::spawn(move || {
                if !worker.claim_scan(SCAN_BACKGROUND) {
                    return;
                }
                let _ = super::bootstrap::runtime().notify("local_background_scan_started");
                let _guard = ScanGuard::background(worker.clone());
                let _ = super::local_watcher::refresh(&worker);
                changed();
            });
        }
        let info = active.store.info()?;
        Ok(LocalLibraryInfo {
            library_id: info.library_id,
            count: info.count,
            revision: info.revision,
        })
    })
    .await
    .map_err(join_error)?
}

pub async fn list_photos(
    cursor: Option<String>,
    limit: u32,
    favorites_only: bool,
    search: String,
    search_scope: String,
    folder: Option<String>,
    media_kind: Option<String>,
    trashed: bool,
) -> Result<LocalPhotoPage, String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        let page = active.store.query(
            PhotoFilter {
                favorites_only,
                search,
                search_scope,
                folder,
                media_kind,
                trashed,
                ..Default::default()
            },
            cursor,
            limit,
        )?;
        Ok(LocalPhotoPage {
            items: {
                let flags = active
                    .store
                    .media_flags(page.items.iter().map(|p| p.id.clone()).collect())?;
                page.items
                    .into_iter()
                    .map(|p| {
                        let (duration_ms, motion_offset) =
                            flags.get(&p.id).copied().unwrap_or((None, None));
                        LocalPhoto {
                            id: p.id,
                            path: p.path,
                            name: p.name,
                            parent: p.parent,
                            size_bytes: p.size_bytes,
                            modified_ms: p.modified_ms,
                            content_version: p.content_version,
                            width: p.width,
                            height: p.height,
                            favorite: p.favorite,
                            media_kind: p.media_kind,
                            mime_type: p.mime_type,
                            orientation: p.orientation,
                            capture_time_ms: p.capture_time_ms,
                            sort_time_ms: p.sort_time_ms,
                            state: p.state,
                            trashed_at_ms: p.trashed_at_ms,
                            duration_ms,
                            motion_offset,
                        }
                    })
                    .collect()
            },
            next_cursor: page.next_cursor,
            total: page.total,
            revision: page.revision,
        })
    })
    .await
    .map_err(join_error)?
}

pub async fn list_albums() -> Result<Vec<LocalAlbum>, String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        Ok(active
            .store
            .list_albums()?
            .into_iter()
            .map(|album: AlbumInfo| LocalAlbum {
                path: album.path,
                name: album.name,
                count: album.count,
                cover_media_id: album.cover_media_id,
            })
            .collect())
    })
    .await
    .map_err(join_error)?
}

pub async fn trash_media(media_ids: Vec<String>) -> Result<u64, String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        let changed_count = active.store.trash_media(media_ids)?;
        if changed_count > 0 {
            changed();
        }
        Ok(changed_count)
    })
    .await
    .map_err(join_error)?
}

pub async fn restore_media(media_ids: Vec<String>) -> Result<u64, String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        let changed_count = active.store.restore_media(media_ids)?;
        if changed_count > 0 {
            changed();
        }
        Ok(changed_count)
    })
    .await
    .map_err(join_error)?
}

pub async fn purge_media(media_ids: Vec<String>) -> Result<u64, String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        let changed_count = active.store.purge_media(media_ids)?;
        if changed_count > 0 {
            changed();
        }
        Ok(changed_count)
    })
    .await
    .map_err(join_error)?
}

pub async fn empty_trash() -> Result<u64, String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        let changed_count = active.store.empty_trash()?;
        if changed_count > 0 {
            changed();
        }
        Ok(changed_count)
    })
    .await
    .map_err(join_error)?
}

pub async fn add_to_album(
    media_ids: Vec<String>,
    target_folder: String,
    move_files: bool,
) -> Result<u64, String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        let changed_count = active
            .store
            .add_to_album(media_ids, target_folder, move_files)?;
        if changed_count > 0 {
            changed();
        }
        Ok(changed_count)
    })
    .await
    .map_err(join_error)?
}

pub async fn rename_media(media_id: String, name: String) -> Result<LocalPhoto, String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        let photo = active.store.rename_media(media_id, name)?;
        changed();
        Ok(LocalPhoto {
            id: photo.id,
            path: photo.path,
            name: photo.name,
            parent: photo.parent,
            size_bytes: photo.size_bytes,
            modified_ms: photo.modified_ms,
            content_version: photo.content_version,
            width: photo.width,
            height: photo.height,
            favorite: photo.favorite,
            media_kind: photo.media_kind,
            mime_type: photo.mime_type,
            orientation: photo.orientation,
            capture_time_ms: photo.capture_time_ms,
            sort_time_ms: photo.sort_time_ms,
            state: photo.state,
            trashed_at_ms: photo.trashed_at_ms,
            duration_ms: None,
            motion_offset: None,
        })
    })
    .await
    .map_err(join_error)?
}

fn to_local_photo(photo: photo_core::local_library::LocalPhoto) -> LocalPhoto {
    LocalPhoto {
        id: photo.id,
        path: photo.path,
        name: photo.name,
        parent: photo.parent,
        size_bytes: photo.size_bytes,
        modified_ms: photo.modified_ms,
        content_version: photo.content_version,
        width: photo.width,
        height: photo.height,
        favorite: photo.favorite,
        media_kind: photo.media_kind,
        mime_type: photo.mime_type,
        orientation: photo.orientation,
        capture_time_ms: photo.capture_time_ms,
        sort_time_ms: photo.sort_time_ms,
        state: photo.state,
        trashed_at_ms: photo.trashed_at_ms,
        duration_ms: None,
        motion_offset: None,
    }
}

pub async fn save_edited(media_id: String, request: EditRequest) -> Result<LocalPhoto, String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        let crop = match (
            request.crop_x,
            request.crop_y,
            request.crop_width,
            request.crop_height,
        ) {
            (Some(x), Some(y), Some(width), Some(height)) if width > 0 && height > 0 => {
                Some(crop_rect(x, y, width, height))
            }
            _ => None,
        };
        let adjustments = EditAdjustments {
            rotation_degrees: request.rotation_degrees,
            flip_horizontal: request.flip_horizontal,
            flip_vertical: request.flip_vertical,
            brightness: request.brightness,
            contrast: request.contrast,
            saturation: request.saturation,
            crop,
        };
        let photo = active.store.save_edited_versioned(
            media_id,
            adjustments,
            request.save_copy,
            request.expected_content_version,
        )?;
        changed();
        Ok(to_local_photo(photo))
    })
    .await
    .map_err(join_error)?
}

/// Releases the scan slot and announces the matching lifecycle status.
pub(super) struct ScanGuard {
    service: Arc<Service>,
    kind: u8,
}
impl ScanGuard {
    pub(super) fn user(service: Arc<Service>) -> Self {
        Self {
            service,
            kind: SCAN_USER,
        }
    }
    pub(super) fn background(service: Arc<Service>) -> Self {
        Self {
            service,
            kind: SCAN_BACKGROUND,
        }
    }
}
impl Drop for ScanGuard {
    fn drop(&mut self) {
        self.service.release_scan();
        let status = if self.kind == SCAN_USER {
            "local_scan_finished"
        } else {
            "local_background_scan_finished"
        };
        let _ = super::bootstrap::runtime().notify(status);
    }
}
pub async fn add_paths(paths: Vec<String>) -> Result<LocalScanResult, String> {
    if paths.is_empty() || paths.len() > 512 {
        return Err("InvalidSourceSelection".into());
    }
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        // An explicit user scan outranks a background sweep: ask the sweep to
        // stop and take its slot instead of rejecting the request.
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if active.claim_scan(SCAN_USER) {
                break;
            }
            if active.scan_is_user() {
                return Err("ScanAlreadyRunning".into());
            }
            active.cancel.store(true, Ordering::Release);
            if Instant::now() >= deadline {
                return Err("ScanAlreadyRunning".into());
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _guard = ScanGuard::user(active.clone());
        active.cancel.store(false, Ordering::Release);
        let _ = super::bootstrap::runtime().notify("local_scan_started");
        let mut total = LocalScanResult {
            discovered: 0,
            skipped: 0,
            failed: 0,
            cancelled: false,
        };
        for selected in paths {
            if active.cancel.load(Ordering::Acquire) || active.closed.load(Ordering::Acquire) {
                total.cancelled = true;
                break;
            }
            let root = PathBuf::from(selected);
            if !root.is_absolute() {
                total.failed += 1;
                continue;
            }
            let source_id = match active.store.add_source(&root) {
                Ok(s) => s,
                Err(_) => {
                    total.failed += 1;
                    continue;
                }
            };
            let mut invalid_paths = 0;
            let mut exclusions = active.store.exclusions()?;
            exclusions.push(active.store.root.clone());
            // Re-adding a known folder or file only re-reads what changed.
            let known = active.store.indexed_fingerprints(&source_id)?;
            let summary = media::scan_paths_excluding_known(
                &[root],
                &exclusions,
                &active.cancel,
                &known,
                |batch| {
                    if active.closed.load(Ordering::Acquire) {
                        return Err("LibraryClosed".into());
                    }
                    let details = batch
                        .iter()
                        .filter_map(|m| Some((m.path.to_str()?.to_string(), m.details.clone())))
                        .collect();
                    let inputs = batch
                        .into_iter()
                        .filter_map(|m| {
                            let (Some(path), Some(parent)) =
                                (m.path.to_str(), m.parent_path.to_str())
                            else {
                                invalid_paths += 1;
                                return None;
                            };
                            Some(MediaInput {
                                path: path.into(),
                                name: m.display_name,
                                parent: parent.into(),
                                size_bytes: m.size_bytes,
                                modified_ns: m.modified_ns,
                                mime_type: m.mime_type,
                                width: m.width,
                                height: m.height,
                                orientation: m.orientation,
                                capture_time_ms: m.capture_time_ms,
                            })
                        })
                        .collect();
                    let changed_count = active.store.upsert_batch(source_id.clone(), inputs)?;
                    active.store.record_details(details)?;
                    if changed_count > 0 {
                        changed();
                    }
                    Ok(())
                },
            )?;
            total.discovered += summary.discovered.saturating_sub(invalid_paths);
            total.skipped += summary.skipped;
            total.failed += summary.failed + invalid_paths;
            total.cancelled |= summary.cancelled;
        }
        let _ = super::local_watcher::install(&active);
        changed();
        Ok(total)
    })
    .await
    .map_err(join_error)?
}

pub async fn cancel_scan() -> Result<(), String> {
    let active = service()?;
    active.cancel.store(true, Ordering::Release);
    Ok(())
}

/// Cached preview classes are fixed so the cache key space stays bounded.
pub const THUMBNAIL_SIZE_CLASSES: [u32; 3] = [256, 512, 1024];

pub async fn thumbnail(media_id: String, size_class: u32) -> Result<String, String> {
    if !THUMBNAIL_SIZE_CLASSES.contains(&size_class) {
        return Err("InvalidThumbnailSizeClass".into());
    }
    let active = service()?;
    let _permit = active
        .thumbnails
        .acquire()
        .await
        .map_err(|_| "LibraryClosed")?;
    if active.closed.load(Ordering::Acquire) {
        return Err("LibraryClosed".into());
    }
    let worker = active.clone();
    tokio::task::spawn_blocking(move || {
        let photo = worker.store.photo(media_id)?;
        let directory = worker
            .store
            .root
            .join("cache")
            .join(&photo.id)
            .join(photo.content_version.to_string());
        std::fs::create_dir_all(&directory).map_err(|_| "CacheUnavailable")?;
        let destination = directory.join(format!("thumbnail-{size_class}.jpg"));
        if !destination.is_file() {
            media::prepare_preview(
                std::path::Path::new(&photo.path),
                photo.size_bytes,
                photo.modified_ns,
                size_class,
                &destination,
            )?;
        }
        let current = worker.store.photo(photo.id)?;
        if current.content_version != photo.content_version {
            return Err("SourceChanged".into());
        }
        destination
            .to_str()
            .map(str::to_owned)
            .ok_or("UnsupportedPathEncoding".into())
    })
    .await
    .map_err(join_error)?
}

pub async fn set_favorite(media_id: String, favorite: bool) -> Result<(), String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        if active.store.set_favorite(media_id, favorite)? {
            changed();
        }
        Ok(())
    })
    .await
    .map_err(join_error)?
}

pub async fn close_library() -> Result<(), String> {
    tokio::task::spawn_blocking(|| {
        if let Some(active) = global().lock().map_err(|_| "LibraryUnavailable")?.take() {
            active.closed.store(true, Ordering::Release);
            active.cancel.store(true, Ordering::Release);
            active.thumbnails.close();
            drop(active);
        }
        Ok(())
    })
    .await
    .map_err(join_error)?
}

/// Local-only tools. JSON is used at the FFI boundary, never as catalog storage.
/// Each command delegates to the same scoped local writer as typed library RPCs.
pub async fn library_tools(command: String) -> Result<String, String> {
    let active = service()?;
    tokio::task::spawn_blocking(move || {
        let request:serde_json::Value=serde_json::from_str(&command).map_err(|_|"InvalidCommand")?;
        let op=request["op"].as_str().ok_or("InvalidCommand")?;
        let string=|key:&str|request[key].as_str().map(str::to_owned).ok_or_else(||"InvalidCommand".to_string());
        let ids=||request["ids"].as_array().ok_or("InvalidCommand")?.iter().map(|v|v.as_str().map(str::to_owned).ok_or_else(||"InvalidCommand".to_string())).collect::<Result<Vec<_>,_>>();
        let started=std::time::Instant::now();
        let result=match op{
            "window"|"selection"|"rank"=>{
                let filter:PhotoFilter=serde_json::from_value(request["filter"].clone()).map_err(|_|"InvalidQuery")?;
                if op=="rank"{serde_json::json!(active.store.photo_rank(filter,string("id")?)?)}else{
                    let start=if op=="selection"{0}else{request["start"].as_u64().ok_or("InvalidQuery")? as usize};
                    let count=if op=="selection"{2000}else{request["count"].as_u64().ok_or("InvalidQuery")? as usize};
                    let page=active.store.query_window(filter.clone(),start,count)?;
                    let groups=if request["groups"].as_bool().unwrap_or(false){active.store.browse_groups(filter)?}else{Vec::new()};
                    {
                    let flags=active.store.media_flags(page.items.iter().map(|p|p.id.clone()).collect())?;
                    let mut items=serde_json::to_value(&page.items).map_err(|_|"LocalMappingFailed")?;
                    for item in items.as_array_mut().ok_or("LocalMappingFailed")?{if let Some((duration,motion))=item["id"].as_str().and_then(|id|flags.get(id)){item["duration_ms"]=serde_json::json!(duration);item["motion_offset"]=serde_json::json!(motion);}}
                    serde_json::json!({"items":items,"total":page.total,"revision":page.revision,"groups":groups})
                    }
                }
            }
            "photos"=>serde_json::json!(ids()?.into_iter().map(|id|active.store.photo(id)).collect::<Result<Vec<_>,_>>()?),
            "preferences"=>serde_json::from_str(&active.store.preferences()?).map_err(|_|"InvalidPreference")?,
            "setPreference"=>{active.store.set_preference(string("key")?,request["value"].to_string())?;serde_json::Value::Null}
            "sources"=>serde_json::json!(active.store.sources()?),
            "removeSource"=>{active.store.remove_source(string("id")?)?;changed();serde_json::Value::Null}
            "createAlbum"=>{let folder=active.store.create_album(PathBuf::from(string("parent")?),string("name")?)?;let _=super::local_watcher::install(&active);changed();serde_json::json!(folder)}
            "renameAlbum"=>{active.store.rename_album(string("folder")?,string("name")?)?;let _=super::local_watcher::install(&active);changed();serde_json::Value::Null}
            "removeAlbum"=>{active.store.remove_album(string("folder")?)?;changed();serde_json::Value::Null}
            "reorderAlbums"=>{active.store.reorder_albums(ids()?)?;changed();serde_json::Value::Null}
            "albumCover"=>{active.store.set_album_cover(string("folder")?,string("id")?)?;changed();serde_json::Value::Null}
            "export"=>serde_json::json!(active.store.export_media(ids()?,PathBuf::from(string("directory")?))?),
            "metadata"=>serde_json::to_value(active.store.media_details(string("id")?)?).map_err(|_|"MetadataFailed")?,
            "preview"=>{
                let photo=active.store.photo(string("id")?)?;
                let directory=active.store.root.join("cache").join(&photo.id).join(photo.content_version.to_string());
                let target=directory.join("preview.jpg");
                if !target.is_file(){media::prepare_preview(std::path::Path::new(&photo.path),photo.size_bytes,photo.modified_ns,2560,&target)?;}
                serde_json::json!(target.to_str().ok_or("UnsupportedPathEncoding")?)
            }
            "motionVideo"=>{
                let photo=active.store.photo(string("id")?)?;
                let info=media::motion_photo::detect(std::path::Path::new(&photo.path)).ok_or("NotMotionPhoto")?;
                let dir=active.store.root.join("cache").join(&photo.id).join(photo.content_version.to_string());std::fs::create_dir_all(&dir).map_err(|_|"CacheUnavailable")?;
                let path=dir.join("motion.mp4");
                if !path.is_file(){let stage=dir.join("motion.tmp");media::motion_photo::extract_video_to(std::path::Path::new(&photo.path),&info,&stage).map_err(|_|"MotionExtractFailed")?;std::fs::rename(&stage,&path).map_err(|_|"MotionExtractFailed")?;}
                serde_json::json!(path.to_str().ok_or("UnsupportedPathEncoding")?)
            }
            "clearLogs"=>{active.store.clear_logs()?;serde_json::Value::Null}
            "cacheUsage"=>serde_json::json!(active.store.cache_usage()?),
            "clearCache"=>{active.store.clear_cache()?;changed();serde_json::Value::Null}
            _=>return Err("UnknownLocalCommand".into())
        };
        if !matches!(op,"window"|"rank"|"metadata"|"preview"|"preferences"|"sources"|"cacheUsage"){active.store.log_event(op,true,started.elapsed().as_millis());}
        Ok(result.to_string())
    }).await.map_err(join_error)?
}
