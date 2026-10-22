//! Cloud synchronization RPC.
//!
//! All protocol work is delegated to `photo_core::cloud`, which speaks only
//! through the pinned sync-client SDK. This layer owns UI-friendly views and
//! serializes overlapping operations; it never touches tokens or HTTP.
use super::local_library::{changed, join_error, service};
use photo_core::cloud::{
    CloudAccountState, CloudEngine, CloudProgress, CloudQueueResult, CloudStatus, CloudSyncReport,
};
use std::sync::{Mutex, OnceLock};
use tokio::sync::{Mutex as AsyncMutex, MutexGuard};

pub struct CloudActivityView {
    pub phase: String,
    pub syncing: bool,
    pub started_at_ms: Option<i64>,
    pub downloaded: u32,
    pub download_total: u32,
    pub uploaded: u32,
    pub upload_total: u32,
    pub favorites_applied: u32,
    pub favorites_uploaded: u32,
    pub favorite_total: u32,
    pub skipped: u32,
    pub failed: u32,
    pub error_code: Option<String>,
}

pub struct CloudAccountView {
    pub account_id: String,
    pub endpoint: String,
    pub username: String,
    pub user_id: Option<String>,
    pub active: bool,
    pub signed_in: bool,
    pub last_sync_ms: Option<i64>,
}

pub struct CloudStatusView {
    pub logged_in: bool,
    pub account_id: Option<String>,
    pub endpoint: Option<String>,
    pub username: Option<String>,
    pub user_id: Option<String>,
    pub token_expires_at_ms: Option<i64>,
    pub last_sync_ms: Option<i64>,
    pub state: String,
    pub error_code: Option<String>,
    pub pending_uploads: u32,
    pub failed_uploads: u32,
    pub pending_favorites: u32,
    pub bound_count: u32,
    pub upload_scope: String,
    pub upload_albums: Vec<String>,
    pub syncing: bool,
    pub activity: CloudActivityView,
    pub accounts: Vec<CloudAccountView>,
}

pub struct CloudSyncReportView {
    pub downloaded: u32,
    pub download_total: u32,
    pub uploaded: u32,
    pub upload_total: u32,
    pub favorites_applied: u32,
    pub favorites_uploaded: u32,
    pub favorite_total: u32,
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

fn cloud_lock() -> &'static AsyncMutex<()> {
    static LOCK: OnceLock<AsyncMutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| AsyncMutex::new(()))
}

/// Held by `shutdown` so the library is never closed mid-sync.
pub(super) async fn lock() -> MutexGuard<'static, ()> {
    cloud_lock().lock().await
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

#[derive(Clone)]
struct Activity {
    phase: String,
    syncing: bool,
    started_at_ms: Option<i64>,
    downloaded: u32,
    download_total: u32,
    uploaded: u32,
    upload_total: u32,
    favorites_applied: u32,
    favorites_uploaded: u32,
    favorite_total: u32,
    skipped: u32,
    failed: u32,
    error_code: Option<String>,
}

fn idle_activity() -> Activity {
    Activity {
        phase: "idle".into(),
        syncing: false,
        started_at_ms: None,
        downloaded: 0,
        download_total: 0,
        uploaded: 0,
        upload_total: 0,
        favorites_applied: 0,
        favorites_uploaded: 0,
        favorite_total: 0,
        skipped: 0,
        failed: 0,
        error_code: None,
    }
}

fn activity() -> &'static Mutex<Activity> {
    static ACTIVITY: OnceLock<Mutex<Activity>> = OnceLock::new();
    ACTIVITY.get_or_init(|| Mutex::new(idle_activity()))
}

fn reset_activity() {
    *activity().lock().unwrap() = idle_activity();
}

fn begin_activity() {
    *activity().lock().unwrap() = Activity {
        phase: "preparing".into(),
        syncing: true,
        started_at_ms: Some(now_ms()),
        ..idle_activity()
    };
}

fn apply_progress(progress: CloudProgress) {
    let mut state = activity().lock().unwrap();
    state.phase = progress.phase;
    state.syncing = true;
    state.downloaded = progress.downloaded;
    state.download_total = progress.download_total;
    state.uploaded = progress.uploaded;
    state.upload_total = progress.upload_total;
    state.favorites_applied = progress.favorites_applied;
    state.favorites_uploaded = progress.favorites_uploaded;
    state.favorite_total = progress.favorite_total;
    state.skipped = progress.skipped;
    state.failed = progress.failed;
    state.error_code = progress.error_code;
}

fn end_activity(phase: &str, error_code: Option<String>) {
    let mut state = activity().lock().unwrap();
    state.phase = phase.to_owned();
    state.syncing = false;
    state.error_code = error_code;
}

fn activity_view() -> CloudActivityView {
    let state = activity().lock().unwrap().clone();
    CloudActivityView {
        phase: state.phase,
        syncing: state.syncing,
        started_at_ms: state.started_at_ms,
        downloaded: state.downloaded,
        download_total: state.download_total,
        uploaded: state.uploaded,
        upload_total: state.upload_total,
        favorites_applied: state.favorites_applied,
        favorites_uploaded: state.favorites_uploaded,
        favorite_total: state.favorite_total,
        skipped: state.skipped,
        failed: state.failed,
        error_code: state.error_code,
    }
}

fn account_view(account: CloudAccountState) -> CloudAccountView {
    CloudAccountView {
        account_id: account.account_id,
        endpoint: account.endpoint,
        username: account.username,
        user_id: account.user_id,
        active: account.is_active,
        signed_in: account.signed_in,
        last_sync_ms: account.last_sync_ms,
    }
}

