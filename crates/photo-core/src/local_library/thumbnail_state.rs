//! Persistent thumbnail bookkeeping; files remain the source of cache availability.
use super::*;

impl LocalLibrary {
    pub fn thumbnail_cache_membership(&self) -> Result<std::collections::HashSet<String>, String> {
        let library = self.library_id.clone();
        self.execute(move |c| {
            let mut stmt = c
                .prepare("SELECT media_id FROM media WHERE library_id=?1")
                .map_err(error)?;
            stmt.query_map([library], |r| r.get(0))
                .map_err(error)?
                .collect::<rusqlite::Result<_>>()
                .map_err(error)
        })
    }
    pub fn record_thumbnail_states(
        &self,
        rows: Vec<(LocalPhoto, u32, String, String)>,
    ) -> Result<(), String> {
        let library = self.library_id.clone();
        let revision = format!("r{}", crate::media::THUMBNAIL_CACHE_REVISION);
        let root = self.root.clone();
        self.execute(move |c| {
            let tx = c.transaction().map_err(error)?;
            for (photo, size, path, state) in rows {
                let path = Path::new(&path).strip_prefix(&root).map(|p|p.to_string_lossy().into_owned()).unwrap_or(path);
                tx.execute("INSERT INTO thumbnails(library_id,media_id,content_version,size_class,cache_key,relative_path,state)
                    SELECT ?1,?2,?3,?4,?5,?6,?7 WHERE EXISTS(SELECT 1 FROM media WHERE library_id=?1 AND media_id=?2 AND content_version=?3)
                    ON CONFLICT(library_id,media_id,content_version,size_class) DO UPDATE SET cache_key=excluded.cache_key,relative_path=excluded.relative_path,state=excluded.state,error_code=NULL",
                    params![library,photo.id,i64::try_from(photo.content_version).map_err(|_|"VersionOutOfRange")?,size,revision,path,state]).map_err(error)?;
            }
            tx.commit().map_err(error)
        })
    }
    /// Cache bookkeeping never replaces the foreground query's narrow index.
    pub(crate) fn thumbnail_reconcile_window(
        &self,
        start: usize,
    ) -> Result<Vec<LocalPhoto>, String> {
        let library = self.library_id.clone();
        self.execute(move|c|{
            let mut statement=c.prepare("SELECT media_id,source_uri,display_name,parent_uri,size_bytes,modified_ns,content_version,width,height,favorite,sort_time_ms,media_kind,mime_type,orientation,capture_time_ms,state,trashed_at_ms FROM media WHERE library_id=?1 AND state='active' ORDER BY sort_time_ms DESC,media_id DESC LIMIT 100 OFFSET ?2").map_err(error)?;
            statement.query_map(params![library,start as i64],decode_photo).map_err(error)?.collect::<rusqlite::Result<_>>().map_err(error)
        })
    }
    pub fn thumbnail_counts(&self, size: u32) -> Result<(u64, u64, u64), String> {
        let library = self.library_id.clone();
        let revision = format!("r{}", crate::media::THUMBNAIL_CACHE_REVISION);
        self.execute(move |c| c.query_row("SELECT COUNT(*),COALESCE(SUM(t.state='ready'),0),COALESCE(SUM(t.state='failed'),0)
            FROM media m LEFT JOIN thumbnails t ON t.library_id=m.library_id AND t.media_id=m.media_id AND t.content_version=m.content_version AND t.size_class=?2 AND t.cache_key=?3
            WHERE m.library_id=?1 AND m.state='active'",params![library,size,revision],|r|Ok((sql_u64(r,0)?,sql_u64(r,1)?,sql_u64(r,2)?))).map_err(error))
    }
    pub fn next_thumbnail_candidate(
        &self,
        size: u32,
        anchor: Option<String>,
    ) -> Result<Option<LocalPhoto>, String> {
        let library = self.library_id.clone();
        let revision = format!("r{}", crate::media::THUMBNAIL_CACHE_REVISION);
        self.execute(move|c|{
            let anchor_time=anchor.as_ref().and_then(|id|c.query_row("SELECT sort_time_ms FROM media WHERE library_id=?1 AND media_id=?2",params![library,id],|r|r.get::<_,i64>(0)).ok());
            let sql="SELECT m.media_id,m.source_uri,m.display_name,m.parent_uri,m.size_bytes,m.modified_ns,m.content_version,m.width,m.height,m.favorite,m.sort_time_ms,m.media_kind,m.mime_type,m.orientation,m.capture_time_ms,m.state,m.trashed_at_ms
                FROM media m WHERE m.library_id=?1 AND m.state='active'
                AND NOT EXISTS(SELECT 1 FROM thumbnails t WHERE t.library_id=m.library_id AND t.media_id=m.media_id AND t.content_version=m.content_version AND t.size_class=?2 AND t.cache_key=?3 AND t.state IN ('ready','failed'))
                ORDER BY CASE WHEN ?4 IS NULL OR m.sort_time_ms<?4 OR (m.sort_time_ms=?4 AND m.media_id<=?5) THEN 0 ELSE 1 END,m.sort_time_ms DESC,m.media_id DESC LIMIT 1";
            c.query_row(sql,params![library,size,revision,anchor_time,anchor],decode_photo).optional().map_err(error)
        })
    }
}
