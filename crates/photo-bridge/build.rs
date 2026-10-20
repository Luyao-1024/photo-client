use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=PHOTO_PROFILE_DIGEST");
    let digest = env::var("PHOTO_PROFILE_DIGEST").ok();
    if let Some(value) = &digest {
        assert!(
            value.len() == 64
                && value
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()),
            "PHOTO_PROFILE_DIGEST must be a canonical SHA-256 hex digest"
        );
    }
    let generated = format!("pub const PROFILE_DIGEST: Option<&str> = {digest:?};\n");
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo supplies OUT_DIR"));
    fs::write(out.join("build_profile.rs"), generated)
        .expect("write generated native profile contract");
}
