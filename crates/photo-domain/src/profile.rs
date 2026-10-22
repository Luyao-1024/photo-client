use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct BuildProfile {
    pub schema_version: u32,
    pub profile_id: String,
    pub platform: String,
    pub status: String,
    pub flutter_target: String,
    pub rust_target: String,
    pub adapters: Adapters,
    pub limits: Limits,
    pub ui: UiOptions,
    pub packaging: Packaging,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Adapters {
    pub storage: String,
    pub source: String,
    pub secrets: String,
    pub scheduler: String,
    pub codec: String,
    pub instance_lock: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Limits {
    pub transfer_parallelism: u32,
    pub original_parallelism: u32,
    pub decoder_parallelism: u32,
    pub decoder_total_mib: u32,
    pub decoder_single_mib: u32,
    pub image_cache_mib: u32,
    pub viewer_cache_mib: u32,
    pub browse_index_mib: u32,
    pub gallery_rows_limit: u32,
    pub disk_cache_mib: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct UiOptions {
    pub layout: String,
    pub keyboard_mouse: bool,
    pub touch: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Packaging {
    pub format: String,
}

#[derive(Debug, Clone)]
pub struct ValidatedProfile {
    profile: BuildProfile,
    digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ProfileError {
    #[error("ProfileMalformed: invalid profile structure")]
    Malformed,
    #[error("ProfileUnsupported: unsupported profile schema")]
    Schema,
    #[error("PlatformPlanned: platform implementation is not available")]
    Planned,
    #[error("HostMismatch: profile does not match this executable")]
    Host,
    #[error("AdapterUnavailable: unknown platform adapter")]
    Adapter,
    #[error("InvalidLimits: invalid resource limits")]
    Limits,
    #[error("InvalidUi: adaptive layout is required")]
    Ui,
    #[error("BuildProfileMismatch: Dart and Rust profiles do not match")]
    Digest,
    #[error("BridgeMismatch: bridge protocol version is incompatible")]
    Protocol,
}

impl BuildProfile {
    /// A profile is bound to the executable that links it: the desktop and the
    /// universal Android package share every service but not their adapters.
    fn matches_host(&self) -> bool {
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        let host = self.platform == "linux"
            && self.flutter_target == "linux"
            && self.rust_target == "x86_64-unknown-linux-gnu"
            && self.profile_id == "linux-x86_64"
            && self.packaging.format == "linux_bundle";
        #[cfg(target_os = "android")]
        let host = self.platform == "android"
            && self.flutter_target == "android"
            && self.rust_target
                == "aarch64-linux-android,armv7-linux-androideabi,x86_64-linux-android"
            && self.profile_id == "android-universal"
            && self.packaging.format == "apk_aab";
        #[cfg(not(any(
            all(target_os = "linux", target_arch = "x86_64"),
            target_os = "android"
        )))]
        let host = false;
        host
    }

    pub fn from_json(raw: &str) -> Result<Self, ProfileError> {
        serde_json::from_str(raw).map_err(|_| ProfileError::Malformed)
    }

    pub fn canonical_json(&self) -> Result<String, ProfileError> {
        let value = serde_json::to_value(self).map_err(|_| ProfileError::Malformed)?;
        serde_json::to_string(&value).map_err(|_| ProfileError::Malformed)
    }

    pub fn digest(&self) -> Result<String, ProfileError> {
        let digest = Sha256::digest(self.canonical_json()?.as_bytes());
        Ok(format!("{digest:x}"))
    }

    pub fn validate(
        self,
        expected_digest: &str,
        protocol: u32,
    ) -> Result<ValidatedProfile, ProfileError> {
        if protocol != crate::BRIDGE_PROTOCOL_VERSION {
            return Err(ProfileError::Protocol);
        }
        if self.schema_version != 1 {
            return Err(ProfileError::Schema);
        }
        if self.status != "active" {
            return Err(ProfileError::Planned);
        }
        if !self.matches_host() {
            return Err(ProfileError::Host);
        }
        let expected = expected_adapters().ok_or(ProfileError::Host)?;
        if self.adapters != expected {
            return Err(ProfileError::Adapter);
        }
        let limits = &self.limits;
        if [
            limits.transfer_parallelism,
            limits.original_parallelism,
            limits.decoder_parallelism,
            limits.decoder_total_mib,
            limits.decoder_single_mib,
            limits.image_cache_mib,
            limits.viewer_cache_mib,
            limits.browse_index_mib,
            limits.gallery_rows_limit,
            limits.disk_cache_mib,
        ]
        .contains(&0)
            || limits.original_parallelism > limits.transfer_parallelism
            || limits.decoder_single_mib > limits.decoder_total_mib
            || limits.gallery_rows_limit > 2_000
        {
            return Err(ProfileError::Limits);
        }
        if self.ui.layout != "adaptive" {
            return Err(ProfileError::Ui);
        }
        let digest = self.digest()?;
        if digest != expected_digest {
            return Err(ProfileError::Digest);
        }
        Ok(ValidatedProfile {
            profile: self,
            digest,
        })
    }
}

fn expected_adapters() -> Option<Adapters> {
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        return Some(Adapters {
            storage: "linux_xdg".into(),
            source: "linux_file_picker".into(),
            secrets: "linux_secret_service".into(),
            scheduler: "while_app_running".into(),
            codec: "portable_image".into(),
            instance_lock: "linux_process_lock".into(),
        });
    }
    #[cfg(target_os = "android")]
    {
        return Some(Adapters {
            storage: "android_private".into(),
            source: "android_content_uri".into(),
            secrets: "android_protected_session".into(),
            scheduler: "android_system_budget".into(),
            codec: "android_media_codec".into(),
            instance_lock: "android_process_lock".into(),
        });
    }
    #[cfg(not(any(
        all(target_os = "linux", target_arch = "x86_64"),
        target_os = "android"
    )))]
    {
        None
    }
}

impl ValidatedProfile {
    pub fn profile(&self) -> &BuildProfile {
        &self.profile
    }
    pub fn digest(&self) -> &str {
        &self.digest
    }
}
