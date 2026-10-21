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
    if !is_uuid(photo_id) || !is_uuid(generation) {
        return Err("GraphInvalid".into());
    }
    Ok(root
        .join("cloud")
        .join(account_id)
        .join("media")
        .join(photo_id)
        .join(generation))
}

/// Gallery grouping name for downloaded photos. The directory is virtual: the
/// actual files live in per-generation folders, but the album sidebar should
/// show one stable, human-readable entry instead of a generation UUID.
pub(super) fn virtual_parent(root: &Path, account_id: &str) -> PathBuf {
    root.join("cloud").join(account_id).join("Cloud")
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
    (1..=8).contains(&extension.len())
        && extension.bytes().all(|byte| byte.is_ascii_alphanumeric())
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
    let year = year_for_ms(sort_time_ms).max(1970);
    format!("Uploads/{year}/{stem}-{media_suffix}-{generation_suffix}.{extension}")
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
        assert_eq!(download_extension("album/noext", "application/x-test"), None);
        assert!(media_dir(Path::new("/tmp"), "acct", "not-a-uuid", "also-no").is_err());
        assert_eq!(
            virtual_parent(Path::new("/tmp/root"), "acct"),
            Path::new("/tmp/root/cloud/acct/Cloud")
        );
    }
}
