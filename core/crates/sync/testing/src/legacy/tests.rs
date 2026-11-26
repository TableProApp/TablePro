use tablepro_sync::api::cloudkit::{CloudKitField, CloudKitRecord, CloudKitValue};
use tablepro_sync::api::legacy::{LegacyMetadata, LegacyMirror, LegacyRecordRef, LegacyTombstone};

use super::FakeLegacyMirror;

fn reference(record_type: &str, id: &str) -> LegacyRecordRef {
    LegacyRecordRef {
        record_type: record_type.to_owned(),
        id: id.to_owned(),
    }
}

fn cached(name: &str, system_fields: Option<Vec<u8>>) -> CloudKitRecord {
    CloudKitRecord {
        record_type: "ConnectionTag".to_owned(),
        name: name.to_owned(),
        system_fields,
        created_ms: None,
        fields: vec![
            CloudKitField {
                name: "name".to_owned(),
                value: Some(CloudKitValue::Text("Production".to_owned())),
            },
            CloudKitField {
                name: "color".to_owned(),
                value: None,
            },
        ],
    }
}

fn pass(account: &str) -> LegacyMetadata {
    LegacyMetadata {
        token: Some(vec![1]),
        dirty: vec![reference("Connection", "A"), reference("ConnectionProject", "P")],
        tombstones: vec![LegacyTombstone {
            record: reference("ConnectionGroup", "G"),
            deleted_at_ms: 5,
            owner: None,
        }],
        changes_held_for_unreadable: vec!["Connection_C".to_owned()],
        account: Some(account.to_owned()),
        zone_state: Some("confirmed".to_owned()),
        cache: vec![cached("Tag_A", Some(vec![7])), cached("Tag_B", None)],
        ..LegacyMetadata::default()
    }
}

#[tokio::test]
async fn a_write_reads_back_as_the_previous_stable_keeps_it() {
    let mirror = FakeLegacyMirror::new();

    mirror.write(pass("_a")).await.unwrap();
    let read = mirror.read().await.unwrap();

    assert_eq!(read.dirty, vec![reference("Connection", "A")]);
    assert_eq!(read.tombstones.len(), 1);
    assert_eq!(read.cache.len(), 1);
    assert_eq!(read.cache[0].fields.len(), 1);
    assert_eq!(read.token, Some(vec![1]));
}

#[tokio::test]
async fn another_account_s_write_drops_the_last_account_s_position_first() {
    let mirror = FakeLegacyMirror::new();
    mirror.write(pass("_a")).await.unwrap();
    let mut next = pass("_b");
    next.token = None;
    next.tombstones.clear();
    next.changes_held_for_unreadable.clear();
    next.cache.clear();

    mirror.write(next).await.unwrap();
    let read = mirror.read().await.unwrap();

    assert_eq!(read.account.as_deref(), Some("_b"));
    assert!(read.token.is_none() && read.tombstones.is_empty() && read.cache.is_empty());
}

#[tokio::test]
async fn a_mark_makes_a_written_record_dirty_and_a_deleted_one_a_tombstone() {
    let mirror = FakeLegacyMirror::new();
    mirror.write(pass("_a")).await.unwrap();

    mirror
        .mark(
            vec![reference("ConnectionTag", "T")],
            vec![LegacyTombstone {
                record: reference("Connection", "A"),
                deleted_at_ms: 9,
                owner: None,
            }],
        )
        .await
        .unwrap();
    let read = mirror.read().await.unwrap();

    assert_eq!(read.dirty, vec![reference("ConnectionTag", "T")]);
    assert!(read.tombstones.iter().any(|tombstone| tombstone.record.id == "A"));
}

#[tokio::test]
async fn re_encoded_system_fields_differ_from_what_was_written() {
    let mirror = FakeLegacyMirror::new();
    mirror.write(pass("_a")).await.unwrap();
    mirror.reencode_system_fields();

    let read = mirror.read().await.unwrap();

    assert_ne!(read.cache[0].system_fields, Some(vec![7]));
}
