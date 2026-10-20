//! Linux adapter composition boundary. No credential, scanner, or database is opened in S01.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlatformCapabilities {
    pub linux_host: bool,
    pub persistent_storage: bool,
    pub persistent_sessions: bool,
    pub media_import: bool,
    pub background_while_closed: bool,
}

pub fn capabilities() -> PlatformCapabilities {
    PlatformCapabilities {
        linux_host: cfg!(target_os = "linux"),
        persistent_storage: false,
        persistent_sessions: false,
        media_import: false,
        background_while_closed: false,
    }
}
