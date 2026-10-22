//! Library-scoped priority scheduling, disk fast path and single-worker idle prewarm.
//! No database, file I/O or decoding runs under the scheduler mutex.
use crate::{
    local_library::{LocalLibrary, LocalPhoto},
    media,
};
use serde::Serialize;
use std::{
    cmp::Reverse,
    collections::{BinaryHeap, HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{Arc, Condvar, Mutex, RwLock},
    thread,
    time::{Duration, Instant},
};
use tokio::sync::oneshot;

/// Match the old fastest tier while respecting process CPU affinity/quota.
pub fn fastest_worker_count() -> usize {
    let available = thread::available_parallelism()
        .map(usize::from)
        .unwrap_or(2);
    let text = std::fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let mut cores = HashSet::new();
    for block in text.split("\n\n") {
        let value = |name: &str| {
            block
                .lines()
                .filter_map(|l| l.split_once(':'))
                .find(|(key, _)| key.trim() == name)
                .map(|(_, v)| v.trim())
        };
        if let Some(core) = value("core id") {
            cores.insert((value("physical id").unwrap_or("0"), core));
        }
    }
    if cores.is_empty() {
        available
    } else {
        cores.len().min(available)
    }
    .clamp(1, 32)
}

type Reply = Result<String, String>;
#[derive(Clone, Debug, Hash, PartialEq, Eq, PartialOrd, Ord)]
struct Key {
    id: String,
    version: u64,
    size: u32,
}
impl Key {
    fn new(p: &LocalPhoto, size: u32) -> Self {
        Self {
            id: p.id.clone(),
            version: p.content_version,
            size,
        }
    }
}
struct Job {
    photo: LocalPhoto,
    tier: u8,
    seq: u64,
    started: bool,
    background: bool,
    queued: Instant,
    waiters: HashMap<String, oneshot::Sender<Reply>>,
}
#[derive(Default)]
struct State {
    queue: BinaryHeap<Reverse<(u8, u64, Key)>>,
    jobs: HashMap<Key, Job>,
    sequence: u64,
    cache: HashMap<Key, (String, u64)>,
    failures: HashMap<Key, String>,
    bad_cloud: HashSet<(String, u64)>,
    cancelled: HashSet<String>,
    closed: bool,
    prewarm: bool,
    paused: bool,
    background_busy: bool,
    next_background: Option<Instant>,
    reconcile: Option<usize>,
    anchor: Option<String>,
    size: u32,
    maintenance: bool,
    budget_limited: bool,
    cache_epoch: u64,
    completion_reported: bool,
    metrics: Metrics,
}
#[derive(Default, Clone, Serialize)]
pub struct Metrics {
    pub generated: u64,
    pub processed: u64,
    pub disk_hits: u64,
    pub memory_hits: u64,
    pub merged: u64,
    pub cancelled: u64,
    pub failed: u64,
    pub max_queue_wait_ms: u64,
    pub generation_ms: u64,
    pub background_queries: u64,
}
#[derive(Serialize)]
pub struct Progress {
    pub total: u64,
    pub ready: u64,
    pub failed: u64,
    pub size_class: u32,
    pub queued: usize,
    pub running: usize,
    pub reconciling: bool,
    pub cache_limit_reached: bool,
    pub cache_epoch: u64,
    pub metrics: Metrics,
}
struct Inner {
    store: LocalLibrary,
    state: Mutex<State>,
    wake: Condvar,
    publication: RwLock<()>,
}
pub struct ThumbnailLoader {
    inner: Arc<Inner>,
    threads: Mutex<Vec<thread::JoinHandle<()>>>,
}

impl ThumbnailLoader {
    pub fn new(store: LocalLibrary, workers: usize) -> Self {
        let inner = Arc::new(Inner {
            store,
            state: Mutex::new(State {
                size: 512,
                reconcile: Some(0),
                maintenance: true,
                ..State::default()
            }),
            wake: Condvar::new(),
            publication: RwLock::new(()),
        });
        let mut threads = Vec::new();
        for index in 0..workers.clamp(1, 32) {
            let worker = inner.clone();
            threads.push(
                thread::Builder::new()
                    .name(format!("photo-thumb-{index}"))
                    .spawn(move || worker_loop(worker))
                    .expect("thumbnail worker"),
            );
        }
        Self {
            inner,
            threads: Mutex::new(threads),
        }
    }
    pub fn resume_prewarm(&self) {
        let mut s = self.inner.state.lock().unwrap();
        s.prewarm = true;
        s.paused = false;
        s.reconcile = Some(0);
        s.completion_reported = false;
        s.next_background = None;
        self.inner.wake.notify_all();
    }
    pub fn wake_after_library_change(&self) {
        let mut s = self.inner.state.lock().unwrap();
        s.completion_reported = false;
        s.next_background = None;
        self.inner.wake.notify_all();
    }
    pub fn pause_prewarm(&self) {
        self.inner.state.lock().unwrap().paused = true;
    }
    pub fn viewport(&self, id: Option<String>, size: u32) {
        let mut s = self.inner.state.lock().unwrap();
        s.anchor = id;
        if [256, 512, 1024].contains(&size) && s.size != size {
            s.size = size;
            s.reconcile = Some(0);
            s.completion_reported = false;
        }
        s.next_background = None;
        self.inner.wake.notify_all();
    }
    pub fn close(&self) {
        let mut s = self.inner.state.lock().unwrap();
        s.closed = true;
        s.queue.clear();
        for (_, job) in s.jobs.drain() {
            for (_, tx) in job.waiters {
                let _ = tx.send(Err("LibraryClosed".into()));
            }
        }
        self.inner.wake.notify_all();
        drop(s);
        for handle in self.threads.lock().unwrap().drain(..) {
            let _ = handle.join();
        }
    }
    pub fn progress(&self) -> Result<Progress, String> {
        let (size, queued, running, reconciling, metrics, budget_limited, cache_epoch) = {
            let s = self.inner.state.lock().unwrap();
            (
                s.size,
                s.jobs.values().filter(|j| !j.started).count(),
                s.jobs.values().filter(|j| j.started).count(),
                s.reconcile.is_some(),
                s.metrics.clone(),
                s.budget_limited,
                s.cache_epoch,
            )
        };
        let (total, ready, failed) = self.inner.store.thumbnail_counts(size)?;
        Ok(Progress {
            total,
            ready,
            failed,
            size_class: size,
            queued,
            running,
            reconciling,
            cache_limit_reached: budget_limited,
            cache_epoch,
            metrics,
        })
    }
    pub fn cancel(&self, token: &str) {
        let mut s = self.inner.state.lock().unwrap();
        let mut remove = Vec::new();
        let mut found = false;
        for (key, job) in &mut s.jobs {
            if job.waiters.remove(token).is_some() {
                found = true;
                if !job.started && !job.background && job.waiters.is_empty() {
                    remove.push(key.clone());
                }
            }
        }
        for key in remove {
            s.jobs.remove(&key);
            s.metrics.cancelled += 1;
        }
        if !found {
            if s.cancelled.len() >= 8192 {
                s.cancelled.clear();
            }
            s.cancelled.insert(token.into());
        }
    }
    pub fn promote(&self, id: &str, version: u64, size: u32) {
        let key = Key {
            id: id.into(),
            version,
            size,
        };
        let mut s = self.inner.state.lock().unwrap();
        if let Some(job) = s.jobs.get_mut(&key) {
            if !job.started && job.tier > 0 {
                job.tier = 0;
                let seq = job.seq;
                s.queue.push(Reverse((0, seq, key)));
                self.inner.wake.notify_one();
            }
        }
    }
    pub fn invalidate(&self, id: &str, version: u64, size: u32) -> Result<(), String> {
        self.invalidate_with_path(id, version, size, None)
    }
    pub fn invalidate_with_path(
        &self,
        id: &str,
        version: u64,
        size: u32,
        bad_path: Option<String>,
    ) -> Result<(), String> {
        let _publication = self.inner.publication.write().unwrap();
        let key = Key {
            id: id.into(),
            version,
            size,
        };
        {
            let mut s = self.inner.state.lock().unwrap();
            let previous = s.cache.remove(&key).map(|(path, _)| path);
            if bad_path.or(previous).is_some_and(|path| {
                Path::new(&path).starts_with(self.inner.store.root.join("cloud"))
            }) {
                if s.bad_cloud.len() >= 512 {
                    s.bad_cloud.clear();
                }
                s.bad_cloud.insert((id.into(), version));
            }
            s.failures.remove(&key);
        }
        let photo = self.inner.store.photo(id.into())?;
        if photo.content_version != version {
            return Ok(());
        }
        let path = cache_path(&self.inner.store, &key);
        let _ = std::fs::remove_file(path);
        self.inner.store.record_thumbnail_states(vec![(
            photo,
            size,
            String::new(),
            "pending".into(),
        )])?;
        self.wake_after_library_change();
        Ok(())
    }
    pub fn cache_usage(&self) -> u64 {
        walkdir::WalkDir::new(self.inner.store.root.join("cache"))
            .follow_links(false)
            .follow_root_links(false)
            .into_iter()
            .flatten()
            .filter(|entry| entry.file_type().is_file() && is_thumbnail_file(entry.path()))
            .filter_map(|entry| entry.metadata().ok())
            .map(|meta| meta.len())
            .sum()
    }
    /// Drop the thumbnail cache: the files, the rows of the database and the
    /// memory of this loader go together.
    ///
    /// The write lock keeps a job from publishing while the cache is being
    /// emptied, so no row can claim a file that the clear just removed.
    pub fn clear_disk(&self) -> Result<(), String> {
        let _publication = self.inner.publication.write().unwrap();
        for entry in walkdir::WalkDir::new(self.inner.store.root.join("cache"))
            .follow_links(false)
            .follow_root_links(false)
            .into_iter()
            .flatten()
        {
            if entry.file_type().is_file() && is_thumbnail_file(entry.path()) {
                std::fs::remove_file(entry.path()).map_err(|_| "CacheUnavailable")?;
            }
        }
        self.inner.store.clear_thumbnail_rows()?;
        self.clear_memory();
        Ok(())
    }
    pub fn clear_memory(&self) {
        let mut s = self.inner.state.lock().unwrap();
        s.cache.clear();
        s.failures.clear();
        s.bad_cloud.clear();
        s.cache_epoch += 1;
        s.budget_limited = false;
        s.completion_reported = false;
        s.reconcile = Some(0);
        s.next_background = None;
        self.inner.wake.notify_all();
    }
    /// Metadata lookup happens on a blocking caller, while the returned receiver
    /// waits asynchronously. Cache hits never enter the generation worker queue.
    pub fn request(
        &self,
        id: String,
        version: Option<u64>,
        size: u32,
        token: String,
        tier: u8,
    ) -> Result<oneshot::Receiver<Reply>, String> {
        if ![256, 512, 1024].contains(&size) {
            return Err("InvalidThumbnailSizeClass".into());
        }
        let (tx, rx) = oneshot::channel();
        let cached = {
            let mut s = self.inner.state.lock().unwrap();
            if s.closed {
                return Err("LibraryClosed".into());
            }
            if s.cancelled.remove(&token) {
                return Err("ThumbnailCancelled".into());
            }
            s.sequence += 1;
            let seq = s.sequence;
            version.and_then(|v| {
                let key = Key {
                    id: id.clone(),
                    version: v,
                    size,
                };
                s.cache.get_mut(&key).map(|(path, stamp)| {
                    *stamp = seq;
                    path.clone()
                })
            })
        };
        if let Some(path) = cached
            && Path::new(&path).is_file()
        {
            self.inner.state.lock().unwrap().metrics.memory_hits += 1;
            let _ = tx.send(Ok(path));
            return Ok(rx);
        }
        let photo = self.inner.store.photo(id)?;
        if version.is_some_and(|v| v != photo.content_version) {
            return Err("SourceChanged".into());
        }
        let key = Key::new(&photo, size);
        let path = cache_path(&self.inner.store, &key);
        if valid_cache(&path, size) {
            let path = path.to_string_lossy().into_owned();
            remember(&self.inner, key, path.clone());
            self.inner.state.lock().unwrap().metrics.disk_hits += 1;
            let _ = tx.send(Ok(path));
            return Ok(rx);
        }
        if let Some(path) =
            cached_cloud_thumbnail(&self.inner, &photo).filter(|p| valid_cache(Path::new(p), size))
        {
            if self.inner.store.photo(photo.id.clone())?.content_version != photo.content_version {
                return Err("SourceChanged".into());
            }
            remember(&self.inner, key, path.clone());
            self.inner.state.lock().unwrap().metrics.disk_hits += 1;
            let _ = tx.send(Ok(path));
            return Ok(rx);
        }
        if let Some(error) = self.inner.state.lock().unwrap().failures.get(&key).cloned() {
            let _ = tx.send(Err(error));
            return Ok(rx);
        }
        let mut s = self.inner.state.lock().unwrap();
        if s.closed {
            return Err("LibraryClosed".into());
        }
        if s.cancelled.remove(&token) {
            return Err("ThumbnailCancelled".into());
        }
        if let Some(job) = s.jobs.get_mut(&key) {
            job.waiters.insert(token, tx);
            if tier < job.tier && !job.started {
                job.tier = tier;
                let seq = job.seq;
                s.queue.push(Reverse((tier, seq, key)));
            }
            s.metrics.merged += 1;
        } else {
            if s.jobs.len() >= 8192 {
                return Err("ThumbnailQueueFull".into());
            }
            s.sequence += 1;
            let seq = s.sequence;
            let mut waiters = HashMap::new();
            waiters.insert(token, tx);
            s.jobs.insert(
                key.clone(),
                Job {
                    photo,
                    tier,
                    seq,
                    started: false,
                    background: false,
                    queued: Instant::now(),
                    waiters,
                },
            );
            s.queue.push(Reverse((tier, seq, key)));
        }
        self.inner.wake.notify_one();
        Ok(rx)
    }
    /// Read-only lookahead: never enqueue or decode an original for prefetch.
    pub fn cached_path(
        &self,
        id: String,
        version: u64,
        size: u32,
    ) -> Result<Option<String>, String> {
        if ![256, 512, 1024].contains(&size) {
            return Err("InvalidThumbnailSizeClass".into());
        }
        let key = Key {
            id: id.clone(),
            version,
            size,
        };
        let cached = {
            let s = self.inner.state.lock().unwrap();
            if s.closed {
                return Err("LibraryClosed".into());
            }
            s.cache.get(&key).map(|(p, _)| p.clone())
        };
        if let Some(path) = cached
            && Path::new(&path).is_file()
        {
            return Ok(Some(path));
        }
        let photo = self.inner.store.photo(id)?;
        if photo.content_version != version {
            return Err("SourceChanged".into());
        }
        let path = cache_path(&self.inner.store, &key);
        if valid_cache(&path, size) {
            return Ok(Some(path.to_string_lossy().into()));
        }
        Ok(cached_cloud_thumbnail(&self.inner, &photo).filter(|p| valid_cache(Path::new(p), size)))
    }
    pub fn embedded(&self, id: String, version: u64) -> Result<Option<String>, String> {
        let _publication = self.inner.publication.read().unwrap();
        let photo = self.inner.store.photo(id)?;
        if photo.content_version != version {
            return Ok(None);
        }
        let path =
            cache_path(&self.inner.store, &Key::new(&photo, 256)).with_file_name("embedded.jpg");
        if path.is_file() {
            return Ok(Some(path.to_string_lossy().into_owned()));
        }
        media::prepare_embedded_thumbnail(
            Path::new(&photo.path),
            photo.size_bytes,
            photo.modified_ns,
            &path,
        )
        .map(|present| present.then(|| path.to_string_lossy().into_owned()))
    }
}
impl Drop for ThumbnailLoader {
    fn drop(&mut self) {
        self.close();
    }
}
fn is_thumbnail_file(path: &Path) -> bool {
    path.file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|name| name.starts_with("thumbnail-") || name == "embedded.jpg")
}
fn cache_path(store: &LocalLibrary, key: &Key) -> PathBuf {
    store
        .root
        .join("cache")
        .join(&key.id)
        .join(key.version.to_string())
        .join(format!("r{}", media::THUMBNAIL_CACHE_REVISION))
        .join(format!("thumbnail-{}.jpg", key.size))
}
/// Cache-only cloud uplink: a missing thumbnail is deferred work. This lookup
/// never opens, hashes, decodes, or schedules the original source.
pub(crate) fn cached_upload_source(store: &LocalLibrary, photo: &LocalPhoto) -> Option<PathBuf> {
    [1024, 512, 256]
        .into_iter()
        .map(|size| (size, cache_path(store, &Key::new(photo, size))))
        .find(|(size, path)| valid_cache(path, *size))
        .map(|(_, path)| path)
}

