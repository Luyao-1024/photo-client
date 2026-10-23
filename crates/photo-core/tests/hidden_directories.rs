//! Run these focused filesystem cases in an isolated test environment.
use image::{Rgb, RgbImage};
use photo_core::{
    local_library::{LocalLibrary, MediaInput, PhotoFilter},
    media::{
        scan_paths, scan_paths_excluding,
        visibility::{hidden_directory_within, relevant_change},
    },
};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
};
use tempfile::TempDir;

fn photo(path: &Path) -> MediaInput {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    RgbImage::from_pixel(4, 4, Rgb([100, 150, 200]))
        .save(path)
        .unwrap();
    MediaInput {
        path: path.to_str().unwrap().into(),
        name: path.file_name().unwrap().to_str().unwrap().into(),
        parent: path.parent().unwrap().to_str().unwrap().into(),
        size_bytes: fs::metadata(path).unwrap().len(),
        modified_ns: 1,
        mime_type: "image/png".into(),
        width: Some(4),
        height: Some(4),
        orientation: 1,
        capture_time_ms: None,
    }
}

#[test]
fn discovery_prunes_hidden_subtrees_before_reading_media() {
    let root = TempDir::new().unwrap();
    photo(&root.path().join("visible.png"));
    photo(&root.path().join("normal/.dot-file.png"));
    photo(&root.path().join(".hidden/nested/hidden.png"));
    photo(&root.path().join("normal/.nested/hidden.png"));
    fs::write(root.path().join(".hidden/invalid.png"), b"invalid image").unwrap();
    let mut names = Vec::new();
    let summary = scan_paths(&[root.path().into()], &AtomicBool::new(false), |batch| {
        names.extend(batch.into_iter().map(|p| p.display_name));
        Ok(())
    })
    .unwrap();
    names.sort();
    assert_eq!(names, [".dot-file.png", "visible.png"]);
    assert_eq!(summary.discovered, 2);
    assert_eq!(summary.failed, 0);
    assert!(hidden_directory_within(
        root.path(),
        &root.path().join("normal/.nested")
    ));
    assert!(!hidden_directory_within(root.path(), root.path()));
}

#[test]
fn catalog_admission_rejects_hidden_contents_without_touching_files() {
    let root = TempDir::new().unwrap();
    let source = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let id = library.add_source(source.path()).unwrap();
    let hidden = photo(&source.path().join(".hidden/hidden.png"));
    let visible = photo(&source.path().join("visible.png"));
    assert_eq!(
        library
            .upsert_batch(id, vec![hidden.clone(), visible])
            .unwrap(),
        1
    );
    let page = library.query(PhotoFilter::default(), None, 10).unwrap();
    assert_eq!(page.total, 1);
    assert_eq!(page.items[0].name, "visible.png");
    assert!(Path::new(&hidden.path).is_file());
    let db = rusqlite::Connection::open(root.path().join("library.sqlite")).unwrap();
    let rows: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM media WHERE source_uri=?1",
            [&hidden.path],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(rows, 0);
}

