use serde_json::Value;
use std::{
    fs,
    io::{Read, Write},
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

/// External codecs receive argument arrays, never a shell. Time and captured
/// output are bounded; their stderr is kept out of user-visible messages.
fn output(mut command: Command) -> Result<Vec<u8>, String> {
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "CodecUnavailable".to_string())?;
    let stdout = child.stdout.take().ok_or("CodecUnavailable")?;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout
            .take(256 * 1024)
            .read_to_end(&mut bytes)
            .map(|_| bytes)
    });
    let start = Instant::now();
    loop {
        if let Some(status) = child.try_wait().map_err(|_| "CodecFailed")? {
            let bytes = reader
                .join()
                .map_err(|_| "CodecFailed")?
                .map_err(|_| "CodecFailed")?;
            return if status.success() {
                Ok(bytes)
            } else {
                Err("CodecFailed".into())
            };
        }
        if start.elapsed() > Duration::from_secs(20) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err("CodecTimedOut".into());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
pub(super) fn probe(path: &Path) -> Result<Value, String> {
    let mut cmd = Command::new("ffprobe");
    cmd.args([
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height,duration:format=duration:format_tags=creation_time",
        "-of",
        "json",
    ])
    .arg(path);
    serde_json::from_slice(&output(cmd)?).map_err(|_| "VideoMetadataFailed".into())
}
pub(super) fn video_header(path: &Path) -> Result<super::headers::Header, String> {
    let value = probe(path)?;
    let stream = value["streams"].get(0).ok_or("VideoMetadataFailed")?;
    let w = stream["width"].as_u64().ok_or("VideoMetadataFailed")? as u32;
    let h = stream["height"].as_u64().ok_or("VideoMetadataFailed")? as u32;
    let mut header = super::headers::header(w, h, 4, None)?;
    header.capture_time_ms = value["format"]["tags"]["creation_time"]
        .as_str()
        .and_then(|s| gio::glib::DateTime::from_iso8601(s, None).ok())
        .map(|t| t.to_unix() * 1000);
    Ok(header)
}
pub(super) fn thumbnail(path: &Path, max_edge: u32, destination: &Path) -> Result<(), String> {
    let dir = destination.parent().ok_or("InvalidDestination")?;
    fs::create_dir_all(dir).map_err(|_| "CacheUnavailable")?;
    // The frame is extracted losslessly and then published through the shared
    // encoder, so a video thumbnail carries the same quality as an image one.
    let frame = tempfile::Builder::new()
        .suffix(".png")
        .tempfile_in(dir)
        .map_err(|_| "CacheUnavailable")?;
    let mut cmd = Command::new("ffmpeg");
    cmd.args(["-v", "error", "-nostdin", "-threads", "1", "-i"])
        .arg(path)
        .args([
            "-frames:v",
            "1",
            "-vf",
            &format!("scale={max_edge}:{max_edge}:force_original_aspect_ratio=decrease"),
            "-y",
        ])
        .arg(frame.path());
    output(cmd)?;
    let decoded = image::open(frame.path()).map_err(|_| "VideoThumbnailFailed")?;
    let mut stage = tempfile::Builder::new()
        .suffix(".jpg")
        .tempfile_in(dir)
        .map_err(|_| "CacheUnavailable")?;
    {
        let mut writer = std::io::BufWriter::new(stage.as_file_mut());
        image::codecs::jpeg::JpegEncoder::new_with_quality(
            &mut writer,
            super::thumbnail::THUMBNAIL_JPEG_QUALITY,
        )
        .encode_image(&decoded.to_rgb8())
        .map_err(|_| "VideoThumbnailFailed")?;
        writer.flush().map_err(|_| "CacheUnavailable")?;
    }
    stage.as_file().sync_all().map_err(|_| "CacheUnavailable")?;
    stage.persist(destination).map_err(|_| "CacheUnavailable")?;
    Ok(())
}
