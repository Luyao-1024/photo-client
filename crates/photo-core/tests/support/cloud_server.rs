//! An opt-in real server fixture. Each case owns an isolated account, server
//! directory and client catalog; no desktop or real library is involved.
//!
//! # Lifetime guarantees
//!
//! The server is a real process, so it has to be guaranteed to stop when the
//! test ends. Three mechanisms cover the ways a test run can end:
//!
//! 1. **Process group** — the server leads its own process group (`setpgid`),
//!    so the terminal's Ctrl-C does not reach it and the fixture, not the
//!    terminal, decides when it stops.
//! 2. **`PR_SET_PDEATHSIG`** — the server asks the kernel to `SIGKILL` it
//!    when the test binary dies. This is the backstop for a run that ends
//!    without running any destructor: an interrupted `cargo test`, a killed
//!    test binary or a reboot. The kernel enforces it, so it holds even when
//!    the parent is killed with `SIGKILL`.
//! 3. **`Drop`** — the ordinary path. The server is asked to stop
//!    gracefully (`SIGTERM`, which the service handles by draining) and is
//!    then reaped; one that ignores the request is killed outright.
//!
//! Without these, an interrupted run leaves the server holding its
//! data-directory lock and its listening socket, and the next run cannot
//! bind the port it expects.
use std::{
    fs::{self, File},
    io::Write,
    net::TcpListener,
    os::unix::process::CommandExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant, UNIX_EPOCH},
};

use photo_core::{
    cloud::{CloudEngine, CloudSyncReport},
    local_library::{LocalLibrary, MediaInput, PhotoFilter},
};
use rusqlite::Connection;
use syncserver_client as sdk;
use tempfile::TempDir;

/// A running server process that is guaranteed to be gone when the test ends.
struct ServerProcess {
    child: Child,
    /// The process group the child leads. Signalling the group rather than
    /// the single pid reaches any helper the server itself started.
    group: i32,
}

