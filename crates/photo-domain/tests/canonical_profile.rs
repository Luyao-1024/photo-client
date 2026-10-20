//! Cross-language contract vector generated from the actual Linux YAML with
//! tools/platform_config.py::canonical_json. Keep these bytes (including the
//! absence of a trailing newline) identical to PHOTO_PROFILE_JSON in Dart defines.
use photo_domain::BRIDGE_PROTOCOL_VERSION;
use photo_domain::profile::{BuildProfile, ProfileError};

const PYTHON_CANONICAL: &str = include_str!("fixtures/linux-profile.canonical.json");
const PYTHON_DIGEST: &str = "7d53d9326d3afebc855e822b4b243c29f6e3482c9445fb44cb284f5087801280";

fn python_profile() -> BuildProfile {
    BuildProfile::from_json(PYTHON_CANONICAL).expect("Python canonical fixture must parse in Rust")
}

#[test]
fn python_canonical_bytes_and_digest_match_rust_exactly() {
    let profile = python_profile();
    let canonical = profile.canonical_json().unwrap();
    assert_eq!(canonical.as_bytes(), PYTHON_CANONICAL.as_bytes());
    assert_eq!(profile.digest().unwrap(), PYTHON_DIGEST);
    assert_eq!(BRIDGE_PROTOCOL_VERSION, 1);
}

#[test]
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn python_digest_is_accepted_by_linux_profile_validation() {
    let validated = python_profile().validate(PYTHON_DIGEST, 1).unwrap();
    assert_eq!(validated.digest(), PYTHON_DIGEST);
    assert_eq!(validated.profile().profile_id, "linux-x86_64");
}

#[test]
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn mismatched_digest_and_changed_profile_are_rejected() {
    let wrong_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    assert_eq!(
        python_profile().validate(wrong_digest, 1).unwrap_err(),
        ProfileError::Digest
    );

    // This remains a valid budget; only its disagreement with the Python/Dart
    // profile digest should prevent initialization.
    let mut changed = python_profile();
    changed.limits.transfer_parallelism += 1;
    assert_eq!(
        changed.validate(PYTHON_DIGEST, 1).unwrap_err(),
        ProfileError::Digest
    );
}

#[test]
fn incompatible_protocol_is_rejected_for_python_profile() {
    for protocol in [0, 2] {
        assert_eq!(
            python_profile()
                .validate(PYTHON_DIGEST, protocol)
                .unwrap_err(),
            ProfileError::Protocol
        );
    }
}
