use super::*;
use image::{GenericImageView, ImageDecoder, ImageEncoder, ImageReader};
use std::{
    collections::HashSet,
    io::{Read, Write},
    sync::OnceLock,
};
use tempfile::NamedTempFile;

static SAVING: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();
struct SaveGuard(PathBuf);
impl Drop for SaveGuard {
    fn drop(&mut self) {
        if let Ok(mut paths) = SAVING.get_or_init(Mutex::default).lock() {
            paths.remove(&self.0);
        }
    }
}
fn digest(path: &Path) -> Result<String, String> {
    let mut f = File::open(path).map_err(error)?;
    let mut sha = Sha256::new();
    let mut bytes = [0; 65536];
    loop {
        let n = f.read(&mut bytes).map_err(error)?;
        if n == 0 {
            break;
        }
        sha.update(&bytes[..n]);
    }
    Ok(format!("{:x}", sha.finalize()))
}
fn sync_parent(path: &Path) -> Result<(), String> {
    File::open(path.parent().ok_or("InvalidDestination")?)
        .and_then(|f| f.sync_all())
        .map_err(error)
}
fn restore_backup(backup: &Path, target: &Path) -> Result<(), String> {
    let mut stage =
        NamedTempFile::new_in(target.parent().ok_or("InvalidDestination")?).map_err(error)?;
    std::io::copy(&mut File::open(backup).map_err(error)?, stage.as_file_mut()).map_err(error)?;
    stage.as_file().sync_all().map_err(error)?;
    stage.persist(target).map_err(|e| error(e.error))?;
    sync_parent(target)
}
/// Reconcile a file published before an interrupted database commit. Never
/// replace an externally modified file: retain its backup and mark a conflict.
pub(super) fn recover(c: &mut Connection) -> Result<(), String> {
    let mut stmt=c.prepare("SELECT o.library_id,o.operation_id,o.destination_uri,o.backup_uri,p.expected_sha256 FROM file_operations o JOIN file_publications p USING(library_id,operation_id) WHERE o.state IN ('prepared','file_applied')").map_err(error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, String>(4)?,
            ))
        })
        .map_err(error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(error)?;
    drop(stmt);
    for (library, op, target, backup, hash) in rows {
        let path = Path::new(&target);
        let current = digest(path).ok();
        let result = if let Some(backup) = backup {
            let backup = Path::new(&backup);
            if current.as_ref() == Some(&hash) || (!path.exists() && backup.is_file()) {
                restore_backup(backup, path)
            } else if current.is_some() && current == digest(backup).ok() {
                Ok(())
            } else {
                Err("SourceChanged".into())
            }
        } else if current.as_ref() == Some(&hash) {
            fs::remove_file(path).map_err(error)
        } else if !path.exists() {
            Ok(())
        } else {
            Err("SourceChanged".into())
        };
        c.execute("UPDATE file_operations SET state=?3,error_code=?4 WHERE library_id=?1 AND operation_id=?2",params![library,op,if result.is_ok(){"failed"}else{"conflict"},result.err()]).map_err(error)?;
    }
    Ok(())
}
/// Orientation is baked into edited pixels; retain all other source EXIF.
fn normalized_exif(mut raw: Vec<u8>) -> Vec<u8> {
    if raw.starts_with(b"Exif\0\0") {
        raw.drain(..6);
    }
    if raw.len() < 8 {
        return raw;
    }
    let little = &raw[..2] == b"II";
    let u16_at = |b: &[u8]| {
        if little {
            u16::from_le_bytes([b[0], b[1]])
        } else {
            u16::from_be_bytes([b[0], b[1]])
        }
    };
    let offset = if little {
        u32::from_le_bytes(raw[4..8].try_into().unwrap())
    } else {
        u32::from_be_bytes(raw[4..8].try_into().unwrap())
    } as usize;
    if offset + 2 > raw.len() {
        return raw;
    }
    let count = u16_at(&raw[offset..]) as usize;
    for i in 0..count.min(4096) {
        let p = offset + 2 + i * 12;
        if p + 12 > raw.len() {
            break;
        }
        if u16_at(&raw[p..]) == 0x112 && u16_at(&raw[p + 2..]) == 3 {
            let value = if little {
                1_u16.to_le_bytes()
            } else {
                1_u16.to_be_bytes()
            };
            raw[p + 8..p + 10].copy_from_slice(&value);
        }
    }
    raw
}
impl LocalLibrary {
    pub fn save_edited(
        &self,
        id: String,
        adjustments: EditAdjustments,
        save_copy: bool,
    ) -> Result<LocalPhoto, String> {
        self.save_edited_versioned(id, adjustments, save_copy, None)
    }
    pub fn save_edited_versioned(
        &self,
        id: String,
        adjustments: EditAdjustments,
        save_copy: bool,
        expected_version: Option<u64>,
    ) -> Result<LocalPhoto, String> {
        let _mutation = self.mutation_guard()?;
        if self.cloud_media_read_only(id.clone())? {
            return Err("CloudMediaReadOnly".into());
        }
        if adjustments.is_identity() {
            return Err("NoEdits".into());
        }
        let photo = self.photo(id.clone())?;
        if expected_version.is_some_and(|v| v != photo.content_version) {
            return Err("SourceChanged".into());
        }
        let metadata = crate::media::details::read(Path::new(&photo.path));
        if metadata.animated || metadata.hdr || metadata.motion_offset.is_some() {
            return Err("UnsupportedEdit".into());
        }
        if photo.media_kind != "image"
            || !matches!(
                photo.mime_type.as_str(),
                "image/jpeg" | "image/png" | "image/webp"
            )
        {
            return Err("UnsupportedEdit".into());
        }
        let source = PathBuf::from(&photo.path);
        let canonical = source.canonicalize().map_err(|_| "SourceUnavailable")?;
        {
            let mut paths = SAVING
                .get_or_init(Mutex::default)
                .lock()
                .map_err(|_| "SaveBusy")?;
            if !paths.insert(canonical.clone()) {
                return Err("SaveBusy".into());
            }
        }
        let _guard = SaveGuard(canonical);
        let expected = crate::media::Fingerprint::from_metadata(
            &fs::symlink_metadata(&source).map_err(error)?,
        )?;
        if expected.size != photo.size_bytes || expected.modified_ns != photo.modified_ns {
            return Err("SourceChanged".into());
        }
        let source_handle = File::open(&source).map_err(error)?;
        // Decode / render / encode outside the database actor.
        let mut decoder = ImageReader::open(&source)
            .map_err(error)?
            .into_decoder()
            .map_err(|_| "DecodeFailed")?;
        let (width, height) = decoder.dimensions();
        if u64::from(width) * u64::from(height) * 24 > 512 * 1024 * 1024 {
            return Err("DecodeBudgetExceeded".into());
        }
        let exif = decoder.exif_metadata().ok().flatten().map(normalized_exif);
        let orientation = decoder.orientation().map_err(|_| "DecodeFailed")?;
        let mut image = image::DynamicImage::from_decoder(decoder).map_err(|_| "DecodeFailed")?;
        image.apply_orientation(orientation);
        let (mut crop_width, mut crop_height) = image.dimensions();
        if adjustments.rotation_degrees.rem_euclid(180) != 0 {
            std::mem::swap(&mut crop_width, &mut crop_height);
        }
        if let Some(crop) = adjustments.crop
            && (crop.width == 0
                || crop.height == 0
                || crop
                    .x
                    .checked_add(crop.width)
                    .is_none_or(|v| v > crop_width)
                || crop
                    .y
                    .checked_add(crop.height)
                    .is_none_or(|v| v > crop_height))
        {
            return Err("InvalidCrop".into());
        }
        let rendered = crate::edit::render(&image, adjustments);
        drop(image);
        let (format, mime) = crate::media::format_for_path(&source).ok_or("UnsupportedFormat")?;
        let mut stage =
            NamedTempFile::new_in(source.parent().ok_or("InvalidDestination")?).map_err(error)?;
        match format {
            image::ImageFormat::Jpeg => {
                let mut encoder =
                    image::codecs::jpeg::JpegEncoder::new_with_quality(stage.as_file_mut(), 92);
                if let Some(exif) = exif {
                    encoder.set_exif_metadata(exif).map_err(error)?;
                }
                encoder.encode_image(&rendered.to_rgb8()).map_err(error)?;
            }
            image::ImageFormat::Png => {
                let mut encoder = image::codecs::png::PngEncoder::new(stage.as_file_mut());
                if let Some(exif) = exif {
                    encoder.set_exif_metadata(exif).map_err(error)?;
                }
                let rgba = rendered.to_rgba8();
                encoder
                    .write_image(
                        &rgba,
                        rgba.width(),
                        rgba.height(),
                        image::ExtendedColorType::Rgba8,
                    )
                    .map_err(error)?;
            }
            _ => rendered
                .write_to(stage.as_file_mut(), format)
                .map_err(error)?,
        }
        stage.as_file_mut().flush().map_err(error)?;
        stage.as_file().sync_all().map_err(error)?;
        image::ImageReader::open(stage.path())
            .map_err(error)?
            .with_guessed_format()
            .map_err(error)?
            .into_dimensions()
            .map_err(|_| "EncodeFailed")?;
        crate::media::check_source(&source, &source_handle, &expected)?;
        let target = if save_copy {
            let stem = source
                .file_stem()
                .and_then(|s| s.to_str())
                .ok_or("InvalidDestination")?;
            let base = stem
                .rsplit_once("_edited_")
                .filter(|(_, s)| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()))
                .map(|(base, _)| base)
                .unwrap_or(stem);
            unique_destination(
                source.parent().unwrap(),
                &format!(
                    "{base}_edited_{}.{}",
                    now_ms(),
                    source.extension().unwrap().to_string_lossy()
                ),
            )?
        } else {
            source.clone()
        };
        let backup = if save_copy {
            None
        } else {
            let dir = self.root.join("backups").join(&id);
            fs::create_dir_all(&dir).map_err(error)?;
            let path = dir.join(format!("v{}-{}.bak", photo.content_version, Uuid::new_v4()));
            copy_file(&source, &path)?;
            sync_parent(&path)?;
            Some(path)
        };
        let op = Uuid::new_v4().to_string();
        let hash = digest(stage.path())?;
        let library = self.library_id.clone();
        let target_uri = target
            .to_str()
            .ok_or("UnsupportedPathEncoding")?
            .to_string();
        let backup_uri = backup.as_ref().map(|p| p.to_string_lossy().into_owned());
        let media_id = id.clone();
        let operation = op.clone();
        let destination = target_uri.clone();
        let source_uri = photo.path.clone();
        let version = photo.content_version;
        self.execute(move|c|{let tx=c.transaction().map_err(error)?;
            tx.execute("INSERT INTO file_operations(library_id,operation_id,media_id,kind,source_uri,destination_uri,captured_content_version,state,backup_uri,created_at_ms) VALUES(?1,?2,?3,'save_copy',?4,?5,?6,'prepared',?7,?8)",params![library,operation,media_id,source_uri,destination,version as i64,backup_uri,now_ms()]).map_err(error)?;
            tx.execute("INSERT INTO file_publications VALUES(?1,?2,?3)",params![library,operation,hash]).map_err(error)?;tx.commit().map_err(error)
        })?;
        crate::media::check_source(&source, &source_handle, &expected)?;
        if save_copy {
            stage
                .persist_noclobber(&target)
                .map_err(|e| error(e.error))?;
        } else {
            stage.persist(&target).map_err(|e| error(e.error))?;
        }
        sync_parent(&target)?;
        let metadata = fs::metadata(&target).map_err(error)?;
        let published = crate::media::Fingerprint::from_metadata(&metadata)?;
        let new_id = if save_copy {
            Uuid::new_v4().to_string()
        } else {
            id.clone()
        };
        let library = self.library_id.clone();
        let result_id = new_id.clone();
        let operation = op.clone();
        let capture = photo.capture_time_ms;
        let favorite = photo.favorite;
        let parent = target.parent().unwrap().to_string_lossy().into_owned();
        let name = target.file_name().unwrap().to_string_lossy().into_owned();
        let mime = mime.to_string();
        let (w, h) = rendered.dimensions();
        drop(rendered);
        let result=self.execute(move|c|{
            let tx=c.transaction().map_err(error)?;
            let current:u64=tx.query_row("SELECT content_version FROM media WHERE library_id=?1 AND media_id=?2 AND state='active'",params![library,id],|r|sql_u64(r,0)).map_err(error)?;
            if current!=version{return Err("SourceChanged".into());}
            if save_copy{
                tx.execute("INSERT INTO media(library_id,media_id,source_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,media_kind,mime_type,width,height,orientation,capture_time_ms,sort_time_ms,favorite) SELECT library_id,?3,source_id,?4,?5,?6,?7,?8,'image',?9,?10,?11,1,?12,COALESCE(?12,?8/1000000),0 FROM media WHERE library_id=?1 AND media_id=?2",params![library,id,result_id,target_uri,name,parent,published.size as i64,published.modified_ns,mime,w,h,capture]).map_err(error)?;
            }else{
                tx.execute("UPDATE media SET size_bytes=?3,modified_ns=?4,content_version=content_version+1,width=?5,height=?6,orientation=1 WHERE library_id=?1 AND media_id=?2",params![library,id,published.size as i64,published.modified_ns,w,h]).map_err(error)?;
                tx.execute("DELETE FROM thumbnails WHERE library_id=?1 AND media_id=?2",params![library,id]).map_err(error)?;
            }
            let _=favorite;
            tools::recount(&tx,&library)?;
            tx.execute("UPDATE file_operations SET state='committed' WHERE library_id=?1 AND operation_id=?2",params![library,operation]).map_err(error)?;
            tx.commit().map_err(error)?;
            c.query_row(PHOTO_COLUMNS,params![library,result_id],decode_photo).map_err(error)
        });
        if result.is_err() {
            if let Some(backup) = backup {
                restore_backup(&backup, &target)?;
            } else {
                fs::remove_file(&target).map_err(error)?;
            }
            let library = self.library_id.clone();
            self.execute(move|c|{c.execute("UPDATE file_operations SET state='failed' WHERE library_id=?1 AND operation_id=?2",params![library,op]).map_err(error)?;Ok(())})?;
        }
        result
    }
}

