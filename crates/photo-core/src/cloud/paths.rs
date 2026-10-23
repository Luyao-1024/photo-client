//! Deterministic paths for downloaded media and upload placement.
use std::fs;
use std::path::{Path, PathBuf};

use uuid::Uuid;

pub(super) fn private_directory(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path).map_err(|_| "Internal")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

pub(super) fn is_uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok()
}

/// Where a downloaded photo publishes inside the real download root the user
/// chose: the album directory mirrors the cloud relative path, and the stem is
/// the cloud file name without its extension, kept as the user will see it in
/// a file manager. A path without a usable album segment lands in the flat
/// `Cloud` album of the root.
pub(crate) struct DownloadPlacement {
    pub(crate) directory: PathBuf,
    pub(crate) stem: String,
}

pub(crate) fn download_placement(download_root: &Path, relative_path: &str) -> DownloadPlacement {
    let segments: Vec<&str> = relative_path.split('/').collect();
    let file_name = segments.last().copied().unwrap_or_default();
    let mut directory = download_root.to_path_buf();
    let mut placed = false;
    for segment in segments.iter().take(segments.len().saturating_sub(1)) {
        if download_album_segment(segment) {
            directory = directory.join(segment);
            placed = true;
        }
    }
    if !placed {
        directory = download_root.join("Cloud");
    }
    DownloadPlacement {
        directory,
        stem: download_stem(file_name),
    }
}

/// The cloud file name as a real local name. Uploaded paths already carry a
/// safe, unique spelling that must survive the round trip; a foreign server
/// may still send separators, control bytes or a leading dot, which the
/// scanner would hide or the filesystem would reinterpret.
fn download_stem(file_name: &str) -> String {
    let stem = Path::new(file_name)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("");
    let mut output = String::with_capacity(stem.len().min(200));
    for character in stem.chars() {
        let mapped =
            if character == '/' || character == '\\' || character == '\0' || character.is_control()
            {
                '-'
            } else {
                character
            };
        output.push(mapped);
        if output.len() >= 200 {
            break;
        }
    }
    let trimmed =
        output.trim_matches(|character: char| character == '.' || character.is_whitespace());
    if trimmed.is_empty() {
        "photo".into()
    } else {
        trimmed.to_owned()
    }
}

/// An album directory segment the scanner will actually visit: everything the
/// wire accepts, minus dot-prefixed segments the local scan treats as hidden
/// and the reserved service directories.
fn download_album_segment(segment: &str) -> bool {
    safe_segment(segment)
        && !segment.starts_with('.')
        && !matches!(
            segment,
            ".syncserver" | ".photoviewer-sync" | ".sync-staging"
        )
}

/// The directory name of a photo inside the media folder.
///
/// A UUID photo id keeps its exact spelling, so a library that already
/// downloaded those photos keeps its files. Any other id is reduced to a safe
/// name with a digest of the original: the service does not require UUID
/// record names, and a foreign id must not abort the whole download.
pub(super) fn media_folder(photo_id: &str) -> Result<String, String> {
    if is_uuid(photo_id) {
        return Ok(photo_id.to_owned());
    }
    let mut name = String::with_capacity(photo_id.len().min(48));
    for character in photo_id.chars() {
        if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
            name.push(character);
        } else {
            name.push('-');
        }
        if name.len() >= 48 {
            break;
        }
    }
    let trimmed = name.trim_matches('-');
    if trimmed.is_empty() {
        return Err("GraphInvalid".into());
    }
    Ok(format!("{trimmed}-{:08x}", digest(photo_id)))
}

/// A short, stable digest of a name. It keeps two different ids apart after
/// they were reduced to the same safe spelling.
fn digest(value: &str) -> u32 {
    let mut hash: u32 = 2_166_136_261;
    for byte in value.as_bytes() {
        hash ^= u32::from(*byte);
        hash = hash.wrapping_mul(16_777_619);
    }
    hash
}

/// The private cache directory of a downloaded cloud thumbnail. It stays out
/// of the download root so a real album folder only ever holds photo files.
pub(super) fn thumbnail_cache_dir(
    root: &Path,
    account_id: &str,
    photo_id: &str,
    generation: &str,
) -> Result<PathBuf, String> {
    if !is_uuid(generation) {
        return Err("GraphInvalid".into());
    }
    if account_id.is_empty()
        || !account_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return Err("Internal".into());
    }
    Ok(root
        .join("cache")
        .join("cloud")
        .join(account_id)
        .join(media_folder(photo_id)?)
        .join(generation))
}

