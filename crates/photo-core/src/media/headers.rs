//! Bounded header reads. In particular, image::JpegDecoder is unsuitable here:
//! its constructor reads the entire original even for a dimensions-only query.
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

use exif::{In, Tag, Value};
use image::ImageFormat;

const HEADER_BUDGET: usize = 1024 * 1024;
const EXIF_BUDGET: usize = 256 * 1024;
const MAX_CHUNKS: usize = 8192;

pub(super) struct Header {
    pub width: u32,
    pub height: u32,
    pub orientation: u8,
    pub capture_time_ms: Option<i64>,
    pub bytes_per_pixel: u64,
}

struct Reader<'a> {
    file: &'a mut File,
    size: u64,
    remaining: usize,
}
impl Reader<'_> {
    fn bytes(&mut self, count: usize) -> Result<Vec<u8>, String> {
        self.remaining = self
            .remaining
            .checked_sub(count)
            .ok_or("InvalidImageHeader: metadata read budget exceeded")?;
        let mut bytes = vec![0; count];
        self.file
            .read_exact(&mut bytes)
            .map_err(|e| format!("InvalidImageHeader: {e}"))?;
        Ok(bytes)
    }
    fn fixed<const N: usize>(&mut self) -> Result<[u8; N], String> {
        self.remaining = self
            .remaining
            .checked_sub(N)
            .ok_or("InvalidImageHeader: metadata read budget exceeded")?;
        let mut data = [0; N];
        self.file
            .read_exact(&mut data)
            .map_err(|e| format!("InvalidImageHeader: {e}"))?;
        Ok(data)
    }
    fn position(&mut self) -> Result<u64, String> {
        self.file
            .stream_position()
            .map_err(|e| format!("SourceRead: {e}"))
    }
    fn seek(&mut self, position: u64) -> Result<(), String> {
        if position > self.size {
            return Err("InvalidImageHeader: truncated segment".into());
        }
        self.file
            .seek(SeekFrom::Start(position))
            .map_err(|e| format!("SourceRead: {e}"))?;
        Ok(())
    }
    fn end(&mut self, length: u64) -> Result<u64, String> {
        self.position()?
            .checked_add(length)
            .filter(|p| *p <= self.size)
            .ok_or_else(|| "InvalidImageHeader: truncated segment".into())
    }
}

pub(super) fn header(
    width: u32,
    height: u32,
    bytes_per_pixel: u64,
    exif: Option<Vec<u8>>,
) -> Result<Header, String> {
    if width == 0 || height == 0 {
        return Err("InvalidImageHeader: zero image dimension".into());
    }
    let (orientation, capture_time_ms) = exif
        .and_then(|raw| {
            let raw = raw.strip_prefix(b"Exif\0\0").unwrap_or(&raw).to_vec();
            exif::Reader::new().read_raw(raw).ok()
        })
        .map(|exif| {
            let orientation = exif
                .get_field(Tag::Orientation, In::PRIMARY)
                .and_then(|f| f.value.get_uint(0))
                .filter(|v| (1..=8).contains(v))
                .unwrap_or(1) as u8;
            (orientation, capture_time(&exif))
        })
        .unwrap_or((1, None));
    Ok(Header {
        width,
        height,
        orientation,
        capture_time_ms,
        bytes_per_pixel,
    })
}

pub(super) fn read(file: &mut File, format: ImageFormat, size: u64) -> Result<Header, String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|e| format!("SourceRead: {e}"))?;
    let mut r = Reader {
        file,
        size,
        remaining: HEADER_BUDGET,
    };
    match format {
        ImageFormat::Jpeg => jpeg(&mut r),
        ImageFormat::Png => png(&mut r),
        ImageFormat::WebP => webp(&mut r),
        ImageFormat::Gif => {
            let magic = r.fixed::<6>()?;
            if magic != *b"GIF87a" && magic != *b"GIF89a" {
                return Err("InvalidImageHeader".into());
            }
            let size = r.fixed::<4>()?;
            header(
                u16::from_le_bytes([size[0], size[1]]) as u32,
                u16::from_le_bytes([size[2], size[3]]) as u32,
                4,
                None,
            )
        }
        _ => Err("UnsupportedSource: image format".into()),
    }
}