#[test]
fn reopening_hides_legacy_rows_and_preserves_identity_favorite_and_original() {
    let root = TempDir::new().unwrap();
    let source = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let source_id = library.add_source(source.path()).unwrap();
    let visible = photo(&source.path().join("legacy.png"));
    library
        .upsert_batch(source_id, vec![visible.clone()])
        .unwrap();
    let id = library
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items[0]
        .id
        .clone();
    library.set_favorite(id.clone(), true).unwrap();
    drop(library);
    let hidden = source.path().join(".hidden/legacy.png");
    fs::create_dir_all(hidden.parent().unwrap()).unwrap();
    fs::rename(&visible.path, &hidden).unwrap();
    let db = rusqlite::Connection::open(root.path().join("library.sqlite")).unwrap();
    db.execute(
        "UPDATE media SET source_uri=?1,parent_uri=?2 WHERE media_id=?3",
        rusqlite::params![
            hidden.to_str().unwrap(),
            hidden.parent().unwrap().to_str().unwrap(),
            id
        ],
    )
    .unwrap();
    drop(db);
    let library = LocalLibrary::open(root.path()).unwrap();
    assert_eq!(library.info().unwrap().count, 0);
    assert!(library.list_albums().unwrap().is_empty());
    assert_eq!(
        library
            .query(
                PhotoFilter {
                    favorites_only: true,
                    ..Default::default()
                },
                None,
                10
            )
            .unwrap()
            .total,
        0
    );
    let db = rusqlite::Connection::open(root.path().join("library.sqlite")).unwrap();
    let row: (String, bool, String) = db
        .query_row(
            "SELECT state,favorite,error_code FROM media WHERE media_id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(row, ("missing".into(), true, "HiddenDirectory".into()));
    assert!(hidden.is_file());
}

#[test]
fn hidden_changes_are_ignored_but_visible_rename_endpoints_are_admitted() {
    let sources = [PathBuf::from("/photos")];
    let accepts =
        |path: &str| relevant_change(Path::new(path), false, &sources, &[], Path::new("/catalog"));
    for path in [
        "/photos/.hidden",
        "/photos/.hidden/a.png",
        "/photos/a/.nested/deleted.png",
    ] {
        assert!(!accepts(path), "{path}");
    }
    assert!(accepts("/photos/visible.png"));
    assert!(
        ["/photos/.hidden/a.png", "/photos/visible.png"]
            .into_iter()
            .any(accepts)
    );
    assert!(
        ["/photos/visible.png", "/photos/.hidden/a.png"]
            .into_iter()
            .any(accepts)
    );
    assert!(
        !["/photos/.hidden/a.png", "/photos/.other/a.png"]
            .into_iter()
            .any(accepts)
    );
}

#[test]
fn linux_real_trash_roots_remain_observable_without_whitelisting_other_hidden_dirs() {
    let sources = [PathBuf::from("/media/photos")];
    let trash: Vec<PathBuf> = [
        "/home/person/.local/share/Trash",
        "/media/.Trash-1000",
        "/media/.Trash/1000",
    ]
    .into_iter()
    .map(Into::into)
    .collect();
    for root in &trash {
        assert!(relevant_change(
            &root.join("files/a.png"),
            true,
            &sources,
            &trash,
            Path::new("/catalog")
        ));
        assert!(relevant_change(
            &root.join("info/a.trashinfo"),
            true,
            &sources,
            &trash,
            Path::new("/catalog")
        ));
        assert!(relevant_change(
            root.parent().unwrap(),
            false,
            &sources,
            &trash,
            Path::new("/catalog")
        ));
    }
    assert!(!relevant_change(
        Path::new("/media/photos/.Trash-not-real/a.png"),
        true,
        &sources,
        &trash,
        Path::new("/catalog")
    ));
    assert!(!relevant_change(
        Path::new("/media/.Trash-1001/files/a.png"),
        true,
        &sources,
        &trash,
        Path::new("/catalog")
    ));
}

#[test]
fn android_library_trash_is_an_exception_to_catalog_write_exclusion() {
    let root = Path::new("/data/app/library");
    let trash = [root.join("Trash")];
    let sources = [PathBuf::from("/sdcard/Pictures")];
    for path in ["Trash/files/photo.png", "Trash/info/photo.trashinfo"] {
        assert!(relevant_change(
            &root.join(path),
            true,
            &sources,
            &trash,
            root
        ));
    }
    assert!(!relevant_change(
        &root.join("library.sqlite-wal"),
        true,
        &sources,
        &trash,
        root
    ));
    assert!(!relevant_change(
        Path::new("/sdcard/Pictures/.thumbnails/a.png"),
        true,
        &sources,
        &trash,
        root
    ));
}

#[test]
fn trash_is_excluded_from_normal_discovery_even_with_a_visible_root_name() {
    let root = TempDir::new().unwrap();
    photo(&root.path().join("visible.png"));
    let trash = root.path().join("Trash");
    photo(&trash.join("files/trashed.png"));
    let mut count = 0;
    let summary = scan_paths_excluding(
        &[root.path().into(), trash.clone()],
        &[trash],
        &AtomicBool::new(false),
        |batch| {
            count += batch.len();
            Ok(())
        },
    )
    .unwrap();
    assert_eq!(summary.discovered, 1);
    assert_eq!(count, 1);
}

#[test]
fn native_watcher_does_not_admit_hidden_changes() {
    use notify::{RecursiveMode, Watcher};
    use std::{
        sync::mpsc,
        time::{Duration, Instant},
    };
    let root = TempDir::new().unwrap();
    let hidden = root.path().join(".hidden");
    fs::create_dir(&hidden).unwrap();
    let sources = vec![root.path().to_owned()];
    let (send, receive) = mpsc::channel();
    let mut watcher =
        notify::recommended_watcher(move |event: Result<notify::Event, notify::Error>| {
            let event = event.unwrap();
            if event.kind.is_access() {
                return;
            }
            for path in event.paths {
                if relevant_change(
                    &path,
                    path.is_file(),
                    &sources,
                    &[],
                    Path::new("/unused-catalog"),
                ) {
                    send.send(path).unwrap();
                }
            }
        })
        .unwrap();
    watcher
        .watch(root.path(), RecursiveMode::Recursive)
        .unwrap();
    fs::write(hidden.join("ignored.png"), b"hidden").unwrap();
    let visible = root.path().join("visible.png");
    fs::write(&visible, b"visible").unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut admitted_visible = false;
    while let Ok(path) = receive.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        assert!(!path.starts_with(&hidden));
        admitted_visible |= path == visible;
        if admitted_visible {
            break;
        }
    }
    assert!(
        admitted_visible,
        "the native watcher must still admit ordinary files"
    );
}

