//! Cloud synchronization orchestration.
//!
//! Every protocol operation goes through the pinned `sync-client` SDK. This
//! module owns persistence, ordering and the stable error vocabulary; it never
//! speaks HTTP itself.
mod auth;
mod downlink;
pub(crate) mod paths;
mod records;
mod uplink;

use std::path::{Path, PathBuf};

use syncserver_client as sdk; // imported for submodules via `use super::*`
use uuid::Uuid;

use crate::local_library::{CloudQueueCounts, CloudUploadIntent, LocalLibrary};

pub use auth::CloudAccountState;
use auth::CloudSession;

#[derive(Clone, Debug, Default)]
pub struct CloudStatus {
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
    pub download_root: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct CloudSyncReport {
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

/// Progress emitted while a sweep runs. The bridge turns it into the detailed
/// status the settings page shows; it is never protocol state.
#[derive(Clone, Debug, Default)]
pub struct CloudProgress {
    pub phase: String,
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

#[derive(Clone, Copy, Debug, Default)]
pub struct CloudQueueResult {
    pub queued: u32,
    pub skipped: u32,
    pub rejected: u32,
}

#[derive(Clone)]
pub struct CloudEngine {
    library: LocalLibrary,
    observer: Option<std::sync::Arc<ChangeObserver>>,
    progress: Option<std::sync::Arc<dyn Fn(CloudProgress) + Send + Sync>>,
}
struct ChangeObserver {
    callback: Box<dyn Fn() + Send + Sync>,
    last: std::sync::Mutex<std::time::Instant>,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

/// Catalog failures are mapped to a stable, non-sensitive code. Only explicit
/// lifecycle codes keep their meaning; details never reach the UI or database.
pub(super) fn store<T>(result: Result<T, String>) -> Result<T, String> {
    result.map_err(|error| match error.as_str() {
        "LibraryClosed" => "LibraryClosed".to_owned(),
        _ => "Internal".to_owned(),
    })
}

pub(super) fn sdk_code(error: &sdk::Error) -> String {
    syncserver_client::error_code(error).to_owned()
}

pub(super) fn note_failure(report: &mut CloudSyncReport, code: &str) {
    report.failed += 1;
    if report.error_code.is_none() {
        report.error_code = Some(code.to_owned());
    }
}

pub(super) fn fatal(code: &str) -> bool {
    matches!(
        code,
        "Network"
            | "AuthFailed"
            | "LeaseBusy"
            | "LeaseLost"
            | "NotCurrent"
            | "LibraryClosed"
            | "TokenExpired"
    )
}

fn upload_intent(
    media_id: &str,
    path: &str,
    name: &str,
    mime_type: &str,
    content_version: u64,
    size_bytes: u64,
    modified_ns: i64,
    sort_time_ms: i64,
    album: &str,
) -> Option<CloudUploadIntent> {
    let extension = paths::upload_extension(Path::new(path), mime_type)?;
    let generation = Uuid::new_v4().to_string();
    let photo_id = Uuid::new_v4().to_string();
    let master_id = Uuid::new_v4().to_string();
    let relative_path =
        paths::upload_relative_path(album, name, media_id, &generation, &extension, sort_time_ms);
    syncserver_client::photo::is_safe_relative_path(&relative_path).then(|| CloudUploadIntent {
        media_id: media_id.to_owned(),
        content_generation: generation.clone(),
        photo_id: photo_id.clone(),
        master_id,
        relative_path,
        operation_id: sdk::create_operation_id(&photo_id, &generation),
        content_version,
        size_bytes,
        modified_ns,
    })
}

pub(super) fn token_path(root: &Path, account_id: &str) -> Result<PathBuf, String> {
    if account_id.is_empty()
        || !account_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return Err("Internal".into());
    }
    Ok(root.join("cloud").join(account_id).join("session.token"))
}

impl CloudEngine {
    pub fn new(library: LocalLibrary) -> Self {
        Self {
            library,
            observer: None,
            progress: None,
        }
    }

    pub fn with_progress(
        mut self,
        callback: impl Fn(CloudProgress) + Send + Sync + 'static,
    ) -> Self {
        self.progress = Some(std::sync::Arc::new(callback));
        self
    }

    pub fn with_change_observer(mut self, callback: impl Fn() + Send + Sync + 'static) -> Self {
        self.observer = Some(std::sync::Arc::new(ChangeObserver {
            callback: Box::new(callback),
            last: std::sync::Mutex::new(
                std::time::Instant::now() - std::time::Duration::from_secs(1),
            ),
        }));
        self
    }

    pub(super) fn notify(&self, phase: &str, report: &CloudSyncReport) {
        let Some(callback) = &self.progress else {
            return;
        };
        callback(CloudProgress {
            phase: phase.to_owned(),
            downloaded: report.downloaded,
            download_total: report.download_total,
            uploaded: report.uploaded,
            upload_total: report.upload_total,
            favorites_applied: report.favorites_applied,
            favorites_uploaded: report.favorites_uploaded,
            favorite_total: report.favorite_total,
            skipped: report.skipped,
            failed: report.failed,
            error_code: report.error_code.clone(),
        });
    }

    fn admitted(&self, force: bool) {
        let Some(observer) = &self.observer else {
            return;
        };
        let notify = {
            let mut last = observer.last.lock().unwrap();
            if force || last.elapsed() >= std::time::Duration::from_millis(300) {
                *last = std::time::Instant::now();
                true
            } else {
                false
            }
        };
        if notify {
            (observer.callback)();
        }
    }

    pub fn status(&self) -> Result<CloudStatus, String> {
        if self.library.is_closed() {
            return Err("LibraryClosed".into());
        }
        let account = store(self.library.cloud_account())?;
        let Some(account) = account else {
            return Ok(CloudStatus {
                state: "logged_out".into(),
                ..CloudStatus::default()
            });
        };
        let state = store(self.library.cloud_sync_state(account.account_id.clone()))?;
        let counts = store(self.library.cloud_counts(account.account_id.clone()))?;
        let upload_albums = store(self.library.cloud_upload_albums(account.account_id.clone()))?;
        let sync_state = state.unwrap_or_default();
        let token_present = token_path(&self.library.root, &account.account_id)
            .map(|path| path.is_file())
            .unwrap_or(false);
        let expired = account
            .token_expires_at_ms
            .is_some_and(|expires| expires <= now_ms());
        let auth_failed = sync_state.error_code.as_deref() == Some("AuthFailed");
        let logged_in = token_present
            && !expired
            && sync_state.status != "logged_out"
            && sync_state.status != "token_expired"
            && !auth_failed;
        let state = if sync_state.status == "logged_out" {
            "logged_out".to_owned()
        } else if expired {
            "token_expired".to_owned()
        } else {
            sync_state.status.clone()
        };
        Ok(CloudStatus {
            logged_in,
            account_id: Some(account.account_id),
            endpoint: Some(account.endpoint),
            username: Some(account.username),
            user_id: account.user_id,
            token_expires_at_ms: account.token_expires_at_ms,
            last_sync_ms: sync_state.last_sync_ms.or(account.last_sync_ms),
            state,
            error_code: sync_state.error_code,
            pending_uploads: counts.pending_uploads,
            failed_uploads: counts.failed_uploads,
            pending_favorites: counts.pending_favorites,
            bound_count: counts.bound,
            upload_scope: account.upload_scope,
            upload_albums,
            download_root: account.download_root,
        })
    }

    /// The automatic-sync switch, read from the same preferences the settings
    /// page writes. Automatic work is opt-in, so a missing value means off.
    pub fn auto_sync_enabled(&self) -> Result<bool, String> {
        let preferences: serde_json::Value =
            serde_json::from_str(&store(self.library.preferences())?).map_err(|_| "Internal")?;
        Ok(preferences
            .get("cloudAutoSync")
            .and_then(|value| value.as_bool())
            .unwrap_or(false))
    }

    /// Whether an unattended sweep would find durable work. This is what keeps
    /// the local-change trigger from turning into an idle remote poll.
    pub fn auto_sync_needed(&self) -> Result<bool, String> {
        let status = self.status()?;
        if !status.logged_in
            || matches!(
                status.error_code.as_deref(),
                Some("AuthFailed" | "TokenExpired" | "CloudScopeChanged")
            )
        {
            return Ok(false);
        }
        if status.pending_uploads > 0 || status.pending_favorites > 0 {
            return Ok(true);
        }
        let Some(account_id) = status.account_id else {
            return Ok(false);
        };
        match status.upload_scope.as_str() {
            "all" => store(self.library.cloud_scope_has_candidates(account_id, true)),
            "selected" => store(self.library.cloud_scope_has_candidates(account_id, false)),
            _ => Ok(false),
        }
    }

    pub async fn sync_now(&self) -> Result<CloudSyncReport, String> {
        if self.library.is_closed() {
            return Err("LibraryClosed".into());
        }
        let session = self.open_session().await?;
        let mut report = CloudSyncReport::default();
        self.notify("preparing", &report);
        // The chosen album scope is a standing upload instruction: each sweep
        // enrolls local photos it has not sent yet, while the explicit per-photo
        // upload remains available.
        let _ = self.queue_scope_uploads(&session.account, &mut report);
        if let Err(code) = self
            .recover_metadata_operations(&session, &mut report)
            .await
        {
            return Ok(self.failed_report(&session, report, &code));
        }
        if let Err(code) = self.downlink(&session, &mut report).await {
            return Ok(self.failed_report(&session, report, &code));
        }
        match self.uplink(&session, &mut report).await {
            Ok(()) => {}
            Err(code) if code == "NotCurrent" => {
                // Catch up once, then retry the lease gate exactly once.
                if let Err(code) = self.downlink(&session, &mut report).await {
                    return Ok(self.failed_report(&session, report, &code));
                }
                if let Err(code) = self.uplink(&session, &mut report).await {
                    return Ok(self.failed_report(&session, report, &code));
                }
            }
            Err(code) => return Ok(self.failed_report(&session, report, &code)),
        }
        // A new photo is created in the final lease phase. Publish any local
        // edit stamp in a following modify lease, preserving the original edit
        // time rather than accepting the server's create/commit time as it.
        if report.uploaded > 0 && report.failed == 0 {
            let counts = store(
                self.library
                    .cloud_counts(session.account.account_id.clone()),
            )?;
            if counts.pending_uploads > 0 || counts.pending_favorites > 0 {
                if let Err(code) = self.downlink(&session, &mut report).await {
                    return Ok(self.failed_report(&session, report, &code));
                }
                if let Err(code) = self.uplink(&session, &mut report).await {
                    return Ok(self.failed_report(&session, report, &code));
                }
            }
        }
        self.notify("finalizing", &report);
        if report.failed > 0 {
            report.state = "error".into();
            let code = report
                .error_code
                .clone()
                .unwrap_or_else(|| "Internal".into());
            let _ = self.library.cloud_set_status(
                session.account.account_id.clone(),
                "error".into(),
                Some(code),
            );
            self.notify("error", &report);
            return Ok(report);
        }
        report.state = "idle".into();
        report.error_code = None;
        let _ =
            self.library
                .cloud_set_status(session.account.account_id.clone(), "idle".into(), None);
        self.notify("idle", &report);
        Ok(report)
    }

    fn failed_report(
        &self,
        session: &CloudSession,
        mut report: CloudSyncReport,
        code: &str,
    ) -> CloudSyncReport {
        if report.failed == 0 {
            report.failed = 1;
        }
        report.error_code = Some(code.to_owned());
        report.state = if code == "TokenExpired" {
            "token_expired"
        } else {
            "error"
        }
        .into();
        if code != "LibraryClosed" {
            let status = if code == "TokenExpired" {
                "token_expired"
            } else {
                "error"
            };
            let _ = self.library.cloud_set_status(
                session.account.account_id.clone(),
                status.into(),
                Some(code.to_owned()),
            );
        }
        self.notify("error", &report);
        report
    }

    pub fn queue_upload(&self, media_ids: Vec<String>) -> Result<CloudQueueResult, String> {
        if self.library.is_closed() {
            return Err("LibraryClosed".into());
        }
        let account = store(self.library.cloud_account())?.ok_or("AuthFailed")?;
        if !self.status()?.logged_in {
            return Err("AuthFailed".into());
        }
        let mut seen = std::collections::HashSet::new();
        let mut intents = Vec::new();
        let mut rejected = 0;
        for media_id in media_ids {
            if !seen.insert(media_id.clone()) {
                continue;
            }
            let photo = match store(self.library.photo(media_id.clone())) {
                Ok(photo) => photo,
                Err(_) => {
                    rejected += 1;
                    continue;
                }
            };
            // The album travels with the photo: the cloud path mirrors the
            // local album, so a download lands in the same album again.
            let album =
                store(self.library.cloud_album_relative_path(&photo.id))?.unwrap_or_default();
            let Some(intent) = upload_intent(
                &photo.id,
                &photo.path,
                &photo.name,
                &photo.mime_type,
                photo.content_version,
                photo.size_bytes,
                photo.modified_ns,
                photo.sort_time_ms,
                &album,
            ) else {
                rejected += 1;
                continue;
            };
            intents.push(intent);
        }
        let counts: CloudQueueCounts = store(
            self.library
                .cloud_queue_uploads(account.account_id, intents),
        )?;
        Ok(CloudQueueResult {
            queued: counts.queued,
            skipped: counts.skipped,
            rejected: rejected + counts.rejected,
        })
    }

    /// Enroll local photos covered by the account's standing upload scope.
    /// Explicit photo upload and this scope share the same durable intents.
    fn queue_scope_uploads(
        &self,
        account: &crate::local_library::CloudAccount,
        report: &mut CloudSyncReport,
    ) -> Result<(), String> {
        let all_albums = account.upload_scope == "all";
        if !all_albums && account.upload_scope != "selected" {
            return Ok(());
        }
        let candidates = store(
            self.library
                .cloud_scope_candidates(account.account_id.clone(), all_albums),
        )?;
        let mut intents = Vec::with_capacity(candidates.len());
        for candidate in candidates {
            let album = Path::new(&candidate.parent)
                .strip_prefix(&candidate.root)
                .ok()
                .map(|path| path.to_string_lossy().replace('\\', "/"))
                .filter(|path| !path.is_empty())
                .unwrap_or_default();
            let Some(intent) = upload_intent(
                &candidate.media_id,
                &candidate.path,
                &candidate.name,
                &candidate.mime_type,
                candidate.content_version,
                candidate.size_bytes,
                candidate.modified_ns,
                candidate.sort_time_ms,
                &album,
            ) else {
                report.skipped += 1;
                continue;
            };
            intents.push(intent);
        }
        let counts = store(
            self.library
                .cloud_queue_uploads(account.account_id.clone(), intents),
        )?;
        report.skipped += counts.skipped + counts.rejected;
        Ok(())
    }

    pub fn bound_media_ids(&self) -> Result<Vec<String>, String> {
        if self.library.is_closed() {
            return Err("LibraryClosed".into());
        }
        let Some(account) = store(self.library.cloud_account())? else {
            return Ok(Vec::new());
        };
        store(
            self.library
                .cloud_account_bound_media_ids(account.account_id),
        )
    }

    pub fn protected_media_ids(&self) -> Result<Vec<String>, String> {
        if self.library.is_closed() {
            return Err("LibraryClosed".into());
        }
        store(self.library.cloud_bound_media_ids())
    }
}

#[cfg(test)]
mod scope_tests {
    use super::*;
    use crate::local_library::{CloudAccount, LocalLibrary, MediaInput, PhotoFilter};
    use std::fs;

    #[test]
    fn selected_album_scope_queues_only_that_album() {
        let root = tempfile::TempDir::new().unwrap();
        let photos = tempfile::TempDir::new().unwrap();
        let selected = photos.path().join("Selected");
        let other = photos.path().join("Other");
        fs::create_dir_all(&selected).unwrap();
        fs::create_dir_all(&other).unwrap();
        let mut inputs = Vec::new();
        for folder in [&selected, &other] {
            let name = if folder == &selected {
                "one.jpg"
            } else {
                "two.jpg"
            };
            let path = folder.join(name);
            fs::write(&path, b"scope fixture").unwrap();
            let modified_ns = fs::metadata(&path)
                .unwrap()
                .modified()
                .unwrap()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos() as i64;
            inputs.push(MediaInput {
                path: path.to_string_lossy().into(),
                name: name.into(),
                parent: folder.to_string_lossy().into(),
                size_bytes: 13,
                modified_ns,
                mime_type: "image/jpeg".into(),
                width: Some(4),
                height: Some(2),
                orientation: 1,
                capture_time_ms: Some(1_700_000_000_000),
            });
        }
        let library = LocalLibrary::open(root.path()).unwrap();
        let source = library.add_source(photos.path()).unwrap();
        library.upsert_batch(source, inputs).unwrap();
        library
            .cloud_upsert_account(CloudAccount {
                account_id: "account".into(),
                endpoint: "http://127.0.0.1:8790".into(),
                username: "alice".into(),
                user_id: Some("user".into()),
                token_file: "cloud/account/session.token".into(),
                token_expires_at_ms: None,
                device_id: "device".into(),
                created_at_ms: 1,
                last_sync_ms: None,
                upload_scope: "none".into(),
                is_active: true,
                download_root: None,
            })
            .unwrap();
        library.cloud_set_active_account("account".into()).unwrap();
        library
            .cloud_set_upload_scope(
                "account".into(),
                "selected".into(),
                vec![selected.to_string_lossy().into()],
            )
            .unwrap();
        let account = library.cloud_account().unwrap().unwrap();
        assert!(
            library
                .cloud_scope_has_candidates("account".into(), false)
                .unwrap()
        );
        assert!(
            library
                .cloud_scope_has_candidates("account".into(), true)
                .unwrap()
        );
        let engine = CloudEngine::new(library.clone());
        let mut report = CloudSyncReport::default();
        engine.queue_scope_uploads(&account, &mut report).unwrap();

        // The selected album has been enrolled; the other album is not in the
        // selected scope and must not keep the scheduler awake.
        assert!(
            !library
                .cloud_scope_has_candidates("account".into(), false)
                .unwrap()
        );
        assert!(
            library
                .cloud_scope_has_candidates("account".into(), true)
                .unwrap()
        );
        let pending = library.cloud_pending_uploads("account".into()).unwrap();
        assert_eq!(pending.len(), 1);
        assert!(pending[0].relative_path.starts_with("Selected/"));
        assert_eq!(
            library
                .query(PhotoFilter::default(), None, 10)
                .unwrap()
                .total,
            2
        );
    }
}