fn jpeg(r: &mut Reader<'_>) -> Result<Header, String> {
    if r.fixed::<2>()?.as_slice() != b"\xff\xd8" {
        return Err("InvalidImageHeader: not JPEG".into());
    }
    let mut dimensions = None;
    let mut exif = None;
    for _ in 0..MAX_CHUNKS {
        if r.fixed::<1>()?[0] != 0xff {
            return Err("InvalidImageHeader: invalid JPEG marker".into());
        }
        let mut marker = r.fixed::<1>()?[0];
        while marker == 0xff {
            marker = r.fixed::<1>()?[0];
        }
        match marker {
            0xda => {
                let (width, height) =
                    dimensions.ok_or("InvalidImageHeader: JPEG lacks frame dimensions")?;
                return header(width, height, 4, exif);
            }
            0xd9 => return Err("InvalidImageHeader: JPEG lacks scan data".into()),
            0x01 | 0xd0..=0xd7 => continue,
            0 | 0xd8 => return Err("InvalidImageHeader: invalid JPEG marker".into()),
            _ => {}
        }
        let length = r.fixed::<2>()?;
        let length = u16::from_be_bytes([length[0], length[1]])
            .checked_sub(2)
            .ok_or("InvalidImageHeader: JPEG segment length")?;
        let end = r.end(u64::from(length))?;
        if matches!(marker, 0xc0..=0xc3 | 0xc5..=0xc7 | 0xc9..=0xcb | 0xcd..=0xcf) {
            if length < 6 {
                return Err("InvalidImageHeader: short JPEG frame".into());
            }
            let data = r.fixed::<6>()?;
            dimensions = Some((
                u32::from(u16::from_be_bytes([data[3], data[4]])),
                u32::from(u16::from_be_bytes([data[1], data[2]])),
            ));
        } else if marker == 0xe1 && exif.is_none() && length >= 6 {
            let prefix = r.fixed::<6>()?;
            if prefix.as_slice() == b"Exif\0\0" {
                exif = Some(r.bytes(usize::from(length) - 6)?);
            }
        }
        r.seek(end)?;
    }
    Err("InvalidImageHeader: excessive JPEG segments".into())
}

fn png(r: &mut Reader<'_>) -> Result<Header, String> {
    if r.fixed::<8>()?.as_slice() != b"\x89PNG\r\n\x1a\n" {
        return Err("InvalidImageHeader: not PNG".into());
    }
    let mut dimensions = None;
    let mut exif = None;
    for number in 0..MAX_CHUNKS {
        let data = r.fixed::<8>()?;
        let length = u32::from_be_bytes(data[..4].try_into().unwrap());
        let end = r.end(u64::from(length) + 4)?; // Include CRC; pixel chunks are sought over.
        match &data[4..8] {
            b"IHDR" if number == 0 && length == 13 => {
                let data = r.fixed::<13>()?;
                let width = u32::from_be_bytes(data[..4].try_into().unwrap());
                let height = u32::from_be_bytes(data[4..8].try_into().unwrap());
                dimensions = Some((width, height, if data[8] == 16 { 8 } else { 4 }));
            }
            _ if number == 0 => return Err("InvalidImageHeader: PNG lacks IHDR".into()),
            b"eXIf" if exif.is_none() => {
                if length as usize > EXIF_BUDGET {
                    return Err("MetadataBudgetExceeded: PNG EXIF exceeds 256 KiB".into());
                }
                exif = Some(r.bytes(length as usize)?);
            }
            b"IEND" if length == 0 => {
                let (width, height, bpp) =
                    dimensions.ok_or("InvalidImageHeader: PNG lacks dimensions")?;
                return header(width, height, bpp, exif);
            }
            _ => {}
        }
        r.seek(end)?;
    }
    Err("InvalidImageHeader: excessive PNG chunks".into())
}

