//! Thin Flutter boundary. Services remain in photo-core; platform wiring stays here.
pub mod api;
mod frb_generated;

pub(crate) mod build_profile {
    include!(concat!(env!("OUT_DIR"), "/build_profile.rs"));
}
