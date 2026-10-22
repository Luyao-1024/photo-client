//! Cloud synchronization RPC.
//!
//! All protocol work is delegated to `photo_core::cloud`, which speaks only
//! through the pinned sync-client SDK. This layer owns UI-friendly views and
//! serializes overlapping operations; it never touches tokens or HTTP.
use super::local_library::{changed, join_error, service};
use photo_core::cloud::{CloudEngine, CloudQueueResult, CloudStatus, CloudSyncReport};
use std::sync::{
    OnceLock,
    atomic::{AtomicBool, Ordering},
};
use tokio::sync::{Mutex, MutexGuard};

pub struct CloudStatusView {
    pub logged_in: bool,
    pub endpoint: Option<String>,
    pub username: Option<String>,
    pub user_id: Option<String>,
    pub token_expires_at_ms: Option<i64>,
    pub last_sync_ms: Option<i64>,
    pub state: String,
    pub error_code: Option<String>,
    pub pending_uploads: u32,
    pub pending_favorites: u32,
    pub bound_count: u32,
    pub syncing: bool,
}

pub struct CloudSyncReportView {
    pub downloaded: u32,
    pub uploaded: u32,
    pub favorites_applied: u32,
    pub favorites_uploaded: u32,
    pub skipped: u32,
    pub failed: u32,
    pub state: String,
    pub error_code: Option<String>,
}

pub struct CloudQueueResultView {
    pub queued: u32,
    pub skipped: u32,
    pub rejected: u32,
}

fn cloud_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// Held by `shutdown` so the library is never closed mid-sync.
pub(super) async fn lock() -> MutexGuard<'static, ()> {
    cloud_lock().lock().await
}

static SYNCING: AtomicBool = AtomicBool::new(false);

struct SyncFlag;
impl SyncFlag {
    fn enter() -> Self {
        SYNCING.store(true, Ordering::Release);
        Self
    }
}
impl Drop for SyncFlag {
    fn drop(&mut self) {
        SYNCING.store(false, Ordering::Release);
    }
}

fn view(status: CloudStatus) -> CloudStatusView {
    CloudStatusView {
        logged_in: status.logged_in,
        endpoint: status.endpoint,
        username: status.username,
        user_id: status.user_id,
        token_expires_at_ms: status.token_expires_at_ms,
        last_sync_ms: status.last_sync_ms,
        state: status.state,
        error_code: status.error_code,
        pending_uploads: status.pending_uploads,
        pending_favorites: status.pending_favorites,
        bound_count: status.bound_count,
        syncing: SYNCING.load(Ordering::Acquire),
    }
}

fn report_view(report: CloudSyncReport) -> CloudSyncReportView {
    CloudSyncReportView {
        downloaded: report.downloaded,
        uploaded: report.uploaded,
        favorites_applied: report.favorites_applied,
        favorites_uploaded: report.favorites_uploaded,
        skipped: report.skipped,
        failed: report.failed,
        state: report.state,
        error_code: report.error_code,
    }
}

async fn current_status(engine: &CloudEngine) -> Result<CloudStatusView, String> {
    let engine = engine.clone();
    let status = tokio::task::spawn_blocking(move || engine.status())
        .await
        .map_err(join_error)??;
    Ok(view(status))
}

/// Login is the only place a password exists. It stays in memory, is never
/// stored or logged, and is dropped as soon as the SDK call returns.
pub async fn cloud_login(
    endpoint: String,
    username: String,
    password: String,
) -> Result<CloudStatusView, String> {
    let _guard = lock().await;
    let active = service()?;
    let _flag = SyncFlag::enter();
    let engine = CloudEngine::new(active.store.clone());
    engine.login(&endpoint, &username, &password).await?;
    drop(password);
    // A failed first sweep is reported through state/error_code, not as a
    // login failure: the session itself is already established.
    let report = engine.sync_now().await?;
    if report.downloaded > 0 || report.favorites_applied > 0 {
        changed();
    }
    // Report the state after the first sweep, not while it still runs.
    drop(_flag);
    current_status(&engine).await
}

pub async fn cloud_logout() -> Result<CloudStatusView, String> {
    let _guard = lock().await;
    let active = service()?;
    let _flag = SyncFlag::enter();
    let engine = CloudEngine::new(active.store.clone());
    let status = tokio::task::spawn_blocking(move || engine.logout())
        .await
        .map_err(join_error)??;
    changed();
    drop(_flag);
    Ok(view(status))
}

/// Read-only and deliberately not serialized: it must stay answerable while a
/// sync is running so the UI can show `syncing`.
pub async fn cloud_status() -> Result<CloudStatusView, String> {
    let active = service()?;
    let engine = CloudEngine::new(active.store.clone());
    current_status(&engine).await
}

pub async fn cloud_sync_now() -> Result<CloudSyncReportView, String> {
    let _guard = lock().await;
    let active = service()?;
    let _flag = SyncFlag::enter();
    let engine = CloudEngine::new(active.store.clone()).with_change_observer(changed);
    let report = engine.sync_now().await?;
    changed();
    Ok(report_view(report))
}

/// Queueing only writes durable intents; the Flutter side then calls syncNow.
pub async fn cloud_queue_upload(media_ids: Vec<String>) -> Result<CloudQueueResultView, String> {
    let _guard = lock().await;
    let active = service()?;
    let engine = CloudEngine::new(active.store.clone());
    let result = tokio::task::spawn_blocking(move || engine.queue_upload(media_ids))
        .await
        .map_err(join_error)??;
    let CloudQueueResult {
        queued,
        skipped,
        rejected,
    } = result;
    Ok(CloudQueueResultView {
        queued,
        skipped,
        rejected,
    })
}

pub async fn cloud_bound_media_ids() -> Result<Vec<String>, String> {
    let active = service()?;
    let engine = CloudEngine::new(active.store.clone());
    tokio::task::spawn_blocking(move || engine.bound_media_ids())
        .await
        .map_err(join_error)?
}