pub(super) fn recover_purges(c: &mut Connection) -> Result<(), String> {
    let mut statement = c
        .prepare(
            "SELECT library_id,operation_id,source_uri,staged_uri,committed FROM pending_purges",
        )
        .map_err(error)?;
    let rows = statement
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, bool>(4)?,
            ))
        })
        .map_err(error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(error)?;
    drop(statement);
    for (library, op, source, stage, committed) in rows {
        let stage = Path::new(&stage);
        let source = Path::new(&source);
        if stage.exists() {
            if committed {
                fs::remove_file(stage).map_err(error)?;
            } else if !source.exists() {
                fs::rename(stage, source).map_err(error)?;
            } else {
                continue;
            }
        }
        c.execute(
            "DELETE FROM pending_purges WHERE library_id=?1 AND operation_id=?2",
            params![library, op],
        )
        .map_err(error)?;
    }
    Ok(())
}
impl LocalLibrary {
    pub fn purge_media(&self, ids: Vec<String>) -> Result<u64, String> {
        let _guard = self.mutation_guard()?;
        self.execute(recover_purges)?;
        let mut prepared = Vec::new();
        for id in ids {
            let photo = match self.photo(id.clone()) {
                Ok(p) => p,
                Err(e) if e == "PhotoNotFound" => continue,
                Err(e) => return Err(e),
            };
            if photo.state != "trashed" {
                return Err("PhotoNotTrashed".into());
            }
            if self.cloud_media_read_only(id.clone())? {
                return Err("CloudMediaReadOnly".into());
            }
            let source = PathBuf::from(&photo.path);
            let op = Uuid::new_v4().to_string();
            let stage = source.with_file_name(format!(".photo-client-purge-{op}"));
            let library = self.library_id.clone();
            let operation = op.clone();
            let media_id = id.clone();
            let source_uri = photo.path.clone();
            let stage_uri = stage.to_string_lossy().into_owned();
            self.execute(move|c|{c.execute("INSERT INTO pending_purges(library_id,operation_id,media_id,source_uri,staged_uri) VALUES(?1,?2,?3,?4,?5)",params![library,operation,media_id,source_uri,stage_uri]).map_err(error)?;Ok(())})?;
            prepared.push((id, op, source, stage));
        }
        let mut rollback = super::system_trash::FileRollback::new();
        for (_, _, source, stage) in &prepared {
            if source.exists() {
                fs::rename(source, stage).map_err(error)?;
                rollback.moves.push((source.clone(), stage.clone()));
            }
        }
        let library = self.library_id.clone();
        let entries = prepared
            .iter()
            .map(|(id, op, _, _)| (id.clone(), op.clone()))
            .collect::<Vec<_>>();
        self.execute(move|c|{let tx=c.transaction().map_err(error)?;
            for(id,op)in entries{
                tx.execute("DELETE FROM file_publications WHERE library_id=?1 AND operation_id IN(SELECT operation_id FROM file_operations WHERE library_id=?1 AND media_id=?2)",params![library,id]).map_err(error)?;
                for table in ["thumbnails","album_members","file_operations","edit_projects","library_memberships"]{
                    if table=="edit_projects"{tx.execute("DELETE FROM edit_steps WHERE library_id=?1 AND edit_id IN(SELECT edit_id FROM edit_projects WHERE library_id=?1 AND media_id=?2)",params![library,id]).map_err(error)?;}
                    tx.execute(&format!("DELETE FROM {table} WHERE library_id=?1 AND media_id=?2"),params![library,id]).map_err(error)?;
                }
                tx.execute("DELETE FROM media WHERE library_id=?1 AND media_id=?2",params![library,id]).map_err(error)?;
                tx.execute("UPDATE pending_purges SET committed=1 WHERE library_id=?1 AND operation_id=?2",params![library,op]).map_err(error)?;
            }
            tools::recount(&tx,&library)?;tx.commit().map_err(error)
        })?;
        rollback.committed = true;
        let count = prepared.len() as u64;
        for (_, op, source, stage) in prepared {
            if stage.exists() {
                fs::remove_file(stage).map_err(error)?;
            }
            if let Some(info) = super::system_trash::info_for(&source) {
                let _ = fs::remove_file(info);
            }
            let library = self.library_id.clone();
            self.execute(move |c| {
                c.execute(
                    "DELETE FROM pending_purges WHERE library_id=?1 AND operation_id=?2",
                    params![library, op],
                )
                .map_err(error)?;
                Ok(())
            })?;
        }
        Ok(count)
    }
}