fn cached_cloud_thumbnail(inner: &Inner, photo: &LocalPhoto) -> Option<String> {
    if inner
        .state
        .lock()
        .unwrap()
        .bad_cloud
        .contains(&(photo.id.clone(), photo.content_version))
    {
        return None;
    }
    inner
        .store
        .cloud_thumbnail_for_media(photo.id.clone())
        .ok()
        .flatten()
        .map(|(path, _)| path)
        .filter(|path| valid_cache(Path::new(path), 2048))
}
fn valid_cache(path: &Path, size: u32) -> bool {
    media::thumbnail_dimensions(path).is_some_and(|(w, h)| w > 0 && h > 0 && w.max(h) <= size)
}
fn remember(inner: &Inner, key: Key, path: String) {
    let mut s = inner.state.lock().unwrap();
    s.sequence += 1;
    let seq = s.sequence;
    s.cache.insert(key, (path, seq));
    if s.cache.len() > 512 {
        if let Some(key) = s
            .cache
            .iter()
            .min_by_key(|(_, (_, seq))| *seq)
            .map(|(k, _)| k.clone())
        {
            s.cache.remove(&key);
        }
    }
}
fn take_job(s: &mut State) -> Option<Key> {
    while let Some(Reverse((tier, seq, key))) = s.queue.pop() {
        if let Some(job) = s.jobs.get_mut(&key)
            && !job.started
            && job.tier == tier
            && job.seq == seq
        {
            job.started = true;
            return Some(key);
        }
    }
    None
}
fn worker_loop(inner: Arc<Inner>) {
    loop {
        let mut s = inner.state.lock().unwrap();
        let work = take_job(&mut s);

        if s.closed {
            return;
        }
        if let Some(key) = work {
            drop(s);
            run_job(&inner, key);
            continue;
        }
        if s.prewarm
            && !s.paused
            && !s.background_busy
            && !s.completion_reported
            && s.next_background.is_none_or(|t| Instant::now() >= t)
        {
            s.background_busy = true;
            drop(s);
            let worked = prewarm_step(&inner);
            let mut s = inner.state.lock().unwrap();
            s.background_busy = false;
            s.next_background = Some(
                Instant::now()
                    + if worked {
                        Duration::from_millis(100)
                    } else {
                        Duration::from_millis(500)
                    },
            );
            inner.wake.notify_all();
            drop(s);
            continue;
        }
        let wait = if s.prewarm && !s.paused && !s.completion_reported && !s.background_busy {
            s.next_background
                .map(|t| t.saturating_duration_since(Instant::now()))
                .unwrap_or(Duration::from_millis(100))
                .max(Duration::from_millis(1))
        } else {
            Duration::from_secs(30)
        };
        let _ = inner.wake.wait_timeout(s, wait).unwrap();
    }
}
fn run_job(inner: &Inner, key: Key) {
    let _publication = inner.publication.read().unwrap();
    let (photo, background, wait, tier) = {
        let s = inner.state.lock().unwrap();
        let Some(j) = s.jobs.get(&key) else {
            return;
        };
        (
            j.photo.clone(),
            j.background,
            j.queued.elapsed().as_millis() as u64,
            j.tier,
        )
    };
    let started = Instant::now();
    let path = cache_path(&inner.store, &key);
    let mut did_generate = false;
    let result = (|| {
        if !valid_cache(&path, key.size) {
            let cloud = cached_cloud_thumbnail(inner, &photo);
            if let Some(path) = cloud
                .as_ref()
                .filter(|p| valid_cache(Path::new(p), key.size))
            {
                if inner.store.photo(photo.id.clone())?.content_version != key.version {
                    return Err("SourceChanged".into());
                }
                return Ok(path.clone());
            }
            did_generate = true;
            let _ = std::fs::remove_file(&path);
            std::fs::create_dir_all(path.parent().unwrap()).map_err(|_| "CacheUnavailable")?;
            // A larger, already-oriented cache entry is sufficient for a smaller
            // class. Never decode the original again merely to shrink the cache.
            let larger = [512, 1024]
                .into_iter()
                .filter(|size| *size > key.size)
                .map(|size| {
                    cache_path(
                        &inner.store,
                        &Key {
                            size,
                            ..key.clone()
                        },
                    )
                })
                .find(|p| valid_cache(p, 1024))
                .or_else(|| cloud.map(PathBuf::from));
            let generated = if let Some(source) = larger {
                std::fs::metadata(&source)
                    .map_err(|_| "CacheUnavailable".to_string())
                    .and_then(|metadata| {
                        let ns = metadata
                            .modified()
                            .map_err(|_| "CacheUnavailable")?
                            .duration_since(std::time::UNIX_EPOCH)
                            .map_err(|_| "CacheUnavailable")?
                            .as_nanos() as i64;
                        media::prepare_thumbnail(&source, metadata.len(), ns, key.size, &path)
                    })
            } else {
                media::prepare_preview(
                    Path::new(&photo.path),
                    photo.size_bytes,
                    photo.modified_ns,
                    key.size,
                    &path,
                )
            };
            if let Err(error) = generated {
                if let Some(cloud) = cached_cloud_thumbnail(inner, &photo) {
                    return Ok(cloud);
                }
                return Err(error);
            }
        }
        let current = inner.store.photo(photo.id.clone())?;
        if current.content_version != key.version {
            return Err("SourceChanged".into());
        }
        Ok(path.to_string_lossy().into_owned())
    })();
    let elapsed = started.elapsed().as_millis() as u64;
    // Publish durable state before notifying observers. Cache-hit requests do no
    // bookkeeping writes; the bounded reconciliation walk repairs those marks.
    let _ = inner.store.record_thumbnail_states(vec![(
        photo,
        key.size,
        result.as_ref().cloned().unwrap_or_default(),
        if result.is_ok() { "ready" } else { "failed" }.into(),
    )]);
    if let Ok(path) = &result
        && !background
    {
        remember(inner, key.clone(), path.clone());
    }
    let waiters = {
        let mut s = inner.state.lock().unwrap();
        s.metrics.max_queue_wait_ms = s.metrics.max_queue_wait_ms.max(wait);
        s.metrics.generation_ms += elapsed;
        s.metrics.processed += 1;
        if result.is_ok() {
            if did_generate {
                s.metrics.generated += 1;
            } else {
                s.metrics.disk_hits += 1;
            }
            s.failures.remove(&key);
        } else {
            s.metrics.failed += 1;
            if s.failures.len() >= 512 {
                s.failures.clear();
            }
            s.failures
                .insert(key.clone(), result.as_ref().unwrap_err().clone());
        }
        s.jobs.remove(&key).map(|j| j.waiters).unwrap_or_default()
    };
    for (_, tx) in waiters {
        let _ = tx.send(result.clone());
    }
    let batch = {
        let mut s = inner.state.lock().unwrap();
        let done = s.metrics.processed;
        if done > 0 && done % 32 == 0 {
            s.maintenance = done % 64 == 0;
            Some((done, s.metrics.clone(), s.jobs.len()))
        } else {
            None
        }
    };
    if let Some((done, m, pending)) = batch {
        eprintln!(
            "thumbnail_batch processed={done} generated={} failed={} pending={pending} disk_hits={} memory_hits={} merged={} cancelled={} generation_ms={} max_queue_wait_ms={} status={}",
            m.generated,
            m.failed,
            m.disk_hits,
            m.memory_hits,
            m.merged,
            m.cancelled,
            m.generation_ms,
            m.max_queue_wait_ms,
            "partial"
        );
    }
    // No private source paths are logged. Slow foreground work remains visible.
    if elapsed >= 250 {
        eprintln!(
            "thumbnail_complete tier={tier} size={} elapsed_ms={elapsed} queue_wait_ms={wait} result={}",
            key.size,
            if result.is_ok() { "complete" } else { "failed" }
        );
    }
}
fn prewarm_step(inner: &Inner) -> bool {
    let (size, reconcile, anchor) = {
        let mut s = inner.state.lock().unwrap();
        if s.maintenance {
            s.maintenance = false;
            drop(s);
            maintain_cache(inner, 2 * 1024 * 1024 * 1024);
            return true;
        }
        if s.budget_limited && s.reconcile.is_none() {
            s.completion_reported = true;
            return false;
        }
        (s.size, s.reconcile, s.anchor.clone())
    };
    if let Some(offset) = reconcile {
        if let Ok(page) = inner.store.thumbnail_reconcile_window(offset) {
            let len = page.len();
            let rows = page
                .into_iter()
                .map(|p| {
                    let path = cache_path(&inner.store, &Key::new(&p, size));
                    let status = if valid_cache(&path, size) {
                        "ready"
                    } else {
                        "pending"
                    };
                    (p, size, path.to_string_lossy().into_owned(), status.into())
                })
                .collect();
            let _ = inner.store.record_thumbnail_states(rows);
            let mut s = inner.state.lock().unwrap();
            if s.size == size && s.reconcile == Some(offset) {
                s.reconcile = if len == 100 { Some(offset + 100) } else { None };
            }
            return true;
        }
        return false;
    }
    inner.state.lock().unwrap().metrics.background_queries += 1;
    let photo = match inner.store.next_thumbnail_candidate(size, anchor) {
        Ok(Some(photo)) => photo,
        Ok(None) => {
            let report = {
                let mut s = inner.state.lock().unwrap();
                if s.completion_reported {
                    false
                } else {
                    s.completion_reported = true;
                    true
                }
            };
            if report {
                if let Ok((total, ready, failed)) = inner.store.thumbnail_counts(size) {
                    eprintln!(
                        "thumbnail_prewarm size={size} total={total} ready={ready} failed={failed} status={}",
                        if failed == 0 && ready == total {
                            "complete"
                        } else {
                            "partial"
                        }
                    );
                }
            }
            return false;
        }
        Err(_) => return false,
    };
    let key = Key::new(&photo, size);
    let path = cache_path(&inner.store, &key);
    if valid_cache(&path, size) {
        let _ = inner.store.record_thumbnail_states(vec![(
            photo,
            size,
            path.to_string_lossy().into_owned(),
            "ready".into(),
        )]);
        return true;
    }
    {
        let mut s = inner.state.lock().unwrap();
        if s.closed || s.paused || s.jobs.contains_key(&key) || !s.queue.is_empty() {
            return false;
        }
        s.sequence += 1;
        let seq = s.sequence;
        s.jobs.insert(
            key.clone(),
            Job {
                photo,
                tier: 2,
                seq,
                started: true,
                background: true,
                queued: Instant::now(),
                waiters: HashMap::new(),
            },
        );
    }
    run_job(inner, key);
    true
}

