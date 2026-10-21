//! Presentation preferences for the account-free local library. Only
//! transparent materials exist, so a solid material must never be stored.
use photo_core::local_library::LocalLibrary;
use tempfile::TempDir;

fn stored_mode(library: &LocalLibrary) -> Option<String> {
    let raw = library.preferences().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&raw).unwrap();
    parsed.get("glassMode").and_then(|v| v.as_str()).map(str::to_string)
}

#[test]
fn transparent_material_modes_are_stored() {
    let root = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    for mode in ["auto", "full", "reduced"] {
        library
            .set_preference("glassMode".into(), format!("\"{mode}\""))
            .unwrap();
        assert_eq!(stored_mode(&library).as_deref(), Some(mode));
    }
}

#[test]
fn the_solid_material_is_not_a_preference() {
    let root = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(
        library.set_preference("glassMode".into(), "\"plain\"".into()),
        Err("InvalidPreference".into())
    );
    assert_eq!(
        library.set_preference("glassMode".into(), "\"solid\"".into()),
        Err("InvalidPreference".into())
    );
    // A rejected material leaves the previous one untouched.
    assert_eq!(stored_mode(&library), None);
}

#[test]
fn other_preferences_keep_their_own_rules() {
    let root = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    library.set_preference("theme".into(), "\"dark\"".into()).unwrap();
    library
        .set_preference("transparency".into(), "0.25".into())
        .unwrap();
    assert_eq!(
        library.set_preference("unknown".into(), "1".into()),
        Err("InvalidPreference".into())
    );
    let raw = library.preferences().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(parsed["theme"], serde_json::json!("dark"));
    assert_eq!(parsed["transparency"], serde_json::json!(0.25));
}
