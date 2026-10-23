use photo_core::runtime::{BootstrapRuntime, RuntimeError};
use photo_domain::profile::BuildProfile;

fn profile() -> photo_domain::profile::ValidatedProfile {
    let examples: serde_json::Value = serde_json::from_str(include_str!(
        "../../../docs/design/contracts/platform-profiles.json"
    ))
    .unwrap();
    let profile: BuildProfile = serde_json::from_value(examples["profiles"][0].clone()).unwrap();
    profile
        .clone()
        .validate(&profile.digest().unwrap(), 1)
        .unwrap()
}

#[tokio::test]
async fn async_round_trip_and_events_use_the_same_runtime() {
    let runtime = BootstrapRuntime::default();
    let snapshot = runtime.initialize(profile()).unwrap();
    assert_eq!(snapshot.status, "bridge_ready");
    let (initial, mut events) = runtime.subscribe().unwrap();
    assert_eq!(initial.status, "bridge_ready");
    assert_eq!(runtime.round_trip("照片".into()).unwrap(), "照片");
    let event = events.recv().await.unwrap();
    assert_eq!(event.status, "round_trip_complete");
    assert!(event.sequence > initial.sequence);
    runtime.shutdown().unwrap();
    assert_eq!(events.recv().await.unwrap().status, "closed");
    assert_eq!(
        runtime.round_trip("late".into()).unwrap_err(),
        RuntimeError::NotInitialized
    );
}

#[test]
fn duplicate_bootstrap_reuses_the_process_session_and_shutdown_is_idempotent() {
    let runtime = BootstrapRuntime::default();
    let first = runtime.initialize(profile()).unwrap();
    // A recreated Flutter engine in the same process attaches to the session
    // that already owns the library lock.
    let second = runtime.initialize(profile()).unwrap();
    assert_eq!(second.session_id, first.session_id);
    runtime.shutdown().unwrap();
    runtime.shutdown().unwrap();
    assert_ne!(
        first.session_id,
        runtime.initialize(profile()).unwrap().session_id
    );
}
