use photo_domain::profile::{BuildProfile, ProfileError};

fn example() -> BuildProfile {
    let document: serde_json::Value = serde_json::from_str(include_str!(
        "../../../docs/design/contracts/platform-profiles.json"
    ))
    .unwrap();
    serde_json::from_value(document["profiles"][0].clone()).unwrap()
}

#[test]
fn canonical_digest_is_independent_of_input_field_order() {
    let profile = example();
    let canonical = profile.canonical_json().unwrap();
    let reparsed = BuildProfile::from_json(&canonical).unwrap();
    assert_eq!(profile.digest().unwrap(), reparsed.digest().unwrap());
    assert!(reparsed.validate(&profile.digest().unwrap(), 1).is_ok());
}

#[test]
fn rejects_mismatch_before_runtime_initialization() {
    let profile = example();
    assert_eq!(
        profile.clone().validate("wrong", 1).unwrap_err(),
        ProfileError::Digest
    );
    assert_eq!(
        profile.validate("wrong", 2).unwrap_err(),
        ProfileError::Protocol
    );
}

#[test]
fn rejects_planned_foreign_adapters_and_invalid_budgets() {
    let mut profile = example();
    profile.status = "planned".into();
    assert_eq!(
        profile
            .clone()
            .validate(&profile.digest().unwrap(), 1)
            .unwrap_err(),
        ProfileError::Planned
    );
    profile.status = "active".into();
    profile.adapters.source = "android_content_uri".into();
    assert_eq!(
        profile
            .clone()
            .validate(&profile.digest().unwrap(), 1)
            .unwrap_err(),
        ProfileError::Adapter
    );
    let mut profile = example();
    profile.limits.decoder_single_mib = profile.limits.decoder_total_mib + 1;
    assert_eq!(
        profile
            .clone()
            .validate(&profile.digest().unwrap(), 1)
            .unwrap_err(),
        ProfileError::Limits
    );
}

#[test]
fn malformed_profile_does_not_echo_input() {
    let raw = r#"{"password":"must-not-appear-in-errors"}"#;
    assert_eq!(
        BuildProfile::from_json(raw).unwrap_err().to_string(),
        "ProfileMalformed: invalid profile structure"
    );
    let canonical = example().canonical_json().unwrap();
    let duplicate = canonical.replacen('{', "{\"schema_version\":1,", 1);
    assert_eq!(
        BuildProfile::from_json(&duplicate).unwrap_err(),
        ProfileError::Malformed
    );
}