/// A path segment that is safe on the wire and as a directory name.
fn safe_segment(segment: &str) -> bool {
    !segment.is_empty()
        && segment != "."
        && segment != ".."
        && segment.len() <= 255
        && !segment.contains(['\\', '\0'])
}

/// The album prefix of an uploaded photo.
///
/// The local album path relative to its source root keeps the cloud record
/// and the local album in agreement: what is uploaded from "Screenshots" comes
/// back into "Screenshots". Reserved service directories are never used.
pub(super) fn safe_album(album: &str) -> String {
    let mut parts = Vec::new();
    for segment in album.split('/') {
        if safe_segment(segment)
            && !matches!(
                segment,
                ".syncserver" | ".photoviewer-sync" | ".sync-staging"
            )
        {
            parts.push(segment);
        }
    }
    parts.join("/")
}

pub(crate) fn download_extension(relative_path: &str, mime: &str) -> Option<String> {
    let from_path = Path::new(relative_path)
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
        .filter(|extension| safe_extension(extension));
    from_path.or_else(|| extension_for_mime(mime).map(str::to_owned))
}

pub(super) fn thumbnail_extension(mime: &str) -> Option<&'static str> {
    match mime {
        "image/jpeg" => Some("jpg"),
        "image/png" => Some("png"),
        _ => extension_for_mime(mime),
    }
}

pub(super) fn upload_extension(path: &Path, mime: &str) -> Option<String> {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
        .filter(|extension| safe_extension(extension))
        .or_else(|| extension_for_mime(mime).map(str::to_owned))
}

fn safe_extension(extension: &str) -> bool {
    (1..=8).contains(&extension.len()) && extension.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

fn extension_for_mime(mime: &str) -> Option<&'static str> {
    match mime {
        "image/jpeg" => Some("jpg"),
        "image/png" => Some("png"),
        "image/webp" => Some("webp"),
        "image/gif" => Some("gif"),
        "image/heic" | "image/heif" => Some("heic"),
        "video/mp4" => Some("mp4"),
        "video/quicktime" => Some("mov"),
        "video/webm" => Some("webm"),
        "video/x-matroska" => Some("mkv"),
        "video/x-msvideo" => Some("avi"),
        _ => None,
    }
}

/// A short ASCII stem that survives the SDK's relative-path rules and never
/// contains separators the server could reinterpret.
pub(super) fn safe_stem(name: &str) -> String {
    let stem = Path::new(name)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("");
    let mut output = String::with_capacity(stem.len().min(40));
    for character in stem.chars() {
        let mapped = if character.is_ascii_alphanumeric() {
            character.to_ascii_lowercase()
        } else {
            '-'
        };
        if mapped == '-' && output.ends_with('-') {
            continue;
        }
        output.push(mapped);
        if output.len() >= 40 {
            break;
        }
    }
    let trimmed = output.trim_matches('-');
    if trimmed.is_empty() {
        "photo".into()
    } else {
        trimmed.to_owned()
    }
}

pub(super) fn upload_relative_path(
    album: &str,
    media_name: &str,
    media_id: &str,
    generation: &str,
    extension: &str,
    sort_time_ms: i64,
) -> String {
    let media_suffix: String = media_id
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(8)
        .collect();
    let generation_suffix: String = generation
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(8)
        .collect();
    let stem = safe_stem(media_name);
    let name = format!("{stem}-{media_suffix}-{generation_suffix}.{extension}");
    // The album travels with the photo: a photo uploaded from an album comes
    // back into that album instead of one flat cloud album.
    let album = safe_album(album);
    if album.is_empty() {
        let year = year_for_ms(sort_time_ms).max(1970);
        format!("Uploads/{year}/{name}")
    } else {
        format!("{album}/{name}")
    }
}

