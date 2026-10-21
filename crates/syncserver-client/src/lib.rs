//! SyncServer protocol boundary.
//!
//! Every network and protocol operation is provided by the pinned `sync-client`
//! SDK. This crate exists so the application depends on one stable boundary and
//! can add app-specific error classification without reimplementing transport.

pub use sync_client::*;

/// Stable, non-sensitive error family used by UI and persistence.
pub fn error_code(error: &Error) -> &'static str {
    match error {
        Error::Endpoint(_) => "EndpointRejected",
        Error::Transport(_) | Error::Io(_) => "Network",
        Error::Authentication(_) => "AuthFailed",
        Error::Api { status: 401, .. } | Error::Api { status: 403, .. } => "AuthFailed",
        Error::LeaseBusy => "LeaseBusy",
        Error::LeaseLost => "LeaseLost",
        Error::NotCurrent(_) => "NotCurrent",
        Error::ExpiredSyncToken => "ExpiredSyncToken",
        Error::QuotaExceeded => "QuotaExceeded",
        Error::UploadRejected { .. } => "UploadRejected",
        Error::ChecksumMismatch { .. } | Error::SizeMismatch { .. } => "TransferCorrupt",
        Error::Graph(_) => "GraphInvalid",
        Error::Api { .. } | Error::InBand(_) => "ServerRejected",
        Error::Protocol(_) | Error::PhaseMismatch(_) | Error::IdempotencyConflict => "Protocol",
        Error::NotFound(_) => "NotFound",
        Error::UploadFailed(_) => "UploadFailed",
    }
}