/// Disk capacity maintenance is idle work. Symlinks are never followed and
/// membership includes trash/missing/cloud media, preserving their thumbnails.
fn maintain_cache(inner: &Inner, limit: u64) {
    let Ok(members) = inner.store.thumbnail_cache_membership() else {
        return;
    };
    let root = inner.store.root.join("cache");
    if !std::fs::symlink_metadata(&root).is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink()) {
        return;
    }
    let mut files = Vec::new();
    let mut bytes = 0_u64;
    let began = std::time::SystemTime::now();
    if let Ok(dirs) = std::fs::read_dir(&root) {
        for entry in dirs.flatten() {
            if entry.file_type().is_ok_and(|t| t.is_dir())
                && !members.contains(&entry.file_name().to_string_lossy().into_owned())
                && entry
                    .metadata()
                    .and_then(|m| m.modified())
                    .is_ok_and(|t| t < began)
            {
                let _publication = inner.publication.write().unwrap();
                let _ = std::fs::remove_dir_all(entry.path());
            }
        }
    }
    for entry in walkdir::WalkDir::new(&root)
        .follow_links(false)
        .follow_root_links(false)
        .into_iter()
        .flatten()
    {
        let name = entry.file_name().to_string_lossy();
        if entry.file_type().is_file() && (name.starts_with("thumbnail-") || name == "embedded.jpg")
        {
            if let Ok(meta) = entry.metadata() {
                bytes = bytes.saturating_add(meta.len());
                files.push((
                    meta.modified().unwrap_or(std::time::UNIX_EPOCH),
                    entry.path().to_path_buf(),
                    meta.len(),
                ));
            }
        }
    }
    if bytes <= limit {
        return;
    }
    files.sort_by_key(|(modified, _, _)| *modified);
    let mut removed = 0;
    let _publication = inner.publication.write().unwrap();
    for (_, path, size) in files {
        if bytes <= limit {
            break;
        }
        if std::fs::remove_file(path).is_ok() {
            bytes = bytes.saturating_sub(size);
            removed += 1;
        }
    }
    if removed > 0 {
        let mut s = inner.state.lock().unwrap();
        s.cache.clear();
        s.cache_epoch += 1;
        s.reconcile = Some(0);
        s.budget_limited = true;
        eprintln!(
            "thumbnail_cache_maintenance removed={removed} bytes={bytes} limit_bytes={limit} status=complete"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local_library::{MediaInput, PhotoFilter};
    use std::sync::atomic::AtomicBool;
    use tempfile::TempDir;

    fn fixture() -> (TempDir, TempDir, LocalLibrary, Vec<LocalPhoto>) {
        let root = TempDir::new().unwrap();
        let sources = TempDir::new().unwrap();
        for i in 0..3 {
            image::RgbImage::from_pixel(64, 40, image::Rgb([i * 30, 100, 200]))
                .save(sources.path().join(format!("{i}.jpg")))
                .unwrap();
        }
        let store = LocalLibrary::open(root.path()).unwrap();
        let source = store.add_source(sources.path()).unwrap();
        media::scan_paths(&[sources.path().into()], &AtomicBool::new(false), |batch| {
            store
                .upsert_batch(
                    source.clone(),
                    batch
                        .into_iter()
                        .map(|m| MediaInput {
                            path: m.path.to_string_lossy().into(),
                            name: m.display_name,
                            parent: m.parent_path.to_string_lossy().into(),
                            size_bytes: m.size_bytes,
                            modified_ns: m.modified_ns,
                            mime_type: m.mime_type,
                            width: m.width,
                            height: m.height,
                            orientation: m.orientation,
                            capture_time_ms: m.capture_time_ms,
                        })
                        .collect(),
                )
                .map(|_| ())
        })
        .unwrap();
        let photos = store
            .query_window(PhotoFilter::default(), 0, 10)
            .unwrap()
            .items;
        (root, sources, store, photos)
    }
    fn paused(store: LocalLibrary) -> ThumbnailLoader {
        ThumbnailLoader {
            inner: Arc::new(Inner {
                store,
                state: Mutex::new(State {
                    size: 256,
                    ..State::default()
                }),
                wake: Condvar::new(),
                publication: RwLock::new(()),
            }),
            threads: Mutex::new(Vec::new()),
        }
    }
    fn request(
        loader: &ThumbnailLoader,
        p: &LocalPhoto,
        token: &str,
        tier: u8,
    ) -> oneshot::Receiver<Reply> {
        loader
            .request(
                p.id.clone(),
                Some(p.content_version),
                256,
                token.into(),
                tier,
            )
            .unwrap()
    }
    fn finish_next(loader: &ThumbnailLoader) -> Key {
        let key = take_job(&mut loader.inner.state.lock().unwrap()).unwrap();
        run_job(&loader.inner, key.clone());
        key
    }
    fn wait_until(mut predicate: impl FnMut() -> bool) {
        let until = Instant::now() + Duration::from_secs(5);
        while !predicate() {
            assert!(Instant::now() < until, "thumbnail work did not converge");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn visible_priority_promotes_shared_work_and_only_decodes_once() {
        let (_r, _s, store, p) = fixture();
        let loader = paused(store);
        let normal = request(&loader, &p[0], "normal", 1);
        let other = request(&loader, &p[1], "other", 1);
        let boosted = request(&loader, &p[0], "boost", 0);
        assert_eq!(loader.inner.state.lock().unwrap().jobs.len(), 2);
        assert_eq!(finish_next(&loader).id, p[0].id);
        assert_eq!(
            normal.blocking_recv().unwrap(),
            boosted.blocking_recv().unwrap()
        );
        assert_eq!(finish_next(&loader).id, p[1].id);
        assert!(other.blocking_recv().unwrap().is_ok());
        let s = loader.inner.state.lock().unwrap();
        assert_eq!(s.metrics.generated, 2);
        assert_eq!(s.metrics.merged, 1);
        assert!(s.jobs.is_empty());
    }
    #[test]
    fn cancellation_removes_orphaned_jobs_but_keeps_shared_observers() {
        let (_r, _s, store, p) = fixture();
        let loader = paused(store);
        let a = request(&loader, &p[0], "a", 0);
        let b = request(&loader, &p[0], "b", 0);
        loader.cancel("a");
        assert!(a.blocking_recv().is_err());
        assert_eq!(loader.inner.state.lock().unwrap().jobs.len(), 1);
        loader.cancel("b");
        assert!(b.blocking_recv().is_err());
        assert!(take_job(&mut loader.inner.state.lock().unwrap()).is_none());
        loader.cancel("early");
        assert!(
            loader
                .request(p[0].id.clone(), Some(1), 256, "early".into(), 0)
                .is_err()
        );
    }
    #[test]
    fn cache_only_lookahead_never_creates_or_queues_missing_thumbnails() {
        let (_r, _s, store, p) = fixture();
        let loader = paused(store.clone());
        assert!(
            loader
                .cached_path(p[0].id.clone(), p[0].content_version, 256)
                .unwrap()
                .is_none()
        );
        assert!(loader.inner.state.lock().unwrap().jobs.is_empty());
        assert!(!store.root.join("cache").exists());
        let rx = request(&loader, &p[0], "visible", 0);
        finish_next(&loader);
        let expected = rx.blocking_recv().unwrap().unwrap();
        assert_eq!(
            loader
                .cached_path(p[0].id.clone(), p[0].content_version, 256)
                .unwrap()
                .unwrap(),
            expected
        );
    }
    #[test]
    fn cached_paths_bypass_a_busy_generation_queue_and_do_no_bookkeeping_write() {
        let (_r, _s, store, p) = fixture();
        let loader = paused(store.clone());
        let first = request(&loader, &p[0], "first", 0);
        finish_next(&loader);
        assert!(first.blocking_recv().unwrap().is_ok());
        let busy = request(&loader, &p[1], "slow", 0);
        let mut cached = request(&loader, &p[0], "hot", 0);
        assert!(cached.try_recv().unwrap().is_ok());
        assert_eq!(loader.inner.state.lock().unwrap().jobs.len(), 1);
        assert_eq!(store.thumbnail_counts(256).unwrap(), (3, 1, 0));
        loader.cancel("slow");
        drop(busy);
    }
    #[test]
    fn prewarm_converges_tracks_actual_files_and_repairs_missing_cache() {
        let (_r, _s, store, _p) = fixture();
        let loader = ThumbnailLoader::new(store.clone(), 2);
        loader.viewport(None, 256);
        loader.resume_prewarm();
        wait_until(|| loader.progress().unwrap().ready == 3);
        loader.pause_prewarm();
        let photo = store
            .query_window(PhotoFilter::default(), 0, 1)
            .unwrap()
            .items
            .remove(0);
        let path = cache_path(&store, &Key::new(&photo, 256));
        std::fs::remove_file(&path).unwrap();
        loader.resume_prewarm();
        wait_until(|| path.is_file() && loader.progress().unwrap().ready == 3);
        assert!(
            loader.inner.state.lock().unwrap().cache.is_empty(),
            "prewarm must not evict foreground history"
        );
        loader.close();
    }
    #[test]
    fn completed_prewarm_sleeps_until_a_library_change() {
        let (_r, _s, store, _p) = fixture();
        let loader = ThumbnailLoader::new(store, 2);
        loader.viewport(None, 256);
        loader.resume_prewarm();
        wait_until(|| loader.inner.state.lock().unwrap().completion_reported);
        let queries = loader.progress().unwrap().metrics.background_queries;
        thread::sleep(Duration::from_millis(600));
        assert_eq!(
            loader.progress().unwrap().metrics.background_queries,
            queries
        );
        loader.wake_after_library_change();
        wait_until(|| loader.progress().unwrap().metrics.background_queries > queries);
        loader.close();
    }
    #[test]
    fn clearing_thumbnail_cache_preserves_previews_and_animation_files() {
        let (_r, _s, store, p) = fixture();
        let loader = paused(store.clone());
        let rx = request(&loader, &p[0], "first", 0);
        finish_next(&loader);
        assert!(rx.blocking_recv().unwrap().is_ok());
        let preview = store.root.join("cache/preview.jpg");
        let animation = store.root.join("cache/frame-0001.png");
        std::fs::write(&preview, b"preview").unwrap();
        std::fs::write(&animation, b"frame").unwrap();
        assert!(loader.cache_usage() > 0);
        loader.clear_disk().unwrap();
        assert_eq!(loader.cache_usage(), 0);
        assert!(preview.is_file());
        assert!(animation.is_file());
    }
    #[test]
    fn clearing_the_cache_removes_the_rows_and_the_files_together() {
        let (_r, _s, store, p) = fixture();
        let loader = paused(store.clone());
        // A rendered thumbnail: the file on the disk and the row in the
        // database say the same thing.
        let key = Key::new(&p[0], 256);
        let path = cache_path(&store, &key);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        image::RgbImage::from_pixel(48, 32, image::Rgb([240, 10, 20]))
            .save(&path)
            .unwrap();
        store
            .record_thumbnail_states(vec![(
                p[0].clone(),
                256,
                path.to_string_lossy().into_owned(),
                "ready".into(),
            )])
            .unwrap();
        // The row keeps the photo out of the candidate list.
        assert_ne!(
            store
                .next_thumbnail_candidate(256, None)
                .unwrap()
                .unwrap()
                .id,
            p[0].id
        );

        loader.clear_disk().unwrap();

        // The file and the row are both gone, so the photo is a candidate
        // again instead of waiting for a content change that never comes.
        assert!(!path.is_file(), "the thumbnail file survived the clear");
        assert_eq!(
            store
                .next_thumbnail_candidate(256, None)
                .unwrap()
                .unwrap()
                .id,
            p[0].id
        );
    }
    #[test]
    fn viewport_anchor_uses_live_media_order_even_when_earlier_rows_are_ready() {
        let (_r, _s, store, p) = fixture();
        store
            .record_thumbnail_states(vec![(p[0].clone(), 256, "cache".into(), "ready".into())])
            .unwrap();
        assert_eq!(
            store
                .next_thumbnail_candidate(256, Some(p[1].id.clone()))
                .unwrap()
                .unwrap()
                .id,
            p[1].id
        );
        store
            .record_thumbnail_states(vec![(p[1].clone(), 256, "cache".into(), "ready".into())])
            .unwrap();
        assert_eq!(
            store
                .next_thumbnail_candidate(256, Some(p[1].id.clone()))
                .unwrap()
                .unwrap()
                .id,
            p[2].id
        );
    }
    #[test]
    fn bad_cache_is_rebuilt_and_larger_cache_can_supply_smaller_class() {
        let (_r, _s, store, p) = fixture();
        let loader = paused(store.clone());
        let key = Key::new(&p[0], 512);
        let path = cache_path(&store, &key);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        image::RgbImage::from_pixel(48, 32, image::Rgb([240, 10, 20]))
            .save(&path)
            .unwrap();
        // If the larger cache is ignored, the unavailable source makes this fail.
        std::fs::remove_file(&p[0].path).unwrap();
        let rx = request(&loader, &p[0], "small", 0);
        finish_next(&loader);
        assert!(rx.blocking_recv().unwrap().is_ok());
        let broken = cache_path(&store, &Key::new(&p[1], 256));
        std::fs::create_dir_all(broken.parent().unwrap()).unwrap();
        std::fs::write(&broken, b"broken").unwrap();
        let rx = request(&loader, &p[1], "repair", 0);
        finish_next(&loader);
        assert!(rx.blocking_recv().unwrap().is_ok());
        assert!(valid_cache(&broken, 256));
    }
    #[test]
    fn failures_converge_and_retry_invalidates_the_failed_marker() {
        let (_r, _s, store, p) = fixture();
        std::fs::write(&p[0].path, b"corrupt").unwrap();
        let loader = ThumbnailLoader::new(store.clone(), 2);
        loader.viewport(None, 256);
        loader.resume_prewarm();
        wait_until(|| {
            let s = loader.progress().unwrap();
            s.ready == 2 && s.failed == 1
        });
        let before = loader.progress().unwrap().metrics.failed;
        thread::sleep(Duration::from_millis(600));
        assert_eq!(loader.progress().unwrap().metrics.failed, before);
        loader.pause_prewarm();
        loader
            .invalidate(&p[0].id, p[0].content_version, 256)
            .unwrap();
        assert_eq!(store.thumbnail_counts(256).unwrap(), (3, 2, 0));
        loader.close();
    }
    #[test]
    fn idle_cache_capacity_evicts_files_without_a_regeneration_loop() {
        let (_r, _s, store, p) = fixture();
        let loader = paused(store.clone());
        for (index, photo) in p.iter().enumerate() {
            let rx = request(&loader, photo, &format!("{index}"), 0);
            finish_next(&loader);
            assert!(rx.blocking_recv().unwrap().is_ok());
        }
        let orphan = store.root.join("cache/orphan/1/r4");
        std::fs::create_dir_all(&orphan).unwrap();
        std::fs::write(orphan.join("thumbnail-256.jpg"), b"orphan").unwrap();
        maintain_cache(&loader.inner, 0);
        assert!(!store.root.join("cache/orphan").exists());
        assert!(loader.progress().unwrap().cache_limit_reached);
        assert!(prewarm_step(&loader.inner));
        assert_eq!(loader.progress().unwrap().ready, 0);
        assert!(!prewarm_step(&loader.inner));
        assert_eq!(loader.progress().unwrap().metrics.generated, 3);
    }

    #[test]
    fn clear_cache_and_shutdown_resolve_waiters_and_remove_hot_paths() {
        let (_r, _s, store, p) = fixture();
        let loader = paused(store);
        let a = request(&loader, &p[0], "a", 0);
        finish_next(&loader);
        assert!(a.blocking_recv().unwrap().is_ok());
        loader.clear_disk().unwrap();
        assert!(loader.inner.state.lock().unwrap().cache.is_empty());
        let pending = request(&loader, &p[0], "pending", 0);
        loader.close();
        assert_eq!(
            pending.blocking_recv().unwrap(),
            Err("LibraryClosed".into())
        );
    }
}