pub(super) fn year_for_ms(milliseconds: i64) -> i32 {
    let days = milliseconds.div_euclid(86_400_000);
    let shifted = days + 719_468;
    let era = if shifted >= 0 {
        shifted
    } else {
        shifted - 146_096
    } / 146_097;
    let day_of_era = shifted - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_part = (5 * day_of_year + 2) / 153;
    let month = month_part + if month_part < 10 { 3 } else { -9 };
    let mut year = year_of_era + era * 400;
    if month <= 2 {
        year += 1;
    }
    year as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stem_and_upload_path_are_safe() {
        assert_eq!(safe_stem("My Trip 2024!!.jpg"), "my-trip-2024");
        assert_eq!(safe_stem("旅行.jpg"), "photo");
        let path = upload_relative_path(
            "",
            "My Trip.jpg",
            "0123456789abcdef",
            "fedcba9876543210",
            "jpg",
            1_700_000_000_000,
        );
        assert_eq!(path, "Uploads/2023/my-trip-01234567-fedcba98.jpg");
        assert!(syncserver_client::photo::is_safe_relative_path(&path));
    }

    #[test]
    fn the_upload_path_carries_the_album() {
        let path = upload_relative_path(
            "Camera/2026-09",
            "IMG_1000.jpg",
            "0123456789abcdef",
            "fedcba9876543210",
            "jpg",
            1_700_000_000_000,
        );
        assert_eq!(path, "Camera/2026-09/img-1000-01234567-fedcba98.jpg");
        assert!(syncserver_client::photo::is_safe_relative_path(&path));
        // A reserved service directory is never used as an album.
        let reserved = upload_relative_path(
            ".syncserver",
            "IMG_1000.jpg",
            "0123456789abcdef",
            "fedcba9876543210",
            "jpg",
            1_700_000_000_000,
        );
        assert!(reserved.starts_with("Uploads/"));
        // A traversal segment cannot escape the album.
        let traversal = upload_relative_path(
            "../etc",
            "IMG_1000.jpg",
            "0123456789abcdef",
            "fedcba9876543210",
            "jpg",
            1_700_000_000_000,
        );
        assert!(!traversal.contains(".."));
        assert!(syncserver_client::photo::is_safe_relative_path(&traversal));
    }

    #[test]
    fn a_download_lands_in_the_real_album_of_its_path() {
        let root = Path::new("/tmp/downloads");
        let camera = download_placement(root, "Camera/2026-09/IMG_1000.png");
        assert_eq!(camera.directory, Path::new("/tmp/downloads/Camera/2026-09"));
        // The cloud spelling, including its unique suffix, stays readable.
        assert_eq!(camera.stem, "IMG_1000");
        let unique = download_placement(root, "Camera/IMG_1000-01234567-fedcba98.jpg");
        assert_eq!(unique.stem, "IMG_1000-01234567-fedcba98");
        // A path without a usable album segment lands in the flat Cloud album.
        let flat = download_placement(root, "IMG_1000.png");
        assert_eq!(flat.directory, Path::new("/tmp/downloads/Cloud"));
        // Unsafe and hidden segments are dropped, so the album stays inside
        // the download root and the scanner keeps seeing it.
        let hidden = download_placement(root, ".hidden/Camera/../IMG.png");
        assert_eq!(hidden.directory, Path::new("/tmp/downloads/Camera"));
        assert_eq!(hidden.stem, "IMG");
    }

    #[test]
    fn a_foreign_photo_id_still_has_a_safe_media_folder() {
        // A UUID keeps its exact spelling, so existing downloads stay valid.
        let uuid = "5c9d3d93-8870-4ac1-ac7d-c9da4c485358";
        assert_eq!(media_folder(uuid).unwrap(), uuid);
        // A service that does not use UUID record names must not break the
        // download.
        let folder = media_folder("seed-photo-0").unwrap();
        assert!(folder.starts_with("seed-photo-0-"));
        assert!(!folder.contains('/'));
        // Two different ids keep different folders.
        assert_ne!(folder, media_folder("seed-photo-1").unwrap());
        assert!(media_folder("///").is_err());
    }

    #[test]
    fn years_match_known_dates() {
        assert_eq!(year_for_ms(0), 1970);
        assert_eq!(year_for_ms(1_700_000_000_000), 2023);
        assert_eq!(year_for_ms(951_782_400_000), 2000);
    }

    #[test]
    fn extension_never_escapes_the_media_directory() {
        assert_eq!(
            download_extension("album/photo.HEIC", "image/heic"),
            Some("heic".into())
        );
        assert_eq!(
            download_extension("album/noext", "image/jpeg"),
            Some("jpg".into())
        );
        assert_eq!(
            download_extension("album/noext", "application/x-test"),
            None
        );
        // The thumbnail cache lives under the private data root, and the
        // generation is the content identity and must stay a UUID.
        let generation = "5c9d3d93-8870-4ac1-ac7d-c9da4c485358";
        let cache_dir =
            thumbnail_cache_dir(Path::new("/tmp"), "acct", "seed-photo-0", generation).unwrap();
        assert!(cache_dir.ends_with(generation));
        let folder = cache_dir.parent().unwrap();
        assert_eq!(folder.parent().unwrap(), Path::new("/tmp/cache/cloud/acct"));
        assert!(
            folder
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("seed-photo-0-"))
        );
        assert!(thumbnail_cache_dir(Path::new("/tmp"), "acct", "p", "also-no").is_err());
    }
}
