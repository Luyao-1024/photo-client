use super::*;

/// Narrow native index. Only the active query is retained; photo DTOs stay paged.
pub type MediaFlagsById = std::collections::HashMap<String, (Option<i64>, Option<i64>)>;

pub struct BrowseIndex {
    revision: u64,
    filter: PhotoFilter,
    ids: Vec<String>,
    groups: Option<Vec<(i64, u64)>>,
}
/// Favorite edits change DTOs/counters, not date/name ordering. Advance only
/// an index captured at the pre-edit revision; never bless a stale structural
/// snapshot. Favorite-filtered queries must rebuild membership normally.
pub(super) fn retain_order_after_favorite(
    cache: &Mutex<Option<BrowseIndex>>,
    before: u64,
    after: u64,
) {
    if let Ok(mut cache) = cache.lock() {
        if let Some(index) = cache.as_mut() {
            if index.revision == before && !index.filter.favorites_only {
                index.revision = after;
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceInfo {
    pub id: String,
    pub path: String,
    pub kind: String,
    pub enabled: bool,
    pub availability: String,
}

fn normalized_date(input: &str) -> Option<String> {
    let mut date = input
        .trim()
        .replace(['年', '月', '/', '.'], "-")
        .replace('日', "");
    while date.ends_with('-') {
        date.pop();
    }
    if date.len() == 8 && date.bytes().all(|c| c.is_ascii_digit()) {
        date = format!("{}-{}-{}", &date[..4], &date[4..6], &date[6..]);
    } else if date.len() == 6 && date.bytes().all(|c| c.is_ascii_digit()) {
        date = format!("{}-{}", &date[..4], &date[4..]);
    }
    let parts: Vec<_> = date.split('-').collect();
    if parts.is_empty() || parts.len() > 3 || parts[0].len() != 4 {
        return None;
    }
    let year: u32 = parts[0].parse().ok()?;
    if !(1..=9999).contains(&year) {
        return None;
    }
    let mut out = format!("{year:04}");
    for (i, part) in parts.iter().enumerate().skip(1) {
        let value: u32 = part.parse().ok()?;
        if value == 0 || value > if i == 1 { 12 } else { 31 } {
            return None;
        }
        out.push_str(&format!("-{value:02}"));
    }
    Some(format!("{out}%"))
}
pub(super) fn filter_sql(
    library: &str,
    filter: &PhotoFilter,
) -> Result<(String, Vec<Value>), String> {
    let scope = if filter.search_scope.is_empty() {
        "all"
    } else {
        &filter.search_scope
    };
    if !matches!(scope, "all" | "name" | "date") || filter.search.len() > 1024 {
        return Err("InvalidQuery".into());
    }
    if filter
        .media_kind
        .as_ref()
        .is_some_and(|k| !matches!(k.as_str(), "image" | "video" | "motion"))
    {
        return Err("InvalidMediaKind".into());
    }
    let mut clause = "library_id=? AND state=?".to_string();
    let mut values = vec![
        Value::Text(library.into()),
        Value::Text(if filter.trashed { "trashed" } else { "active" }.into()),
    ];
    if filter.favorites_only {
        clause.push_str(" AND favorite=1");
    }
    if !filter.search.trim().is_empty() {
        let date = normalized_date(&filter.search);
        let date_sql = "substr(datetime(sort_time_ms/1000,'unixepoch','localtime'),1,10) LIKE ?";
        match scope {
            "date" => {
                clause.push_str(&format!(" AND {date_sql}"));
                values.push(Value::Text(date.unwrap_or_else(|| "!invalid-date!".into())));
            }
            "all" if date.is_some() => {
                clause.push_str(&format!(
                    " AND (instr(lower(display_name),lower(?))>0 OR {date_sql})"
                ));
                values.push(Value::Text(filter.search.clone()));
                values.push(Value::Text(date.unwrap()));
            }
            _ => {
                clause.push_str(" AND instr(lower(display_name),lower(?))>0");
                values.push(Value::Text(filter.search.clone()));
            }
        }
    }
    if let Some(folder) = &filter.folder {
        clause.push_str(" AND parent_uri=?");
        values.push(Value::Text(folder.clone()));
    }
    if let Some(kind) = &filter.media_kind {
        if kind == "motion" {
            clause.push_str(" AND EXISTS(SELECT 1 FROM media_details d WHERE d.library_id=media.library_id AND d.media_id=media.media_id AND d.motion_offset>0)");
        } else {
            clause.push_str(" AND media_kind=?");
            values.push(Value::Text(kind.clone()));
        }
    }
    Ok((clause, values))
}
fn order_sql(order: &str) -> Result<&'static str, String> {
    match order {
        "" | "date_desc" => Ok("sort_time_ms DESC,media_id DESC"),
        "date_asc" => Ok("sort_time_ms ASC,media_id ASC"),
        "name_asc" => Ok("display_name COLLATE NOCASE ASC,media_id ASC"),
        "name_desc" => Ok("display_name COLLATE NOCASE DESC,media_id DESC"),
        _ => Err("InvalidOrder".into()),
    }
}
impl LocalLibrary {
    pub fn query_window(
        &self,
        filter: PhotoFilter,
        start: usize,
        count: usize,
    ) -> Result<LocalPage, String> {
        if count == 0 || count > 2000 {
            return Err("InvalidQuery".into());
        }
        let library = self.library_id.clone();
        let cache = self.browse_index.clone();
        self.execute(move |c| query_window_db(c, &library, &cache, filter, start, count))
    }
    pub fn browse_groups(&self, filter: PhotoFilter) -> Result<Vec<(i64, u64)>, String> {
        let library = self.library_id.clone();
        let cache = self.browse_index.clone();
        self.execute(move |c| groups_db(c, &library, &cache, &filter))
    }
    /// Page, groups and media flags share one actor/read snapshot. Background
    /// admission cannot splice a newer section layout into an older DTO page.
    pub fn browse_window(
        &self,
        filter: PhotoFilter,
        start: usize,
        count: usize,
        groups: bool,
    ) -> Result<(LocalPage, Vec<(i64, u64)>, MediaFlagsById), String> {
        if count == 0 || count > 2000 {
            return Err("InvalidQuery".into());
        }
        let library = self.library_id.clone();
        let cache = self.browse_index.clone();
        self.execute(move|c|{
            let tx=c.transaction().map_err(error)?;
            let page=query_window_db(&tx,&library,&cache,filter.clone(),start,count)?;
            let groups=if groups{groups_db(&tx,&library,&cache,&filter)?}else{Vec::new()};
            let mut statement=tx.prepare_cached("SELECT duration_ms,motion_offset FROM media_details WHERE library_id=?1 AND media_id=?2").map_err(error)?;
            let mut flags=std::collections::HashMap::new();
            for photo in &page.items {if let Some(value)=statement.query_row(params![library,photo.id],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(error)?{flags.insert(photo.id.clone(),value);}}
            drop(statement);tx.commit().map_err(error)?;Ok((page,groups,flags))
        })
    }
    pub fn photo_rank(&self, filter: PhotoFilter, id: String) -> Result<Option<usize>, String> {
        let library = self.library_id.clone();
        let cache = self.browse_index.clone();
        self.execute(move |c| {
            query_window_db(c, &library, &cache, filter, 0, 1)?;
            let cache = cache.lock().map_err(|_| "LibraryUnavailable")?;
            Ok(cache
                .as_ref()
                .and_then(|i| i.ids.iter().position(|p| p == &id)))
        })
    }
    pub fn media_details(&self, id: String) -> Result<crate::media::details::MediaDetails, String> {
        let photo = self.photo(id.clone())?;
        let details = crate::media::details::read(Path::new(&photo.path));
        self.record_details(vec![(photo.path, details.clone())])?;
        Ok(details)
    }
    pub fn record_details(
        &self,
        items: Vec<(String, crate::media::details::MediaDetails)>,
    ) -> Result<(), String> {
        let library = self.library_id.clone();
        self.execute(move|c|{let tx=c.transaction().map_err(error)?;
            let mut statement=tx.prepare_cached("INSERT INTO media_details(library_id,media_id,duration_ms,camera_make,camera_model,lens,exposure,aperture,iso,focal_length,motion_offset,animated,hdr) SELECT library_id,media_id,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13 FROM media WHERE library_id=?1 AND source_uri=?2 ON CONFLICT(library_id,media_id) DO UPDATE SET duration_ms=excluded.duration_ms,camera_make=excluded.camera_make,camera_model=excluded.camera_model,lens=excluded.lens,exposure=excluded.exposure,aperture=excluded.aperture,iso=excluded.iso,focal_length=excluded.focal_length,motion_offset=excluded.motion_offset,animated=excluded.animated,hdr=excluded.hdr").map_err(error)?;
            for(path,d)in items{statement.execute(params![library,path,d.duration_ms,d.camera_make,d.camera_model,d.lens,d.exposure,d.aperture,d.iso,d.focal_length,d.motion_offset,d.animated,d.hdr]).map_err(error)?;}
            drop(statement);tx.commit().map_err(error)
        })
    }
    pub fn media_flags(&self, ids: Vec<String>) -> Result<MediaFlagsById, String> {
        let library = self.library_id.clone();
        self.execute(move|c|{let mut statement=c.prepare_cached("SELECT duration_ms,motion_offset FROM media_details WHERE library_id=?1 AND media_id=?2").map_err(error)?;let mut result=std::collections::HashMap::new();for id in ids{if let Some(flags)=statement.query_row(params![library,id],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(error)?{result.insert(id,flags);}}Ok(result)})
    }
    pub fn log_event(&self, operation: &str, ok: bool, elapsed_ms: u128) {
        use std::io::Write;
        if self
            .preferences()
            .ok()
            .and_then(|p| serde_json::from_str::<serde_json::Value>(&p).ok())
            .is_some_and(|p| p["logLevel"] == "error")
            && ok
        {
            return;
        }
        let dir = self.root.join("logs");
        if fs::create_dir_all(&dir).is_err() {
            return;
        }
        let path = dir.join("local.log");
        if fs::metadata(&path).is_ok_and(|m| m.len() > 5 * 1024 * 1024) {
            let old = dir.join("local.previous.log");
            let _ = fs::remove_file(&old);
            let _ = fs::rename(&path, &old);
        }
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(
                file,
                "{{\"time_ms\":{},\"operation\":\"{}\",\"result\":\"{}\",\"elapsed_ms\":{}}}",
                now_ms(),
                operation,
                if ok { "complete" } else { "failed" },
                elapsed_ms
            );
        }
    }
    pub fn clear_logs(&self) -> Result<(), String> {
        let dir = self.root.join("logs");
        if dir.is_dir() {
            fs::remove_dir_all(dir).map_err(error)?;
        }
        Ok(())
    }
    pub fn preferences(&self) -> Result<String, String> {
        self.execute(|c| {
            let mut stmt = c
                .prepare("SELECT key,value FROM local_preferences ORDER BY key")
                .map_err(error)?;
            let rows = stmt
                .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
                .map_err(error)?;
            let mut map = serde_json::Map::new();
            for row in rows {
                let (k, v) = row.map_err(error)?;
                map.insert(k, serde_json::from_str(&v).map_err(error)?);
            }
            Ok(serde_json::Value::Object(map).to_string())
        })
    }
    pub fn set_preference(&self, key: String, value: String) -> Result<(), String> {
        if !matches!(
            key.as_str(),
            "theme"
                | "locale"
                | "glassMode"
                | "transparency"
                | "backgroundBlur"
                | "followScroll"
                | "reduceMotion"
                | "autoPlayMotionPhoto"
                | "dayColumns"
                | "thumbnailWorkers"
                | "logLevel"
                | "order"
                | "cloudAutoSync"
        ) {
            return Err("InvalidPreference".into());
        }
        let parsed: serde_json::Value =
            serde_json::from_str(&value).map_err(|_| "InvalidPreference")?;
        if key == "backgroundBlur" && !parsed.as_f64().is_some_and(|v| (0.0..=1.0).contains(&v)) {
            return Err("InvalidPreference".into());
        }
        if key == "followScroll" && !parsed.is_boolean() {
            return Err("InvalidPreference".into());
        }
        if key == "autoPlayMotionPhoto" && !parsed.is_boolean() {
            return Err("InvalidPreference".into());
        }
        if key == "cloudAutoSync" && !parsed.is_boolean() {
            return Err("InvalidPreference".into());
        }
        if key == "glassMode" {
            // Only transparent materials exist. A solid material is not a
            // preference this build can honour.
            let mode = parsed.as_str().ok_or("InvalidPreference")?;
            if !matches!(mode, "auto" | "full" | "reduced") {
                return Err("InvalidPreference".into());
            }
        }
        self.execute(move|c|{c.execute("INSERT INTO local_preferences VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",params![key,value]).map_err(error)?;Ok(())})
    }
    pub fn sources(&self) -> Result<Vec<SourceInfo>, String> {
        let library = self.library_id.clone();
        self.execute(move|c|{
            let mut stmt=c.prepare("SELECT source_id,root_uri,source_kind,enabled,availability FROM sources WHERE library_id=?1 ORDER BY root_uri").map_err(error)?;
            stmt.query_map([library],|r|Ok(SourceInfo{id:r.get(0)?,path:r.get(1)?,kind:r.get(2)?,enabled:r.get(3)?,availability:r.get(4)?})).map_err(error)?.collect::<rusqlite::Result<Vec<_>>>().map_err(error)
        })
    }
    /// Disable and remove only this source's index; originals remain untouched.
    pub fn remove_source(&self, id: String) -> Result<(), String> {
        let library = self.library_id.clone();
        self.execute(move|c|{
            let kind:Option<String>=c.query_row("SELECT source_kind FROM sources WHERE library_id=?1 AND source_id=?2",params![library,id],|r|r.get(0)).optional().map_err(error)?;
            if kind.as_deref()==Some("managed"){return Err("ManagedSource".into());}
            let tx=c.transaction().map_err(error)?;
            tx.execute("INSERT OR IGNORE INTO excluded_paths SELECT library_id,root_uri FROM sources WHERE library_id=?1 AND source_id=?2",params![library,id]).map_err(error)?;
            // Keep rows for recoverable trash. Live entries become missing and can
            // be explicitly re-admitted when the user adds the source again.
            tx.execute("UPDATE media SET state='missing' WHERE library_id=?1 AND source_id=?2 AND state='active'",params![library,id]).map_err(error)?;
            tx.execute("UPDATE sources SET enabled=0 WHERE library_id=?1 AND source_id=?2",params![library,id]).map_err(error)?;
            recount(&tx,&library)?;tx.commit().map_err(error)
        })
    }
    pub fn reconcile_source(&self, id: String) -> Result<(), String> {
        let library = self.library_id.clone();
        let root = self.root.clone();
        self.execute(move|c|{
            let enabled:bool=c.query_row("SELECT enabled FROM sources WHERE library_id=?1 AND source_id=?2",params![library,id],|r|r.get(0)).optional().map_err(error)?.unwrap_or(false);
            if !enabled {return Ok(());}
            let mut stmt=c.prepare("SELECT media_id,source_uri FROM media WHERE library_id=?1 AND source_id=?2 AND state='active'").map_err(error)?;
            let rows=stmt.query_map(params![library,id],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).map_err(error)?.collect::<rusqlite::Result<Vec<_>>>().map_err(error)?;drop(stmt);
            let tx=c.transaction().map_err(error)?;let mut changed=false;
            for (media_id,path) in rows {if !Path::new(&path).is_file() && !Path::new(&path).starts_with(&root){tx.execute("UPDATE media SET state='missing' WHERE library_id=?1 AND media_id=?2",params![library,media_id]).map_err(error)?;changed=true;}}
            if changed {recount(&tx,&library)?;}tx.commit().map_err(error)
        })
    }
    pub fn reorder_albums(&self, folders: Vec<String>) -> Result<(), String> {
        let library = self.library_id.clone();
        self.execute(move|c|{let tx=c.transaction().map_err(error)?;
            for (position,folder) in folders.into_iter().enumerate(){tx.execute("INSERT INTO album_preferences(library_id,folder,position) VALUES(?1,?2,?3) ON CONFLICT(library_id,folder) DO UPDATE SET position=excluded.position",params![library,folder,position as i64]).map_err(error)?;}tx.commit().map_err(error)})
    }
    pub fn set_album_cover(&self, folder: String, media_id: String) -> Result<(), String> {
        let photo = self.photo(media_id.clone())?;
        if photo.parent != folder || photo.state != "active" {
            return Err("InvalidAlbumCover".into());
        }
        let library = self.library_id.clone();
        self.execute(move|c|{c.execute("INSERT INTO album_preferences(library_id,folder,cover_media_id) VALUES(?1,?2,?3) ON CONFLICT(library_id,folder) DO UPDATE SET cover_media_id=excluded.cover_media_id",params![library,folder,media_id]).map_err(error)?;Ok(())})
    }
    pub fn export_media(&self, ids: Vec<String>, directory: PathBuf) -> Result<u64, String> {
        if !directory.is_dir() {
            return Err("InvalidDestination".into());
        }
        let mut count = 0;
        for id in ids {
            let photo = self.photo(id)?;
            let source = Path::new(&photo.path);
            let target = unique_destination(&directory, &photo.name)?;
            copy_file(source, &target)?;
            count += 1;
        }
        Ok(count)
    }
    pub fn cache_usage(&self) -> Result<u64, String> {
        Ok(walkdir::WalkDir::new(self.root.join("cache"))
            .into_iter()
            .filter_map(Result::ok)
            .filter_map(|e| e.metadata().ok())
            .filter(|m| m.is_file())
            .map(|m| m.len())
            .sum())
    }
    /// Drop the thumbnail cache: the rows of the database and the files on
    /// the disk go together. A row that still says "ready" while its file is
    /// gone would keep the photo from being rendered again, because the
    /// candidate query trusts the row and never asks for a new thumbnail.
    pub fn clear_cache(&self) -> Result<(), String> {
        self.clear_thumbnail_rows()?;
        let cache = self.root.join("cache");
        if cache.is_dir() {
            fs::remove_dir_all(&cache).map_err(error)?;
        }
        fs::create_dir_all(cache).map_err(error)?;
        Ok(())
    }
    /// Drop published thumbnails that do not belong to the current encoding
    /// revision, so a changed encoder rebuilds them instead of reusing the
    /// entries an older encoder wrote. Previews and extracted motion videos
    /// live beside them and are kept.
    pub fn prune_thumbnail_cache(&self) -> Result<(), String> {
        prune_thumbnail_cache_root(&self.root)
    }
}
pub(super) fn recount(c: &Connection, library: &str) -> Result<(), String> {
    c.execute("UPDATE libraries SET media_count=(SELECT COUNT(*) FROM media WHERE library_id=?1 AND state='active'),favorite_count=(SELECT COUNT(*) FROM media WHERE library_id=?1 AND state='active' AND favorite=1),revision=revision+1 WHERE library_id=?1",[library]).map_err(error)?;
    Ok(())
}

impl LocalLibrary {
    /// Reflect file-manager trash / restore / empty operations for included roots.
    pub fn reconcile_trash(&self) -> Result<(), String> {
        let sources = self.sources()?;
        let enabled: Vec<_> = sources
            .iter()
            .filter(|s| s.enabled && s.kind != "managed")
            .collect();
        let mut entries = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for source in &enabled {
            for (original, payload, info) in
                super::system_trash::entries(Path::new(&source.path), &self.root)
            {
                if enabled.iter().any(|s| original.starts_with(&s.path)) && seen.insert(info) {
                    entries.push((original, payload));
                }
            }
        }
        let library = self.library_id.clone();
        self.execute(move|c|{
            let tx=c.transaction().map_err(error)?;let mut changed=false;
            for(original,payload)in entries{
                let original=original.to_string_lossy();let path=payload.to_string_lossy();
                let updated=tx.execute("UPDATE media SET original_uri=COALESCE(original_uri,source_uri),source_uri=?3,parent_uri=?4,state='trashed',trashed_at_ms=COALESCE(trashed_at_ms,?5) WHERE library_id=?1 AND (source_uri=?2 OR original_uri=?2) AND source_uri<>?3",params![library,original,path,payload.parent().unwrap().to_string_lossy(),now_ms()]).map_err(error)?;
                changed|=updated>0;
            }
            let mut stmt=tx.prepare("SELECT media_id,source_uri,original_uri FROM media WHERE library_id=?1 AND state='trashed'").map_err(error)?;
            let rows=stmt.query_map([&library],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,Option<String>>(2)?))).map_err(error)?.collect::<rusqlite::Result<Vec<_>>>().map_err(error)?;drop(stmt);
            for(id,payload,original)in rows{
                if Path::new(&payload).is_file(){continue;}
                if let Some(original)=original.filter(|p|Path::new(p).is_file()){
                    let parent=Path::new(&original).parent().ok_or("InvalidSource")?.to_string_lossy().into_owned();
                    tx.execute("UPDATE media SET source_uri=?3,parent_uri=?4,original_uri=NULL,trashed_at_ms=NULL,state='active' WHERE library_id=?1 AND media_id=?2",params![library,id,original,parent]).map_err(error)?;
                }else{
                    // External emptying removed the physical payload. Retain a
                    // missing identity rather than a false recoverable trash row.
                    tx.execute("UPDATE media SET state='missing',trashed_at_ms=NULL WHERE library_id=?1 AND media_id=?2",params![library,id]).map_err(error)?;
                }
                changed=true;
            }
            if changed{recount(&tx,&library)?;}tx.commit().map_err(error)
        })
    }
    pub fn source_availability(&self, id: String, available: bool) -> Result<(), String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            c.execute(
                "UPDATE sources SET availability=?3 WHERE library_id=?1 AND source_id=?2",
                params![
                    library,
                    id,
                    if available {
                        "available"
                    } else {
                        "unavailable"
                    }
                ],
            )
            .map_err(error)?;
            Ok(())
        })
    }
}

