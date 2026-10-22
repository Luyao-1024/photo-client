//! Generic issued metadata mutations. The application persists the logical
//! request and a request-wide ID before invoking the SDK, just as the old client.
use super::*;

#[derive(Clone, Debug)]
pub struct MetadataMutation {
    pub operation_id: String,
    pub zone: ZoneId,
    pub photo_id: String,
    pub record_revision: String,
    pub metadata: PhotoMetadata,
    pub is_trashed: bool,
    pub event: EditEvent,
}

pub fn validate_metadata_confirmation(
    mutation: &MetadataMutation,
    record: RemoteRecord,
) -> Result<RemoteRecord, Error> {
    if record.deleted
        || record.record_name != mutation.photo_id
        || record
            .record_change_tag
            .as_deref()
            .is_none_or(str::is_empty)
        || record.events.metadata_event.as_ref() != Some(&mutation.event)
        || record.int64("isFavorite") != Some(i64::from(mutation.metadata.is_favorite))
        || record.string("relativePath") != Some(mutation.metadata.relative_path.as_str())
        || record.int64("isHidden") != Some(i64::from(mutation.metadata.is_hidden))
        || record.int64("isTrashed").unwrap_or(0) != i64::from(mutation.is_trashed)
        || record.int64("assetDate") != mutation.metadata.asset_date_ms
    {
        return Err(Error::Protocol(
            "metadata confirmation does not match the issued event and values".into(),
        ));
    }
    Ok(record)
}

pub fn metadata_receipt(
    mutation: &MetadataMutation,
    receipt: &serde_json::Value,
) -> Result<RemoteRecord, Error> {
    if receipt.get("serverErrorCode").is_some() {
        let failure = serde_json::from_value(receipt.clone())
            .map_err(|_| Error::Protocol("invalid metadata failure receipt".into()))?;
        return Err(Error::InBand(Box::new(failure)));
    }
    let records = receipt
        .get("records")
        .and_then(serde_json::Value::as_array)
        .filter(|records| records.len() == 1)
        .ok_or_else(|| Error::Protocol("metadata receipt did not confirm one record".into()))?;
    if records[0].get("serverErrorCode").is_some() {
        let failure = serde_json::from_value(records[0].clone())
            .map_err(|_| Error::Protocol("invalid metadata record failure".into()))?;
        return Err(Error::InBand(Box::new(failure)));
    }
    let record = serde_json::from_value(records[0].clone())
        .map_err(|_| Error::Protocol("invalid metadata record receipt".into()))?;
    validate_metadata_confirmation(mutation, record)
}

pub async fn update_metadata(
    connection: &Connection,
    lease: &UploadLease,
    mutation: &MetadataMutation,
) -> Result<RemoteRecord, Error> {
    lease.require_held()?;
    if lease.phase() != Some(UploadPhase::Modify) || lease.zone() != &mutation.zone {
        return Err(Error::PhaseMismatch(
            "metadata mutation requires its original zone and modify phase".into(),
        ));
    }
    let metadata = &mutation.metadata;
    let operation = RecordOperation::update_fields(
        &mutation.photo_id,
        &mutation.record_revision,
        std::collections::BTreeMap::from([
            (
                "relativePath".into(),
                Some(Field::string(&metadata.relative_path)),
            ),
            (
                "isFavorite".into(),
                Some(Field::int64(i64::from(metadata.is_favorite))),
            ),
            (
                "isHidden".into(),
                Some(Field::int64(i64::from(metadata.is_hidden))),
            ),
            (
                "isTrashed".into(),
                Some(Field::int64(i64::from(mutation.is_trashed))),
            ),
            (
                "assetDate".into(),
                metadata.asset_date_ms.map(Field::timestamp),
            ),
        ]),
    )
    .with_events(EditEvents {
        metadata_event: Some(mutation.event.clone()),
        ..EditEvents::default()
    });
    let request = ModifyRequest::new(mutation.zone.clone(), vec![operation])
        .idempotency_key(&mutation.operation_id);
    match connection
        .modify(lease.proof(), request)
        .await?
        .into_iter()
        .next()
    {
        Some(RecordResult::Confirmed(record)) => validate_metadata_confirmation(mutation, record),
        Some(RecordResult::Failed(failure)) => Err(Error::InBand(Box::new(failure))),
        _ => Err(Error::Protocol(
            "metadata mutation did not confirm the record".into(),
        )),
    }
}
