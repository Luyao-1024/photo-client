//! Login, token file handling and session construction.
use std::fs::{self, File, OpenOptions};
use std::io::Write;

use syncserver_client as sdk;

use super::*;
use crate::local_library::CloudAccount;

pub(crate) struct CloudSession {
    pub(super) account: CloudAccount,
    pub(super) connection: sdk::Connection,
    pub(super) zone: sdk::ZoneId,
}

impl CloudEngine {
    pub async fn login(
        &self,
        endpoint: &str,
        username: &str,
        password: &str,
    ) -> Result<CloudStatus, String> {
        if self.library.is_closed() {
            return Err("LibraryClosed".into());
        }
        let username = username.trim();
        if username.is_empty() || password.is_empty() {
            return Err("AuthFailed".into());
        }
        let endpoint = sdk::Endpoint::parse(endpoint).map_err(|error| sdk_code(&error))?;
        let canonical = endpoint.as_str().to_owned();
        let existing = store(self.library.cloud_account())?;
        if let Some(account) = &existing
            && (account.endpoint != canonical || account.username != username)
        {
            return Err("AccountExists".into());
        }

        let client = sdk::Client::from_endpoint(endpoint)
            .build()
            .map_err(|error| sdk_code(&error))?;
        client
            .ready()
            .await
            .map_err(|error| sdk_code(&error))?;
        let session = client
            .login(username, password)
            .await
            .map_err(|error| sdk_code(&error))?;
        if session.user.is_admin() {
            return Err("AdminAccountUnsupported".into());
        }
        if let Some(account) = &existing
            && account
                .user_id
                .as_deref()
                .is_some_and(|user_id| user_id != session.user.id)
        {
            return Err("AccountExists".into());
        }
        let connection = client
            .connect()
            .await
            .map_err(|error| sdk_code(&error))?;
        connection
            .primary_zone()
            .map_err(|error| sdk_code(&error))?;

        let account_id = existing
            .as_ref()
            .map(|account| account.account_id.clone())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let device_id = existing
            .as_ref()
            .map(|account| account.device_id.clone())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        store(self.library.ensure_managed_cloud_source(&account_id))?;
        let path = token_path(&self.library.root, &account_id)?;
        write_token(&path, &session.access_token)?;
        let expires_at_ms = session.expires_at.saturating_mul(1000);
        let account = CloudAccount {
            account_id: account_id.clone(),
            endpoint: canonical,
            username: username.to_owned(),
            user_id: Some(session.user.id),
            token_file: format!("cloud/{account_id}/session.token"),
            token_expires_at_ms: Some(expires_at_ms),
            device_id,
            created_at_ms: existing
                .as_ref()
                .map(|account| account.created_at_ms)
                .unwrap_or_else(now_ms),
            last_sync_ms: existing.and_then(|account| account.last_sync_ms),
        };
        if let Err(error) = store(self.library.cloud_upsert_account(account)) {
            let _ = fs::remove_file(&path);
            return Err(error);
        }
        store(self.library.cloud_set_status(account_id, "idle".into(), None))?;
        self.status()
    }

    pub fn logout(&self) -> Result<CloudStatus, String> {
        if self.library.is_closed() {
            return Err("LibraryClosed".into());
        }
        let Some(account) = store(self.library.cloud_account())? else {
            return self.status();
        };
        if let Ok(path) = token_path(&self.library.root, &account.account_id) {
            let _ = fs::remove_file(path);
        }
        store(self.library.cloud_mark_logged_out(account.account_id))?;
        self.status()
    }

    pub(super) async fn open_session(&self) -> Result<CloudSession, String> {
        if self.library.is_closed() {
            return Err("LibraryClosed".into());
        }
        let account = store(self.library.cloud_account())?.ok_or("AuthFailed")?;
        let state = store(self.library.cloud_sync_state(account.account_id.clone()))?;
        if state.as_ref().is_none_or(|state| state.status == "logged_out") {
            return Err("AuthFailed".into());
        }
        if account
            .token_expires_at_ms
            .is_some_and(|expires| expires <= now_ms())
        {
            let _ = self.library.cloud_set_status(
                account.account_id.clone(),
                "token_expired".into(),
                Some("TokenExpired".into()),
            );
            return Err("TokenExpired".into());
        }
        let path = token_path(&self.library.root, &account.account_id)?;
        let token = fs::read_to_string(&path)
            .map_err(|_| {
                let _ = self.library.cloud_set_status(
                    account.account_id.clone(),
                    "error".into(),
                    Some("AuthFailed".into()),
                );
                "AuthFailed".to_owned()
            })?
            .trim()
            .to_owned();
        if token.is_empty() {
            return Err("AuthFailed".into());
        }
        let client = sdk::Client::builder(&account.endpoint)
            .map_err(|error| sdk_code(&error))?
            .access_token(token)
            .build()
            .map_err(|error| sdk_code(&error))?;
        let fail = |error: sdk::Error| {
            let code = sdk_code(&error);
            let _ = self.library.cloud_set_status(
                account.account_id.clone(),
                "error".into(),
                Some(code.clone()),
            );
            code
        };
        client.ready().await.map_err(|error| fail(error))?;
        let connection = client.connect().await.map_err(|error| fail(error))?;
        let zone = connection.primary_zone().map_err(|error| fail(error))?;
        if let Some(user) = connection
            .scope()
            .authentication
            .as_ref()
            .and_then(|authentication| authentication.user.as_ref())
            && account
                .user_id
                .as_deref()
                .is_some_and(|user_id| user_id != user.id)
        {
            let _ = self.library.cloud_set_status(
                account.account_id.clone(),
                "error".into(),
                Some("AuthFailed".into()),
            );
            return Err("AuthFailed".into());
        }
        Ok(CloudSession {
            account,
            connection,
            zone,
        })
    }
}

fn write_token(path: &Path, token: &str) -> Result<(), String> {
    let directory = path.parent().ok_or("Internal")?;
    fs::create_dir_all(directory).map_err(|_| "Internal")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(directory, fs::Permissions::from_mode(0o700));
    }
    let temporary = directory.join(format!(".session.token.{}", Uuid::new_v4()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| -> std::io::Result<()> {
        let mut file = options.open(&temporary)?;
        file.write_all(token.as_bytes())?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        File::open(directory)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|_| "Internal".into())
}