impl LocalLibrary {
    pub(super) fn mutation_guard(&self) -> Result<File, String> {
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(self.root.join("file-operations.lock"))
            .map_err(error)?;
        lock.try_lock_exclusive().map_err(|_| "FileOperationBusy")?;
        Ok(lock)
    }
    pub fn exclusions(&self) -> Result<Vec<PathBuf>, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let mut statement = c
                .prepare("SELECT path FROM excluded_paths WHERE library_id=?1")
                .map_err(error)?;
            statement
                .query_map([library], |r| r.get::<_, String>(0).map(PathBuf::from))
                .map_err(error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(error)
        })
    }
    pub fn remove_album(&self, folder: String) -> Result<(), String> {
        let library = self.library_id.clone();
        self.execute(move|c|{let tx=c.transaction().map_err(error)?;
            tx.execute("INSERT OR IGNORE INTO excluded_paths VALUES(?1,?2)",params![library,folder]).map_err(error)?;
            tx.execute("UPDATE media SET state='missing' WHERE library_id=?1 AND state='active' AND (parent_uri=?2 OR (substr(parent_uri,1,length(?2))=?2 AND substr(parent_uri,length(?2)+1,1)='/'))",params![library,folder]).map_err(error)?;
            tx.execute("UPDATE sources SET enabled=0 WHERE library_id=?1 AND (root_uri=?2 OR (substr(root_uri,1,length(?2))=?2 AND substr(root_uri,length(?2)+1,1)='/'))",params![library,folder]).map_err(error)?;
            tx.execute("DELETE FROM album_preferences WHERE library_id=?1 AND (folder=?2 OR (substr(folder,1,length(?2))=?2 AND substr(folder,length(?2)+1,1)='/'))",params![library,folder]).map_err(error)?;
            recount(&tx,&library)?;tx.commit().map_err(error)
        })
    }
    pub fn rename_album(&self, folder: String, name: String) -> Result<(), String> {
        let _guard = self.mutation_guard()?;
        if name.trim().is_empty() || name == "." || name == ".." || name.contains(['/', '\\']) {
            return Err("InvalidName".into());
        }
        let old = PathBuf::from(&folder);
        if !old.is_dir() {
            return Err("SourceUnavailable".into());
        }
        let new = old.parent().ok_or("InvalidDestination")?.join(&name);
        if new.exists() {
            return Err("DestinationExists".into());
        }
        let new_path = new.to_str().ok_or("UnsupportedPathEncoding")?.to_string();
        let mut rollback = super::system_trash::FileRollback::new();
        move_file(&old, &new)?;
        rollback.moves.push((old, new));
        let library = self.library_id.clone();
        self.execute(move|c|{let tx=c.transaction().map_err(error)?;
            for(table,column)in [("sources","root_uri"),("media","source_uri"),("media","parent_uri"),("media","original_uri"),("album_preferences","folder"),("excluded_paths","path")]{
                let sql=format!("UPDATE {table} SET {column}=?3||substr({column},length(?2)+1) WHERE library_id=?1 AND ({column}=?2 OR (substr({column},1,length(?2))=?2 AND substr({column},length(?2)+1,1)='/'))");
                tx.execute(&sql,params![library,folder,new_path]).map_err(error)?;
            }
            tx.execute("UPDATE media SET display_name=?3 WHERE library_id=?1 AND parent_uri=?2 AND display_name=''",params![library,new_path,name]).map_err(error)?;
            recount(&tx,&library)?;tx.commit().map_err(error)
        })?;
        rollback.committed = true;
        Ok(())
    }
}