#[cfg(target_os = "android")]
#[test]
fn android_native_trash_watch_tracks_external_restore_and_empty() {
    use notify::{RecursiveMode, Watcher};
    use std::{
        sync::mpsc,
        time::{Duration, Instant},
    };
    let root = TempDir::new().unwrap();
    let source = TempDir::new().unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let source_id = library.add_source(source.path()).unwrap();
    let original = source.path().join("photo.png");
    library
        .upsert_batch(source_id, vec![photo(&original)])
        .unwrap();
    let id = library
        .query(PhotoFilter::default(), None, 10)
        .unwrap()
        .items[0]
        .id
        .clone();
    let trash = library.trash_roots().unwrap();
    assert_eq!(trash, [root.path().join("Trash")]);
    for child in ["files", "info"] {
        fs::create_dir_all(trash[0].join(child)).unwrap();
    }
    let observed_trash = trash.clone();
    let data_root = root.path().to_owned();
    let (send, receive) = mpsc::channel();
    let mut watcher =
        notify::recommended_watcher(move |event: Result<notify::Event, notify::Error>| {
            let event = event.unwrap();
            if event.kind.is_access() {
                return;
            }
            for path in event.paths {
                if relevant_change(&path, path.is_file(), &[], &observed_trash, &data_root) {
                    send.send(path).unwrap();
                }
            }
        })
        .unwrap();
    watcher.watch(&trash[0], RecursiveMode::Recursive).unwrap();
    let wait_for = |expected: &Path| {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let path = receive
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .unwrap();
            if path == expected {
                break;
            }
        }
    };
    library.trash_media(vec![id.clone()]).unwrap();
    let page = library
        .query(
            PhotoFilter {
                trashed: true,
                ..Default::default()
            },
            None,
            10,
        )
        .unwrap();
    assert_eq!(page.total, 1);
    let payload = PathBuf::from(&page.items[0].path);
    wait_for(&payload);
    for _ in receive.try_iter() {}
    fs::rename(&payload, &original).unwrap();
    wait_for(&payload);
    library.reconcile_trash().unwrap();
    assert_eq!(library.info().unwrap().count, 1);
    assert!(original.is_file());
    library.trash_media(vec![id]).unwrap();
    let page = library
        .query(
            PhotoFilter {
                trashed: true,
                ..Default::default()
            },
            None,
            10,
        )
        .unwrap();
    let payload = PathBuf::from(&page.items[0].path);
    wait_for(&payload);
    for _ in receive.try_iter() {}
    fs::remove_file(&payload).unwrap();
    wait_for(&payload);
    library.reconcile_trash().unwrap();
    assert_eq!(
        library
            .query(
                PhotoFilter {
                    trashed: true,
                    ..Default::default()
                },
                None,
                10
            )
            .unwrap()
            .total,
        0
    );
    assert!(!original.exists());
}
