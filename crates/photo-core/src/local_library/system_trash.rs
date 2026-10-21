use super::*;
use gio::prelude::FileExt as GioFileExt;
use std::collections::HashSet;

pub(super) fn roots(source: &Path, data_root: &Path) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Some(base) = std::env::var_os("XDG_DATA_HOME") {
        roots.push(PathBuf::from(base).join("Trash"));
    }
    if let Some(home) = std::env::var_os("HOME") {
        roots.push(PathBuf::from(home).join(".local/share/Trash"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if let (Ok(metadata), Ok(owner)) = (fs::metadata(source), fs::metadata(data_root)) {
            let mut top = source.to_path_buf();
            while let Some(parent) = top.parent() {
                if fs::metadata(parent).is_ok_and(|m| m.dev() == metadata.dev()) {
                    top = parent.to_path_buf();
                } else {
                    break;
                }
            }
            roots.push(top.join(format!(".Trash-{}", owner.uid())));
            roots.push(top.join(".Trash").join(owner.uid().to_string()));
        }
    }
    roots.sort();
    roots.dedup();
    roots
}
fn decode(value: &str) -> Option<PathBuf> {
    let mut decoded = Vec::new();
    let bytes = value.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            decoded.push(
                u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).ok()?, 16).ok()?,
            );
            i += 3;
        } else {
            decoded.push(bytes[i]);
            i += 1;
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStringExt;
        Some(PathBuf::from(std::ffi::OsString::from_vec(decoded)))
    }
    #[cfg(not(unix))]
    {
        Some(PathBuf::from(String::from_utf8(decoded).ok()?))
    }
}
pub(super) fn entries(source: &Path, data_root: &Path) -> Vec<(PathBuf, PathBuf, PathBuf)> {
    let mut result = Vec::new();
    for root in roots(source, data_root) {
        if let Ok(entries) = fs::read_dir(root.join("info")) {
            for entry in entries.flatten() {
                let info = entry.path();
                if info.extension().is_none_or(|v| v != "trashinfo") {
                    continue;
                }
                let Ok(text) = fs::read_to_string(&info) else {
                    continue;
                };
                let Some(path) = text
                    .lines()
                    .find_map(|l| l.strip_prefix("Path="))
                    .and_then(decode)
                else {
                    continue;
                };
                let path = if path.is_absolute() {
                    path
                } else {
                    root.parent().unwrap_or(Path::new("/")).join(path)
                };
                let Some(name) = info.file_stem() else {
                    continue;
                };
                let payload = root.join("files").join(name);
                if payload.is_file() {
                    result.push((path, payload, info));
                }
            }
        }
    }
    result
}
pub(super) fn move_to_trash(source: &Path, data_root: &Path) -> Result<(PathBuf, PathBuf), String> {
    let before: HashSet<_> = entries(source, data_root)
        .into_iter()
        .map(|(_, _, info)| info)
        .collect();
    if gio::File::for_path(source)
        .trash(gio::Cancellable::NONE)
        .is_ok()
    {
        return entries(source, data_root)
            .into_iter()
            .find(|(original, _, info)| original == source && !before.contains(info))
            .map(|(_, payload, info)| (payload, info))
            .ok_or_else(|| "TrashResolutionFailed".into());
    }
    // GIO refuses some cross-filesystem sources (notably /tmp). Publish a
    // standard freedesktop payload + .trashinfo in the user's system trash.
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .ok_or("SystemTrashUnavailable")?;
    let root = base.join("Trash");
    let files = root.join("files");
    let infos = root.join("info");
    fs::create_dir_all(&files).map_err(error)?;
    fs::create_dir_all(&infos).map_err(error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for directory in [&root, &files, &infos] {
            fs::set_permissions(directory, fs::Permissions::from_mode(0o700)).map_err(error)?;
        }
    }
    let name = source.file_name().ok_or("InvalidSource")?.to_string_lossy();
    use std::io::Write;
    for index in 0..10000 {
        let filename = if index == 0 {
            name.to_string()
        } else {
            format!("{name}.{index}")
        };
        let payload = files.join(&filename);
        let info = infos.join(format!("{filename}.trashinfo"));
        if payload.exists() {
            continue;
        }
        let mut file = match OpenOptions::new().write(true).create_new(true).open(&info) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(error(e)),
        };
        let path = source.to_str().ok_or("UnsupportedPathEncoding")?;
        let encoded = path
            .bytes()
            .map(|b| {
                if b.is_ascii_alphanumeric() || b"/-_.~".contains(&b) {
                    (b as char).to_string()
                } else {
                    format!("%{b:02X}")
                }
            })
            .collect::<String>();
        let date = gio::glib::DateTime::now_local()
            .and_then(|t| t.format("%Y-%m-%dT%H:%M:%S"))
            .map_err(error)?;
        let published = (|| {
            writeln!(file, "[Trash Info]\nPath={encoded}\nDeletionDate={date}").map_err(error)?;
            file.sync_all().map_err(error)?;
            move_file(source, &payload)
        })();
        if let Err(error) = published {
            let _ = fs::remove_file(&info);
            return Err(error);
        }
        return Ok((payload, info));
    }
    Err("NoAvailableFileName".into())
}
pub(super) fn info_for(payload: &Path) -> Option<PathBuf> {
    let root = payload.parent()?.parent()?;
    let info = root.join("info").join(format!(
        "{}.trashinfo",
        payload.file_name()?.to_string_lossy()
    ));
    info.is_file().then_some(info)
}
/// A database transaction cannot roll back physical renames. This guard does.
pub(super) struct FileRollback {
    pub moves: Vec<(PathBuf, PathBuf)>,
    pub created: Vec<PathBuf>,
    pub committed: bool,
}
impl FileRollback {
    pub fn new() -> Self {
        Self {
            moves: Vec::new(),
            created: Vec::new(),
            committed: false,
        }
    }
}
impl Drop for FileRollback {
    fn drop(&mut self) {
        if !self.committed {
            for (source, target) in self.moves.iter().rev() {
                let _ = move_file(target, source);
            }
            for path in &self.created {
                let _ = fs::remove_file(path);
            }
        }
    }
}
