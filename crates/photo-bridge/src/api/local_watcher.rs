//! Desktop filesystem changes are independent of any network/account runtime.
use super::local_library::{SCAN_BACKGROUND, Service, local_changed};
use notify::{RecursiveMode, Watcher};
use photo_core::{local_library::MediaInput, media};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, atomic::Ordering},
    time::Duration,
};

pub(super) fn install(service: &Arc<Service>) -> Result<(), String> {
    let weak = Arc::downgrade(service);
    let watcher =
        notify::recommended_watcher(move |event: Result<notify::Event, notify::Error>| {
            let Ok(event) = event else {
                return;
            };
            if event.kind.is_access() {
                return;
            }
            let Some(service) = weak.upgrade() else {
                return;
            };
            if service.closed.load(Ordering::Acquire) {
                return;
            }
            if event
                .paths
                .iter()
                .all(|p| p.starts_with(&service.store.root))
            {
                return;
            }
            service.fs_dirty.store(true, Ordering::Release);
            if service.watcher_running.swap(true, Ordering::AcqRel) {
                return;
            }
            std::thread::spawn(move || {
                loop {
                    std::thread::sleep(Duration::from_millis(300));
                    if service.closed.load(Ordering::Acquire) {
                        break;
                    }
                    if !service.claim_scan(SCAN_BACKGROUND) {
                        continue;
                    }
                    service.cancel.store(false, Ordering::Release);
                    // Filesystem reconciliation is background work: the library
                    // updates itself without asking the user for attention.
                    let _ = super::bootstrap::runtime().notify("local_background_scan_started");
                    service.fs_dirty.store(false, Ordering::Release);
                    let _guard = super::local_library::ScanGuard::background(service.clone());
                    let result = refresh(&service);
                    service
                        .store
                        .log_event("filesystem_scan", result.is_ok(), 0);
                    local_changed();
                    drop(_guard);
                    if result.is_err() {
                        let _ = super::bootstrap::runtime().notify("local_background_scan_failed");
                    }
                    if !service.fs_dirty.load(Ordering::Acquire) {
                        break;
                    }
                }
                service.watcher_running.store(false, Ordering::Release);
            });
        })
        .map_err(|_| "WatchUnavailable")?;
    let mut watcher = watcher;
    let sources = service.store.sources()?;
    for source in sources
        .into_iter()
        .filter(|s| s.enabled && s.kind != "managed")
    {
        let path = PathBuf::from(source.path);
        let watched = if path.is_dir() {
            path
        } else {
            path.parent().unwrap_or(Path::new("/")).to_path_buf()
        };
        if watched.exists() {
            let _ = watcher.watch(&watched, RecursiveMode::Recursive);
        }
    }
    #[cfg(target_os = "linux")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            let root = PathBuf::from(home).join(".local/share/Trash");
            if root.exists() {
                let _ = watcher.watch(&root, RecursiveMode::Recursive);
            }
        }
        if let Some(data) = std::env::var_os("XDG_DATA_HOME") {
            let root = PathBuf::from(data).join("Trash");
            if root.exists() {
                let _ = watcher.watch(&root, RecursiveMode::Recursive);
            }
        }
    }
    *service.watcher.lock().map_err(|_| "WatchUnavailable")? = Some(watcher);
    Ok(())
}
pub(super) fn refresh(service: &Arc<Service>) -> Result<(), String> {
    service.store.reconcile_trash()?;
    for source in service
        .store
        .sources()?
        .into_iter()
        .filter(|s| s.enabled && s.kind != "managed")
    {
        if service.closed.load(Ordering::Acquire) {
            break;
        }
        let path = PathBuf::from(&source.path);
        let exists = path.exists();
        service
            .store
            .source_availability(source.id.clone(), exists)?;
        if !exists {
            continue;
        }
        let mut exclusions = service.store.exclusions()?;
        exclusions.push(service.store.root.clone());
        // Files already indexed under the same fingerprint need no metadata
        // again, so a repeated sweep only pays one stat per file.
        let known = service.store.indexed_fingerprints(&source.id)?;
        media::scan_paths_excluding_known(
            &[path],
            &exclusions,
            &service.cancel,
            &known,
            |batch| {
                let details = batch
                    .iter()
                    .filter_map(|m| Some((m.path.to_str()?.to_string(), m.details.clone())))
                    .collect();
                let inputs = batch
                    .into_iter()
                    .filter_map(|m| {
                        Some(MediaInput {
                            path: m.path.to_str()?.into(),
                            name: m.display_name,
                            parent: m.parent_path.to_str()?.into(),
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
                let changed_count = service.store.upsert_batch(source.id.clone(), inputs)?;
                service.store.record_details(details)?;
                if changed_count > 0 {
                    local_changed();
                }
                Ok(())
            },
        )?;
        service.store.reconcile_source(source.id)?;
    }
    service.store.reconcile_trash()?;
    Ok(())
}