impl ServerProcess {
    fn spawn(command: &mut Command) -> std::io::Result<Self> {
        // SAFETY: `pre_exec` runs in the forked child before `execve`. The
        // closure only calls async-signal-safe syscalls (`setpgid`,
        // `prctl`), takes no locks and allocates nothing, which is what
        // `pre_exec` requires.
        unsafe {
            command.pre_exec(|| {
                // Own process group: the terminal's SIGINT must not reach the
                // server, so only the fixture stops it.
                if libc::setpgid(0, 0) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                // Kernel backstop: if the parent dies without running its
                // destructors, the kernel kills this child.
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL as libc::c_ulong) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn()?;
        // The child is its own group leader, so its pid is the group id.
        let group = child.id() as i32;
        Ok(Self { child, group })
    }

    /// Stop the server and reap it.
    ///
    /// `SIGTERM` first, because the service drains its state on that signal
    /// and releases the data-directory lock cleanly. A server that has not
    /// exited within the grace period is killed, so a wedged process cannot
    /// hold the test suite open.
    fn stop(&mut self) {
        if self.child.try_wait().ok().flatten().is_some() {
            return;
        }
        // SAFETY: `kill` with a negative pid signals the process group; the
        // group id was obtained from the child's own pid right after `spawn`.
        unsafe {
            libc::kill(-self.group, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match self.child.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) => std::thread::sleep(Duration::from_millis(20)),
                Err(_) => break,
            }
        }
        // SAFETY: as above; `SIGKILL` cannot be ignored or blocked.
        unsafe {
            libc::kill(-self.group, libc::SIGKILL);
        }
        let _ = self.child.wait();
    }
}

impl Drop for ServerProcess {
    fn drop(&mut self) {
        self.stop();
    }
}

pub struct Server {
    pub endpoint: String,
    pub password: String,
    child: ServerProcess,
    _root: TempDir,
}

impl Server {
    pub async fn start() -> Self {
        let binary = std::env::var_os("PHOTO_SYNC_SERVER_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../../syncserver/target/release/syncserver")
            });
        assert!(
            binary.is_file(),
            "build the adjacent SyncServer or set PHOTO_SYNC_SERVER_BIN"
        );
        let root = tempfile::tempdir().unwrap();
        // A fixed key is sufficient for this private, disposable test server.
        let key = root.path().join("signing.key");
        fs::write(&key, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&key, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let endpoint = format!("http://127.0.0.1:{port}");
        let password = uuid::Uuid::new_v4().to_string();
        let mut command = Command::new(&binary);
        command
            .env("SYNC_DATA_DIR", root.path().join("data"))
            .env("SYNC_SIGNING_KEY_FILE", root.path().join("signing.key"))
            .env("SYNC_BIND", format!("127.0.0.1:{port}"))
            .env("SYNC_PUBLIC_BASE_URL", &endpoint)
            .env("SYNC_LOG_PAYLOAD", "off");
        let mut create = command
            .args(["users", "create", "review", "--password-stdin"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        writeln!(create.stdin.take().unwrap(), "{password}").unwrap();
        let result = create.wait_with_output().unwrap();
        assert!(
            result.status.success(),
            "user creation failed: {}",
            String::from_utf8_lossy(&result.stderr)
        );
        // Command arguments persist across spawn calls; build a fresh serve command.
        let mut serve = Command::new(&binary);
        serve
            .envs(command.get_envs().map(|(key, value)| (key, value.unwrap())))
            .stdout(File::create(root.path().join("server.log")).unwrap())
            .stderr(Stdio::null());
        let child = ServerProcess::spawn(&mut serve).unwrap();
        let mut server = Self {
            endpoint,
            password,
            child,
            _root: root,
        };
        let client = sdk::Client::builder(&server.endpoint)
            .unwrap()
            .request_timeout(Duration::from_secs(1))
            .build()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            if client.ready().await.is_ok() {
                break;
            }
            assert!(
                server.child.child.try_wait().unwrap().is_none() && Instant::now() < deadline,
                "server did not start: {}",
                fs::read_to_string(server._root.path().join("server.log")).unwrap_or_default(),
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        server
    }
}

pub struct Fixture {
    pub _server: Server,
    pub library: LocalLibrary,
    pub engine: CloudEngine,
    pub db: Connection,
    pub _root: TempDir,
    pub _originals: TempDir,
    pub file: PathBuf,
    pub media_id: String,
    pub photo_id: String,
    pub initial_token: String,
    pub connection: sdk::Connection,
    pub zone: sdk::ZoneId,
}

pub fn successful(report: &CloudSyncReport) {
    assert_eq!(report.failed, 0, "{report:?}");
    assert_eq!(report.error_code, None, "{report:?}");
}

impl Fixture {
    pub async fn uploaded() -> Self {
        Self::uploaded_with_favorite(false).await
    }

    pub async fn uploaded_with_favorite(favorite: bool) -> Self {
        let server = Server::start().await;
        let root = tempfile::tempdir().unwrap();
        let originals = tempfile::tempdir().unwrap();
        let file = originals.path().join("review.jpg");
        image::RgbImage::from_pixel(16, 12, image::Rgb([50, 100, 150]))
            .save(&file)
            .unwrap();
        let metadata = fs::metadata(&file).unwrap();
        let library = LocalLibrary::open(root.path()).unwrap();
        let source = library.add_source(originals.path()).unwrap();
        library
            .upsert_batch(
                source,
                vec![MediaInput {
                    path: file.to_str().unwrap().into(),
                    name: "review.jpg".into(),
                    parent: originals.path().to_str().unwrap().into(),
                    size_bytes: metadata.len(),
                    modified_ns: metadata
                        .modified()
                        .unwrap()
                        .duration_since(UNIX_EPOCH)
                        .unwrap()
                        .as_nanos() as i64,
                    mime_type: "image/jpeg".into(),
                    width: Some(16),
                    height: Some(12),
                    orientation: 1,
                    capture_time_ms: Some(1_700_000_000_000),
                }],
            )
            .unwrap();
        let media_id = library
            .query(PhotoFilter::default(), None, 100)
            .unwrap()
            .items[0]
            .id
            .clone();
        let engine = CloudEngine::new(library.clone());
        engine
            .login(&server.endpoint, "review", &server.password)
            .await
            .unwrap();
        successful(&engine.sync_now().await.unwrap());
        let db = Connection::open(root.path().join("library.sqlite")).unwrap();
        let initial_token = db
            .query_row("SELECT sync_token FROM cloud_sync_state", [], |r| r.get(0))
            .unwrap();
        if favorite {
            library.set_favorite(media_id.clone(), true).unwrap();
            // This was edited offline, long before the server create commits.
            db.execute(
                "UPDATE media_sync_state SET edited_at_ms=1700000000123 WHERE media_id=?1",
                [&media_id],
            )
            .unwrap();
        }
        let thumbnails = photo_core::thumbnail_loader::ThumbnailLoader::new(library.clone(), 1);
        thumbnails
            .request(media_id.clone(), None, 512, "fixture".into(), 0)
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        thumbnails.close();
        assert_eq!(
            engine.queue_upload(vec![media_id.clone()]).unwrap().queued,
            1
        );
        let report = engine.sync_now().await.unwrap();
        successful(&report);
        assert_eq!(report.uploaded, 1, "{report:?}");
        let photo_id = db
            .query_row("SELECT photo_id FROM cloud_bindings", [], |r| r.get(0))
            .unwrap();
        let account = fs::read_dir(root.path().join("cloud"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        let token = fs::read_to_string(account.join("session.token")).unwrap();
        let connection = sdk::Client::builder(&server.endpoint)
            .unwrap()
            .access_token(token)
            .build()
            .unwrap()
            .connect()
            .await
            .unwrap();
        let zone = connection.primary_zone().unwrap();
        Self {
            _server: server,
            library,
            engine,
            db,
            _root: root,
            _originals: originals,
            file,
            media_id,
            photo_id,
            initial_token,
            connection,
            zone,
        }
    }

    pub async fn modify_lease(&self) -> sdk::UploadLease {
        successful(&self.engine.sync_now().await.unwrap());
        let applied: String = self
            .db
            .query_row("SELECT sync_token FROM cloud_sync_state", [], |r| r.get(0))
            .unwrap();
        let lease =
            sdk::UploadLease::acquire(&self.connection, "regression-other-device", &self.zone)
                .await
                .unwrap();
        let check = lease.check(&applied, true).await.unwrap();
        assert!(check.is_current && check.may_upload);
        assert_eq!(
            lease.advance_phase().await.unwrap(),
            Some(sdk::UploadPhase::Modify)
        );
        lease
    }

    pub fn lose_create_acknowledgement(&self) {
        // The durable boundary immediately after the remote create committed,
        // before its local binding transaction committed. Keep the upload IDs.
        self.db.execute_batch("BEGIN; DELETE FROM cloud_bindings; DELETE FROM cloud_records; UPDATE cloud_uploads SET state='publishing';").unwrap();
        self.db
            .execute(
                "UPDATE cloud_sync_state SET sync_token=?1",
                [&self.initial_token],
            )
            .unwrap();
        self.db.execute_batch("COMMIT;").unwrap();
    }

    pub async fn create_at(&self, lease: &sdk::UploadLease, path: String) -> sdk::RemotePhoto {
        let original = sdk::AssetUpload::from_file(self.file.clone(), "image/jpeg")
            .await
            .unwrap();
        let thumbnail = sdk::AssetUpload::from_file(self.file.clone(), "image/jpeg")
            .await
            .unwrap();
        self.connection
            .create_photo(
                lease,
                sdk::PhotoUpload::new(sdk::PhotoMetadata::new(path), original, thumbnail),
            )
            .await
            .unwrap()
    }
}
