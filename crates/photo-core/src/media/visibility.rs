//! Source-relative directory visibility shared by discovery and change admission.
use std::path::{Component, Path, PathBuf};

/// Ancestors outside an explicitly selected source are not part of its contents.
/// In particular, a source under ~/.local must not hide the whole source.
pub fn hidden_directory_within(root: &Path, directory: &Path) -> bool {
    directory.strip_prefix(root).is_ok_and(|relative| {
        relative.components().any(|component| {
            matches!(component, Component::Normal(name) if name.as_encoded_bytes().starts_with(b"."))
        })
    })
}

/// Ignore hidden source contents and the catalog's own writes. Only real trash
/// roots receive an exception, including their creation below a watched parent.
pub fn relevant_change(
    path: &Path,
    is_file: bool,
    sources: &[PathBuf],
    trash_roots: &[PathBuf],
    data_root: &Path,
) -> bool {
    if trash_roots
        .iter()
        .any(|trash| path.starts_with(trash) || trash.starts_with(path))
    {
        return true;
    }
    if path.starts_with(data_root) {
        return false;
    }
    let directory = if is_file {
        path.parent().unwrap_or(path)
    } else {
        path
    };
    sources.iter().any(|root| {
        (path.starts_with(root) || root.starts_with(path))
            && !hidden_directory_within(root, directory)
    })
}