impl LocalLibrary {
    pub fn create_album(&self, parent: PathBuf, name: String) -> Result<String, String> {
        let _guard = self.mutation_guard()?;
        if name.trim().is_empty() || name == "." || name == ".." || name.contains(['/', '\\']) {
            return Err("InvalidName".into());
        }
        let path = parent
            .canonicalize()
            .map_err(|_| "SourceUnavailable")?
            .join(name);
        fs::create_dir(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::AlreadyExists {
                "DestinationExists".to_string()
            } else {
                error(e)
            }
        })?;
        let folder = path.to_str().ok_or("UnsupportedPathEncoding")?.to_string();
        let library = self.library_id.clone();
        let value = folder.clone();
        let result = (|| {
            self.add_source(&path)?;
            self.execute(move |c| {
                c.execute(
                    "INSERT INTO album_preferences(library_id,folder) VALUES(?1,?2)",
                    params![library, value],
                )
                .map_err(error)?;
                Ok(())
            })
        })();
        if result.is_err() {
            let _ = fs::remove_dir(path);
        }
        result?;
        Ok(folder)
    }
}

pub(super) fn prune_thumbnail_cache_root(root: &Path) -> Result<(), String> {
    let cache = root.join("cache");
    if !fs::symlink_metadata(&cache).is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink()) {
        return Ok(());
    }
    let current = format!("r{}", crate::media::THUMBNAIL_CACHE_REVISION);
    for media_entry in fs::read_dir(&cache).map_err(error)? {
        let media_entry = media_entry.map_err(error)?;
        if !media_entry.file_type().map_err(error)?.is_dir() {
            continue;
        }
        for version_entry in fs::read_dir(media_entry.path()).map_err(error)? {
            let version_entry = version_entry.map_err(error)?;
            if !version_entry.file_type().map_err(error)?.is_dir() {
                continue;
            }
            for entry in fs::read_dir(version_entry.path()).map_err(error)? {
                let entry = entry.map_err(error)?;
                let path = entry.path();
                let name = entry.file_name();
                let name = name.to_string_lossy();
                let kind = entry.file_type().map_err(error)?;
                if kind.is_symlink() {
                    continue;
                }
                let stale = if kind.is_dir() {
                    name.strip_prefix('r')
                        .and_then(|revision| revision.parse::<u32>().ok())
                        .is_some_and(|revision| revision < crate::media::THUMBNAIL_CACHE_REVISION)
                } else {
                    name.starts_with("thumbnail-")
                };
                if !stale || name == current {
                    continue;
                }
                if path.is_dir() {
                    let _ = fs::remove_dir_all(&path);
                } else {
                    let _ = fs::remove_file(&path);
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod browse_performance_tests {
    use super::*;
    fn input(folder: &Path, name: &str) -> MediaInput {
        let path = folder.join(name);
        fs::write(&path, b"catalog fixture").unwrap();
        MediaInput {
            path: path.to_string_lossy().into(),
            name: name.into(),
            parent: folder.to_string_lossy().into(),
            size_bytes: 15,
            modified_ns: 10000,
            mime_type: "image/jpeg".into(),
            width: None,
            height: None,
            orientation: 1,
            capture_time_ms: None,
        }
    }
    #[test]
    fn favorite_changes_reuse_unfiltered_ranks_but_refresh_filtered_membership() {
        let root = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let library = LocalLibrary::open(root.path()).unwrap();
        let source = library.add_source(folder.path()).unwrap();
        library
            .upsert_batch(
                source,
                vec![input(folder.path(), "a.jpg"), input(folder.path(), "b.jpg")],
            )
            .unwrap();
        let page = library
            .query_window(PhotoFilter::default(), 0, 100)
            .unwrap();
        let id = page.items[0].id.clone();
        let before = library
            .browse_index
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .ids
            .as_ptr();
        library.set_favorite(id.clone(), true).unwrap();
        let page = library
            .query_window(PhotoFilter::default(), 0, 100)
            .unwrap();
        assert_eq!(
            library
                .browse_index
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .ids
                .as_ptr(),
            before
        );
        assert!(page.items[0].favorite);
        let filter = PhotoFilter {
            favorites_only: true,
            ..PhotoFilter::default()
        };
        assert_eq!(
            library.query_window(filter.clone(), 0, 100).unwrap().total,
            1
        );
        library
            .set_favorite(page.items[1].id.clone(), true)
            .unwrap();
        assert_eq!(library.query_window(filter, 0, 100).unwrap().total, 2);
    }
    #[test]
    fn browse_snapshot_keeps_groups_flags_and_foreground_index_together() {
        let root = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let library = LocalLibrary::open(root.path()).unwrap();
        let source = library.add_source(folder.path()).unwrap();
        library
            .upsert_batch(
                source,
                vec![input(folder.path(), "a.jpg"), input(folder.path(), "b.jpg")],
            )
            .unwrap();
        let all = library
            .query_window(PhotoFilter::default(), 0, 100)
            .unwrap();
        library.set_favorite(all.items[0].id.clone(), true).unwrap();
        library
            .record_details(vec![(
                all.items[0].path.clone(),
                crate::media::details::MediaDetails {
                    motion_offset: Some(12),
                    ..Default::default()
                },
            )])
            .unwrap();
        let filter = PhotoFilter {
            favorites_only: true,
            ..Default::default()
        };
        let (page, groups, flags) = library.browse_window(filter.clone(), 0, 100, true).unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(
            groups.iter().map(|(_, count)| count).sum::<u64>(),
            page.total
        );
        assert_eq!(flags.get(&page.items[0].id), Some(&(None, Some(12))));
        assert_eq!(
            library
                .photo_rank(filter, page.items[0].id.clone())
                .unwrap(),
            Some(0)
        );
        let before = library
            .browse_index
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .ids
            .as_ptr();
        assert_eq!(library.thumbnail_reconcile_window(0).unwrap().len(), 2);
        let cache = library.browse_index.lock().unwrap();
        let index = cache.as_ref().unwrap();
        assert_eq!(index.ids.as_ptr(), before);
        assert!(index.filter.favorites_only);
        assert_eq!(index.groups.as_ref().unwrap(), &groups);
    }
    #[test]
    fn a_favorite_edit_cannot_bless_an_index_stale_from_an_insert() {
        let root = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let library = LocalLibrary::open(root.path()).unwrap();
        let source = library.add_source(folder.path()).unwrap();
        library
            .upsert_batch(source.clone(), vec![input(folder.path(), "a.jpg")])
            .unwrap();
        let page = library
            .query_window(PhotoFilter::default(), 0, 100)
            .unwrap();
        library
            .upsert_batch(source, vec![input(folder.path(), "b.jpg")])
            .unwrap();
        library
            .set_favorite(page.items[0].id.clone(), true)
            .unwrap();
        assert_eq!(
            library
                .query_window(PhotoFilter::default(), 0, 100)
                .unwrap()
                .total,
            2
        );
    }
}

fn query_window_db(
    c: &Connection,
    library: &str,
    cache: &Mutex<Option<BrowseIndex>>,
    filter: PhotoFilter,
    start: usize,
    count: usize,
) -> Result<LocalPage, String> {
    let revision: u64 = c
        .query_row(
            "SELECT revision FROM libraries WHERE library_id=?1",
            [&library],
            |r| sql_u64(r, 0),
        )
        .map_err(error)?;
    let mut cache = cache.lock().map_err(|_| "LibraryUnavailable")?;
    if cache
        .as_ref()
        .is_none_or(|idx| idx.revision != revision || idx.filter != filter)
    {
        let (clause, values) = filter_sql(&library, &filter)?;
        let sql = format!(
            "SELECT media_id FROM media WHERE {clause} ORDER BY {}{}",
            if filter.search.is_empty() {
                ""
            } else {
                "media_kind ASC,"
            },
            order_sql(&filter.order)?
        );
        let mut stmt = c.prepare(&sql).map_err(error)?;
        let ids = stmt
            .query_map(rusqlite::params_from_iter(values), |r| r.get(0))
            .map_err(error)?
            .collect::<rusqlite::Result<Vec<String>>>()
            .map_err(error)?;
        *cache = Some(BrowseIndex {
            revision,
            filter,
            ids,
            groups: None,
        });
    }
    let index = cache.as_ref().ok_or("LibraryUnavailable")?;
    let ids =
        &index.ids[start.min(index.ids.len())..start.saturating_add(count).min(index.ids.len())];
    let mut stmt = c.prepare_cached(PHOTO_COLUMNS).map_err(error)?;
    let mut items = Vec::with_capacity(ids.len());
    for id in ids {
        items.push(
            stmt.query_row(params![library, id], decode_photo)
                .map_err(error)?,
        );
    }
    Ok(LocalPage {
        items,
        total: index.ids.len() as u64,
        revision,
        next_cursor: None,
    })
}

fn groups_db(
    c: &Connection,
    library: &str,
    cache: &Mutex<Option<BrowseIndex>>,
    filter: &PhotoFilter,
) -> Result<Vec<(i64, u64)>, String> {
    let revision = c
        .query_row(
            "SELECT revision FROM libraries WHERE library_id=?1",
            [library],
            |r| sql_u64(r, 0),
        )
        .map_err(error)?;
    if let Some(groups) = cache
        .lock()
        .map_err(|_| "LibraryUnavailable")?
        .as_ref()
        .filter(|index| index.revision == revision && index.filter == *filter)
        .and_then(|index| index.groups.clone())
    {
        return Ok(groups);
    }

    let (clause, values) = filter_sql(&library, &filter)?;
    let grouping = if filter.order.starts_with("name_") {
        "'all'"
    } else {
        "date(sort_time_ms/1000,'unixepoch','localtime')"
    };
    let direction = if filter.order == "date_asc" {
        "ASC"
    } else {
        "DESC"
    };
    let sql = if filter.search.is_empty() {
        format!(
            "SELECT MIN(sort_time_ms),COUNT(*) FROM media WHERE {clause} GROUP BY {grouping} ORDER BY MIN(sort_time_ms) {direction}"
        )
    } else {
        format!(
            "SELECT CASE media_kind WHEN 'video' THEN -1 ELSE -2 END,COUNT(*) FROM media WHERE {clause} GROUP BY media_kind ORDER BY media_kind ASC"
        )
    };
    let mut stmt = c.prepare(&sql).map_err(error)?;
    let groups = stmt
        .query_map(rusqlite::params_from_iter(values), |r| {
            Ok((r.get(0)?, sql_u64(r, 1)?))
        })
        .map_err(error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(error)?;

    if let Some(index) = cache
        .lock()
        .map_err(|_| "LibraryUnavailable")?
        .as_mut()
        .filter(|index| index.revision == revision && index.filter == *filter)
    {
        index.groups = Some(groups.clone());
    }
    Ok(groups)
}