fn webp(r: &mut Reader<'_>) -> Result<Header, String> {
    let signature = r.fixed::<12>()?;
    if &signature[..4] != b"RIFF" || &signature[8..] != b"WEBP" {
        return Err("InvalidImageHeader: not WebP".into());
    }
    let container_end = 8 + u64::from(u32::from_le_bytes(signature[4..8].try_into().unwrap()));
    if container_end > r.size || container_end < 12 {
        return Err("InvalidImageHeader: truncated WebP".into());
    }
    let mut dimensions = None;
    let mut exif = None;
    for _ in 0..MAX_CHUNKS {
        if r.position()? == container_end {
            let (width, height) = dimensions.ok_or("InvalidImageHeader: WebP lacks dimensions")?;
            return header(width, height, 4, exif);
        }
        let data = r.fixed::<8>()?;
        let length = u32::from_le_bytes(data[4..8].try_into().unwrap());
        let end = r.end(u64::from(length) + u64::from(length & 1))?;
        if end > container_end {
            return Err("InvalidImageHeader: WebP chunk exceeds container".into());
        }
        match &data[..4] {
            b"VP8X" if length >= 10 => {
                let p = r.fixed::<10>()?;
                let width = 1 + u32::from_le_bytes([p[4], p[5], p[6], 0]);
                let height = 1 + u32::from_le_bytes([p[7], p[8], p[9], 0]);
                dimensions = Some((width, height));
            }
            b"VP8 " if dimensions.is_none() && length >= 10 => {
                let p = r.fixed::<10>()?;
                if p[3..6] != [0x9d, 0x01, 0x2a] {
                    return Err("InvalidImageHeader: WebP frame header".into());
                }
                dimensions = Some((
                    u32::from(u16::from_le_bytes([p[6], p[7]]) & 0x3fff),
                    u32::from(u16::from_le_bytes([p[8], p[9]]) & 0x3fff),
                ));
            }
            b"VP8L" if dimensions.is_none() && length >= 5 => {
                let p = r.fixed::<5>()?;
                if p[0] != 0x2f {
                    return Err("InvalidImageHeader: WebP lossless signature".into());
                }
                let bits = u32::from_le_bytes(p[1..5].try_into().unwrap());
                dimensions = Some(((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1));
            }
            b"EXIF" if exif.is_none() => {
                if length as usize > EXIF_BUDGET {
                    return Err("MetadataBudgetExceeded: WebP EXIF exceeds 256 KiB".into());
                }
                exif = Some(r.bytes(length as usize)?);
            }
            _ => {}
        }
        r.seek(end)?;
    }
    Err("InvalidImageHeader: excessive WebP chunks".into())
}

fn ascii(exif: &exif::Exif, tag: Tag) -> Option<&[u8]> {
    match &exif.get_field(tag, In::PRIMARY)?.value {
        Value::Ascii(values) => values.first().map(Vec::as_slice),
        _ => None,
    }
}

pub(super) fn capture_time(exif: &exif::Exif) -> Option<i64> {
    let mut time = exif::DateTime::from_ascii(ascii(exif, Tag::DateTimeOriginal)?).ok()?;
    // EXIF wall time without an offset does not identify a UTC instant.
    let offset_ascii = ascii(exif, Tag::OffsetTimeOriginal)?;
    if offset_ascii.len() != 6
        || !matches!(offset_ascii[0], b'+' | b'-')
        || offset_ascii[3] != b':'
        || !offset_ascii[1..3]
            .iter()
            .chain(&offset_ascii[4..6])
            .all(u8::is_ascii_digit)
        || offset_ascii[4] > b'5'
    {
        return None;
    }
    time.parse_offset(offset_ascii).ok()?;
    if let Some(value) = ascii(exif, Tag::SubSecTimeOriginal) {
        time.parse_subsec(value).ok()?;
    }
    let (year, month, day) = (
        i64::from(time.year),
        i64::from(time.month),
        i64::from(time.day),
    );
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days = match month {
        2 => {
            if leap {
                29
            } else {
                28
            }
        }
        4 | 6 | 9 | 11 => 30,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => return None,
    };
    if !(1..=9999).contains(&year)
        || !(1..=days).contains(&day)
        || time.hour > 23
        || time.minute > 59
        || time.second > 59
    {
        return None;
    }
    let offset = i64::from(time.offset?);
    if offset.abs() > 14 * 60 {
        return None;
    }
    let adjusted_year = year - i64::from(month <= 2);
    let era = adjusted_year.div_euclid(400);
    let yoe = adjusted_year - era * 400;
    let m = month + if month > 2 { -3 } else { 9 };
    let doy = (153 * m + 2) / 5 + day - 1;
    let epoch_days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468;
    Some(
        (epoch_days * 86400
            + i64::from(time.hour) * 3600
            + i64::from(time.minute) * 60
            + i64::from(time.second)
            - offset * 60)
            * 1000
            + i64::from(time.nanosecond.unwrap_or(0) / 1_000_000),
    )
}
