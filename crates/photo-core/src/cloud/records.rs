//! Cache records without transport capabilities and rebuild the photo graph.
use syncserver_client::{PhotoGraph, RemotePhoto, RemoteRecord};
use serde_json::Value;

use crate::local_library::StoredCloudRecord;

pub(super) fn stored(record: &RemoteRecord) -> Result<StoredCloudRecord, String> {
    let mut value = serde_json::to_value(record).map_err(|_| "Internal")?;
    scrub(&mut value);
    Ok(StoredCloudRecord {
        record_name: record.record_name.clone(),
        record_type: record.record_type.clone(),
        record_change_tag: record.record_change_tag.clone(),
        deleted: record.deleted,
        record_json: (!record.deleted)
            .then(|| serde_json::to_string(&value))
            .transpose()
            .map_err(|_| "Internal")?,
    })
}

/// `downloadURL` and `receipt` are temporary capabilities. They must never be
/// written to the catalog, so they are removed before the JSON is cached.
fn scrub(value: &mut Value) {
    match value {
        Value::Object(map) => {
            map.remove("downloadURL");
            map.remove("receipt");
            for child in map.values_mut() {
                scrub(child);
            }
        }
        Value::Array(items) => {
            for item in items {
                scrub(item);
            }
        }
        _ => {}
    }
}

pub(super) fn graph(records: &[StoredCloudRecord]) -> Result<PhotoGraph, String> {
    let mut decoded = Vec::with_capacity(records.len());
    for record in records {
        if record.deleted {
            continue;
        }
        let json = record.record_json.as_deref().ok_or("GraphInvalid")?;
        decoded.push(serde_json::from_str::<RemoteRecord>(json).map_err(|_| "GraphInvalid")?);
    }
    PhotoGraph::from_records(decoded.iter()).map_err(|_| "GraphInvalid".into())
}

pub(super) fn is_trashed(photo: &RemotePhoto) -> bool {
    photo.asset.int64("isTrashed").unwrap_or(0) != 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn record() -> RemoteRecord {
        serde_json::from_value(json!({
            "recordName": "asset-1",
            "recordType": "CPLAsset",
            "recordChangeTag": "tag-1",
            "fields": {
                "resOriginalRes": {
                    "type": "ASSETID",
                    "value": {
                        "assetId": "6f1e6f7a-6d1e-4d3c-9b6a-2c3d4e5f6071",
                        "size": 10,
                        "fileChecksum": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                        "checksumAlgorithm": "SHA256",
                        "mimeType": "image/jpeg",
                        "downloadURL": "https://example.invalid/secret?token=1",
                        "receipt": "opaque-receipt"
                    }
                },
                "relativePath": {"type": "STRING", "value": "album/one.jpg"}
            }
        }))
        .unwrap()
    }

    #[test]
    fn cached_json_has_no_transport_capabilities() {
        let stored = stored(&record()).unwrap();
        let json = stored.record_json.unwrap();
        assert!(!json.contains("downloadURL"));
        assert!(!json.contains("receipt"));
        assert!(!json.contains("example.invalid"));
        assert!(json.contains("album/one.jpg"));
    }

    #[test]
    fn tombstones_keep_identity_without_payload() {
        let mut record = record();
        record.deleted = true;
        let stored = stored(&record).unwrap();
        assert!(stored.deleted);
        assert_eq!(stored.record_json, None);
        assert!(graph(&[stored]).unwrap().photos.is_empty());
    }
}