fn view(status: CloudStatus, accounts: Vec<CloudAccountState>) -> CloudStatusView {
    let activity = activity_view();
    CloudStatusView {
        logged_in: status.logged_in,
        account_id: status.account_id,
        endpoint: status.endpoint,
        username: status.username,
        user_id: status.user_id,
        token_expires_at_ms: status.token_expires_at_ms,
        last_sync_ms: status.last_sync_ms,
        state: status.state,
        error_code: status.error_code,
        pending_uploads: status.pending_uploads,
        failed_uploads: status.failed_uploads,
        pending_favorites: status.pending_favorites,
        bound_count: status.bound_count,
        upload_scope: status.upload_scope,
        upload_albums: status.upload_albums,
        syncing: activity.syncing,
        activity,
        accounts: accounts.into_iter().map(account_view).collect(),
    }
}

fn report_view(report: CloudSyncReport) -> CloudSyncReportView {
    CloudSyncReportView {
        downloaded: report.downloaded,
        download_total: report.download_total,
        uploaded: report.uploaded,
        upload_total: report.upload_total,
        favorites_applied: report.favorites_applied,
        favorites_uploaded: report.favorites_uploaded,
        favorite_total: report.favorite_total,
        skipped: report.skipped,
        failed: report.failed,
        state: report.state,
        error_code: report.error_code,
    }
}

async fn current_status(engine: &CloudEngine) -> Result<CloudStatusView, String> {
    let engine = engine.clone();
    let (status, accounts) = tokio::task::spawn_blocking(move || {
        let status = engine.status()?;
        let accounts = engine.accounts()?;
        Ok::<_, String>((status, accounts))
    })
    .await
    .map_err(join_error)??;
    Ok(view(status, accounts))
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
    let engine = CloudEngine::new(active.store.clone());
    engine.login(&endpoint, &username, &password).await?;
    drop(password);
    // Signing in establishes the session and nothing else. The answer must
    // arrive as soon as the session exists: a first sweep can take minutes on
    // a large library, and the user asked for the login result, not for the
    // download. Syncing is a separate, explicitly triggered action.
    reset_activity();
    current_status(&engine).await
}

pub async fn cloud_logout() -> Result<CloudStatusView, String> {
    let _guard = lock().await;
    let active = service()?;
    let engine = CloudEngine::new(active.store.clone());
    let status = tokio::task::spawn_blocking(move || engine.logout())
        .await
        .map_err(join_error)??;
    reset_activity();
    changed();
    let accounts = {
        let engine = CloudEngine::new(service()?.store.clone());
        tokio::task::spawn_blocking(move || engine.accounts())
            .await
            .map_err(join_error)??
    };
    Ok(view(status, accounts))
}

/// Read-only and deliberately not serialized: it must stay answerable while a
/// sync is running so the UI can show the live phase and counters.
pub async fn cloud_status() -> Result<CloudStatusView, String> {
    let active = service()?;
    let engine = CloudEngine::new(active.store.clone());
    current_status(&engine).await
}

pub async fn cloud_sync_now() -> Result<CloudSyncReportView, String> {
    let _guard = lock().await;
    let active = service()?;
    begin_activity();
    let engine = CloudEngine::new(active.store.clone())
        .with_change_observer(changed)
        .with_progress(apply_progress);
    let report = match engine.sync_now().await {
        Ok(report) => report,
        Err(error) => {
            end_activity("error", Some(error.clone()));
            return Err(error);
        }
    };
    changed();
    let error = report.error_code.clone();
    end_activity(if error.is_some() { "error" } else { "idle" }, error);
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

/// All cloud-bound photos, including other saved accounts: the UI keeps them
/// read-only even while a different account is selected.
pub async fn cloud_protected_media_ids() -> Result<Vec<String>, String> {
    let active = service()?;
    let engine = CloudEngine::new(active.store.clone());
    tokio::task::spawn_blocking(move || engine.protected_media_ids())
        .await
        .map_err(join_error)?
}

pub async fn cloud_switch_account(account_id: String) -> Result<CloudStatusView, String> {
    let _guard = lock().await;
    let active = service()?;
    let engine = CloudEngine::new(active.store.clone());
    tokio::task::spawn_blocking(move || engine.switch_account(&account_id))
        .await
        .map_err(join_error)??;
    reset_activity();
    let engine = CloudEngine::new(service()?.store.clone());
    current_status(&engine).await
}

pub async fn cloud_remove_account(account_id: String) -> Result<CloudStatusView, String> {
    let _guard = lock().await;
    let active = service()?;
    let engine = CloudEngine::new(active.store.clone());
    tokio::task::spawn_blocking(move || engine.remove_account(&account_id))
        .await
        .map_err(join_error)??;
    reset_activity();
    changed();
    let engine = CloudEngine::new(service()?.store.clone());
    current_status(&engine).await
}

pub async fn cloud_set_upload_scope(
    mode: String,
    albums: Vec<String>,
) -> Result<CloudStatusView, String> {
    let _guard = lock().await;
    let active = service()?;
    let engine = CloudEngine::new(active.store.clone());
    tokio::task::spawn_blocking(move || engine.set_upload_scope(&mode, albums))
        .await
        .map_err(join_error)??;
    let engine = CloudEngine::new(service()?.store.clone());
    current_status(&engine).await
}
