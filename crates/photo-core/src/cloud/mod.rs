//! Cloud synchronization orchestration.
//!
//! Every protocol operation goes through the pinned `sync-client` SDK. This
//! module owns persistence, ordering and the stable error vocabulary; it never
//! speaks HTTP itself.
mod auth;
mod downlink;
mod paths;
mod records;
mod uplink;

use std::path::{Path, PathBuf};

use syncserver_client as sdk; // imported for submodules via `use super::*`
use uuid::Uuid;

use crate::local_library::{CloudQueueCounts, CloudUploadIntent, LocalLibrary};

use auth::CloudSession;

#[derive(Clone, Debug, Default)]
pub struct CloudStatus {
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
}

#[derive(Clone, Debug, Default)]
pub struct CloudSyncReport {
    pub downloaded: u32,
    pub uploaded: u32,
    pub favorites_applied: u32,
    pub favorites_uploaded: u32,
    pub skipped: u32,
    pub failed: u32,
    pub state: String,
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
        }
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
            endpoint: Some(account.endpoint),
            username: Some(account.username),
            user_id: account.user_id,
            token_expires_at_ms: account.token_expires_at_ms,
            last_sync_ms: sync_state.last_sync_ms.or(account.last_sync_ms),
            state,
            error_code: sync_state.error_code,
            pending_uploads: counts.pending_uploads,
            pending_favorites: counts.pending_favorites,
            bound_count: counts.bound,
        })
    }

    pub async fn sync_now(&self) -> Result<CloudSyncReport, String> {
        if self.library.is_closed() {
            return Err("LibraryClosed".into());
        }
        let session = self.open_session().await?;
        let mut report = CloudSyncReport::default();
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
        if report.uploaded > 0
            && report.failed == 0
            && store(
                self.library
                    .cloud_counts(session.account.account_id.clone()),
            )?
            .pending_favorites
                > 0
        {
            if let Err(code) = self.downlink(&session, &mut report).await {
                return Ok(self.failed_report(&session, report, &code));
            }
            if let Err(code) = self.uplink(&session, &mut report).await {
                return Ok(self.failed_report(&session, report, &code));
            }
        }
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
            return Ok(report);
        }
        report.state = "idle".into();
        report.error_code = None;
        let _ =
            self.library
                .cloud_set_status(session.account.account_id.clone(), "idle".into(), None);
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
        let mut skipped = 0;
        let bound = store(self.library.cloud_bound_media_ids())?
            .into_iter()
            .collect::<std::collections::HashSet<_>>();
        for media_id in media_ids {
            if !seen.insert(media_id.clone()) {
                continue;
            }
            if bound.contains(&media_id) {
                skipped += 1;
                continue;
            }
            let photo = match store(self.library.photo(media_id.clone())) {
                Ok(photo) => photo,
                Err(_) => {
                    rejected += 1;
                    continue;
                }
            };
            if photo.state != "active" {
                rejected += 1;
                continue;
            }
            let extension = match paths::upload_extension(Path::new(&photo.path), &photo.mime_type)
            {
                Some(extension) => extension,
                None => {
                    rejected += 1;
                    continue;
                }
            };
            let generation = Uuid::new_v4().to_string();
            let photo_id = Uuid::new_v4().to_string();
            let master_id = Uuid::new_v4().to_string();
            let relative_path = paths::upload_relative_path(
                &photo.name,
                &photo.id,
                &generation,
                &extension,
                photo.sort_time_ms,
            );
            if !syncserver_client::photo::is_safe_relative_path(&relative_path) {
                rejected += 1;
                continue;
            }
            intents.push(CloudUploadIntent {
                media_id: photo.id,
                content_generation: generation.clone(),
                photo_id: photo_id.clone(),
                master_id,
                relative_path,
                operation_id: sdk::create_operation_id(&photo_id, &generation),
                content_version: photo.content_version,
                size_bytes: photo.size_bytes,
                modified_ns: photo.modified_ns,
            });
        }
        let counts: CloudQueueCounts = store(
            self.library
                .cloud_queue_uploads(account.account_id, intents),
        )?;
        Ok(CloudQueueResult {
            queued: counts.queued,
            skipped: counts.skipped + skipped,
            rejected: rejected + counts.rejected,
        })
    }

    pub fn bound_media_ids(&self) -> Result<Vec<String>, String> {
        if self.library.is_closed() {
            return Err("LibraryClosed".into());
        }
        store(self.library.cloud_bound_media_ids())
    }
}
