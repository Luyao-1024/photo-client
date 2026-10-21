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
        atomic::{AtomicBool, Ordering},
    },
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
    pub brightness: i32,
    pub contrast: i32,
    pub saturation: i32,
    pub crop_x: Option<u32>,
    pub crop_y: Option<u32>,
    pub crop_width: Option<u32>,
    pub crop_height: Option<u32>,
    pub save_copy: bool,
}

pub struct LocalScanResult {
    pub discovered: u64,
    pub skipped: u64,
    pub failed: u64,
    pub cancelled: bool,
}

struct Service {
    store: LocalLibrary,
    cancel: AtomicBool,
    scanning: AtomicBool,
    closed: AtomicBool,
    thumbnails: Semaphore,
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
fn changed() {
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
    let root = root_path(data_root)?;
    tokio::task::spawn_blocking(move || {
        let mut slot = global().lock().map_err(|_| "LibraryUnavailable")?;
        if slot.is_none() {
            *slot = Some(Arc::new(Service {
                store: LocalLibrary::open(&root)?,
                cancel: AtomicBool::new(false),
                scanning: AtomicBool::new(false),
                closed: AtomicBool::new(false),
                thumbnails: Semaphore::new(2),
            }));
        }
        let active = slot.as_ref().ok_or("LibraryNotOpen")?;
        if active.store.root != root.canonicalize().map_err(|_| "DataRootUnavailable")? {
            return Err("AnotherLibraryAlreadyOpen".into());
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
            },
            cursor,
            limit,
        )?;
        Ok(LocalPhotoPage {
            items: page
                .items
                .into_iter()
                .map(|p| LocalPhoto {
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
                })
                .collect(),
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
            brightness: request.brightness,
            contrast: request.contrast,
            saturation: request.saturation,
            crop,
        };
        let photo = active
            .store
            .save_edited(media_id, adjustments, request.save_copy)?;
        changed();
        Ok(to_local_photo(photo))
    })
    .await
    .map_err(join_error)?
}

struct ScanGuard(Arc<Service>);
impl Drop for ScanGuard {
    fn drop(&mut self) {
        self.0.scanning.store(false, Ordering::Release);
    }
}
pub async fn add_paths(paths: Vec<String>) -> Result<LocalScanResult, String> {
    if paths.is_empty() || paths.len() > 512 {
        return Err("InvalidSourceSelection".into());
    }
    let active = service()?;
    if active
        .scanning
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err("ScanAlreadyRunning".into());
    }
    active.cancel.store(false, Ordering::Release);
    tokio::task::spawn_blocking(move || {
        let _guard = ScanGuard(active.clone());
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
            let summary = media::scan_paths(&[root], &active.cancel, |batch| {
                if active.closed.load(Ordering::Acquire) {
                    return Err("LibraryClosed".into());
                }
                let inputs = batch
                    .into_iter()
                    .filter_map(|m| {
                        let (Some(path), Some(parent)) = (m.path.to_str(), m.parent_path.to_str())
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
                if active.store.upsert_batch(source_id.clone(), inputs)? > 0 {
                    changed();
                }
                Ok(())
            })?;
            total.discovered += summary.discovered.saturating_sub(invalid_paths);
            total.skipped += summary.skipped;
            total.failed += summary.failed + invalid_paths;
            total.cancelled |= summary.cancelled;
        }
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
            media::prepare_thumbnail(
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
