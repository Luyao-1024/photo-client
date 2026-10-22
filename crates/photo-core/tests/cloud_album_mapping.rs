//! The album of a photo survives the round trip through the cloud.
//!
//! A photo uploaded from an album keeps that album in the cloud record, and a
//! photo downloaded from the cloud lands in the album of the same name. The
//! service is the real SyncServer; the client is the real engine.
// The shared fixture offers more than this case needs.
#![allow(dead_code)]

#[path = "support/cloud_server.rs"]
mod cloud_server;

use std::fs;

use cloud_server::Server;
use photo_core::{
    cloud::CloudEngine,
    local_library::{LocalLibrary, MediaInput},
};
use tempfile::TempDir;

async fn library_with_album(root: &TempDir, originals: &TempDir) -> (LocalLibrary, String) {
    let album = originals.path().join("Trip");
    fs::create_dir_all(&album).unwrap();
    let file = album.join("review.jpg");
    image::RgbImage::from_pixel(16, 12, image::Rgb([50, 100, 150]))
        .save(&file)
        .unwrap();
    let metadata = fs::metadata(&file).unwrap();
    let library = LocalLibrary::open(root.path()).unwrap();
    let source = library.add_source(originals.path()).unwrap();
    library
        .upsert_batch(
            source,
            vec![MediaInput {
                path: file.to_str().unwrap().into(),
                name: "review.jpg".into(),
                parent: album.to_str().unwrap().into(),
                size_bytes: metadata.len(),
                modified_ns: metadata
                    .modified()
                    .unwrap()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos() as i64,
                mime_type: "image/jpeg".into(),
                width: Some(16),
                height: Some(12),
                orientation: 1,
                capture_time_ms: Some(1_700_000_000_000),
            }],
        )
        .unwrap();
    let media_id = library
        .query(photo_core::local_library::PhotoFilter::default(), None, 100)
        .unwrap()
        .items[0]
        .id
        .clone();
    (library, media_id)
}

#[tokio::test]
#[ignore = "requires a built real SyncServer; see docs/verification/cloud-sync-e2e.md"]
async fn a_photo_keeps_its_album_from_upload_to_download() {
    let server = Server::start().await;
    let originals = tempfile::tempdir().unwrap();
    let uploader_root = tempfile::tempdir().unwrap();
    let (uploader, media_id) = library_with_album(&uploader_root, &originals).await;

    let engine = CloudEngine::new(uploader.clone());
    engine
        .login(&server.endpoint, "review", &server.password)
        .await
        .unwrap();
    // An upload waits for its thumbnail, exactly like the product does.
    let thumbnails = photo_core::thumbnail_loader::ThumbnailLoader::new(uploader.clone(), 1);
    thumbnails
        .request(media_id.clone(), None, 512, "album-mapping".into(), 0)
        .unwrap()
        .await
        .unwrap()
        .unwrap();
    thumbnails.close();
    assert_eq!(engine.queue_upload(vec![media_id]).unwrap().queued, 1);
    let report = engine.sync_now().await.unwrap();
    assert_eq!(report.failed, 0, "{report:?}");
    assert_eq!(report.uploaded, 1, "{report:?}");

    // The cloud record carries the album of the uploaded photo.
    let uploader_db =
        rusqlite::Connection::open(uploader_root.path().join("library.sqlite")).unwrap();
    let relative_path: String = uploader_db
        .query_row("SELECT relative_path FROM cloud_bindings", [], |r| r.get(0))
        .unwrap();
    assert!(
        relative_path.starts_with("Trip/"),
        "the cloud record lost the album: {relative_path}"
    );

    // A second client downloads the photo into the album of the same name.
    let reader_root = tempfile::tempdir().unwrap();
    let reader = LocalLibrary::open(reader_root.path()).unwrap();
    let reader_engine = CloudEngine::new(reader.clone());
    reader_engine
        .login(&server.endpoint, "review", &server.password)
        .await
        .unwrap();
    let report = reader_engine.sync_now().await.unwrap();
    assert_eq!(report.failed, 0, "{report:?}");
    assert_eq!(report.downloaded, 1, "{report:?}");

    let reader_db = rusqlite::Connection::open(reader_root.path().join("library.sqlite")).unwrap();
    let parent: String = reader_db
        .query_row("SELECT parent_uri FROM media", [], |r| r.get(0))
        .unwrap();
    assert!(
        parent.ends_with("/Trip"),
        "the downloaded photo is not in the album of its path: {parent}"
    );
    let albums = reader.list_albums().unwrap();
    assert!(
        albums
            .iter()
            .any(|album| album.name == "Trip" && album.count == 1),
        "the album of the downloaded photo is missing: {albums:?}"
    );

    // A photo that was downloaded before the album mapping existed still sits
    // in the flat cloud album. The next sync moves it into the album of its
    // path, without downloading the bytes again.
    let account = fs::read_dir(reader_root.path().join("cloud"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let flat = reader_root
        .path()
        .join("cloud")
        .join(&account)
        .join("Cloud")
        .to_string_lossy()
        .into_owned();
    reader_db
        .execute("UPDATE media SET parent_uri=?1", [&flat])
        .unwrap();
    let report = reader_engine.sync_now().await.unwrap();
    assert_eq!(report.failed, 0, "{report:?}");
    assert_eq!(report.downloaded, 0, "the photo was downloaded again");
    let parent: String = reader_db
        .query_row("SELECT parent_uri FROM media", [], |r| r.get(0))
        .unwrap();
    assert!(
        parent.ends_with("/Trip"),
        "the photo did not move into the album of its path: {parent}"
    );
}
