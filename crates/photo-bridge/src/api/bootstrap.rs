use crate::frb_generated::StreamSink;
use photo_core::runtime::BootstrapRuntime;
use photo_domain::profile::BuildProfile;
use std::sync::OnceLock;

pub(super) fn runtime() -> &'static BootstrapRuntime {
    static RUNTIME: OnceLock<BootstrapRuntime> = OnceLock::new();
    RUNTIME.get_or_init(BootstrapRuntime::default)
}

pub struct BootstrapSnapshot {
    pub profile_id: String,
    pub profile_digest: String,
    pub bridge_protocol_version: u32,
    pub session_id: String,
    pub status: String,
}

pub struct RuntimeEvent {
    pub sequence: u64,
    pub status: String,
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

pub async fn initialize(
    profile_json: String,
    expected_digest: String,
    bridge_protocol_version: u32,
) -> Result<BootstrapSnapshot, String> {
    let compiled_digest = crate::build_profile::PROFILE_DIGEST
        .ok_or_else(|| "BuildProfileMissing: native library has no build profile".to_owned())?;
    if expected_digest != compiled_digest {
        return Err("BuildProfileMismatch: Dart and compiled native profiles do not match".into());
    }
    let profile = BuildProfile::from_json(&profile_json)
        .and_then(|p| p.validate(&expected_digest, bridge_protocol_version))
        .map_err(|e| e.to_string())?;
    if !platform_linux::capabilities().linux_host {
        return Err("HostMismatch: Linux adapter is not available".into());
    }
    let snapshot = runtime().initialize(profile).map_err(|e| e.to_string())?;
    Ok(BootstrapSnapshot {
        profile_id: snapshot.profile_id,
        profile_digest: snapshot.profile_digest,
        bridge_protocol_version: snapshot.bridge_protocol_version,
        session_id: snapshot.session_id,
        status: snapshot.status,
    })
}

pub async fn round_trip(message: String) -> Result<String, String> {
    runtime().round_trip(message).map_err(|e| e.to_string())
}

pub async fn watch_runtime(sink: StreamSink<RuntimeEvent>) -> Result<(), String> {
    let (initial, mut receiver) = runtime().subscribe().map_err(|e| e.to_string())?;
    if sink
        .add(RuntimeEvent {
            sequence: initial.sequence,
            status: initial.status,
        })
        .is_err()
    {
        return Ok(());
    }
    loop {
        match receiver.recv().await {
            Ok(event) => {
                let closed = event.status == "closed";
                if sink
                    .add(RuntimeEvent {
                        sequence: event.sequence,
                        status: event.status,
                    })
                    .is_err()
                    || closed
                {
                    break;
                }
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                let (current, _) = runtime().subscribe().map_err(|e| e.to_string())?;
                let _ = sink.add(RuntimeEvent {
                    sequence: current.sequence,
                    status: "resync_required".into(),
                });
                break;
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        }
    }
    Ok(())
}

pub async fn shutdown() -> Result<(), String> {
    super::local_library::close_library().await?;
    runtime().shutdown().map_err(|e| e.to_string())
}
