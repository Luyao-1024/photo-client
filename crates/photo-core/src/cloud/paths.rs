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

pub(super) fn media_dir(
    root: &Path,
    account_id: &str,
    photo_id: &str,
    generation: &str,
) -> Result<PathBuf, String> {
    if !is_uuid(generation) {
        return Err("GraphInvalid".into());
    }
    Ok(root
        .join("cloud")
        .join(account_id)
        .join("media")
        .join(media_folder(photo_id)?)
        .join(generation))
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

/// The album a downloaded photo belongs to.
///
/// The album mirrors the cloud relative path, so a photo that was uploaded
/// from an album comes back into an album with the same name instead of one
/// flat "Cloud" album. The path is virtual: the bytes stay in the per
/// generation media folders.
pub(super) fn virtual_album(root: &Path, account_id: &str, relative_path: &str) -> PathBuf {
    let album = album_path(relative_path);
    let base = root.join("cloud").join(account_id);
    if album.is_empty() {
        return base.join("Cloud");
    }
    let mut path = base;
    for segment in album.split('/') {
        path = path.join(segment);
    }
    path
}

/// The album directory of a cloud relative path: every segment except the
/// file name. Unsafe segments are dropped, so the result can never escape
/// the cloud folder.
pub(super) fn album_path(relative_path: &str) -> String {
    let segments: Vec<&str> = relative_path.split('/').collect();
    let mut parts = Vec::new();
    for segment in segments.iter().take(segments.len().saturating_sub(1)) {
        if safe_segment(segment) {
            parts.push(*segment);
        }
    }
    parts.join("/")
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

pub(super) fn download_extension(relative_path: &str, mime: &str) -> Option<String> {
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
    fn a_downloaded_photo_lands_in_the_album_of_its_path() {
        let root = Path::new("/tmp/root");
        assert_eq!(
            virtual_album(root, "acct", "Camera/2026-09/IMG_1000.png"),
            Path::new("/tmp/root/cloud/acct/Camera/2026-09")
        );
        assert_eq!(
            virtual_album(root, "acct", "IMG_1000.png"),
            Path::new("/tmp/root/cloud/acct/Cloud")
        );
        // An unsafe segment is dropped, so the album stays inside the cloud
        // folder.
        assert_eq!(
            virtual_album(root, "acct", "../escape/IMG_1000.png"),
            Path::new("/tmp/root/cloud/acct/escape")
        );
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
        // A non UUID generation is still refused: the generation is the
        // content identity and must stay a UUID.
        assert!(media_dir(Path::new("/tmp"), "acct", "not-a-uuid", "also-no").is_err());
    }
}
