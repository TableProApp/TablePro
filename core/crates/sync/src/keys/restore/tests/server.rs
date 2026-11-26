// 0051's lost-write rule over the bases, as push-back reads what the server holds.

use super::fakes::epoch;
use crate::api::ids::{ChangeTag, KindName, RecordKey, ScopeName};
use crate::api::scopes::LineageEpoch;
use crate::api::state::BaseRow;
use crate::api::transport::DeletedReason;
use crate::keys::restore::server::survives;

fn base(written: Option<u128>, revision: Option<u64>) -> BaseRow {
    BaseRow {
        key: RecordKey::new(ScopeName::Personal, KindName::parse("key.account").unwrap(), "x"),
        tag: ChangeTag::Service("tag".to_owned()),
        version: Some(1),
        revision,
        epoch: written.map(epoch),
        deleted: None,
        fields: None,
        created_ms: None,
    }
}

fn lineage() -> Vec<LineageEpoch> {
    vec![
        LineageEpoch {
            id: epoch(1),
            kept_revision: 0,
        },
        LineageEpoch {
            id: epoch(2),
            kept_revision: 40,
        },
    ]
}

#[test]
fn a_base_survives_only_below_the_cut_of_the_epoch_after_its_own() {
    assert!(survives(&base(Some(1), Some(40)), &lineage()));
    assert!(!survives(&base(Some(1), Some(41)), &lineage()));
    assert!(survives(&base(Some(2), Some(90)), &lineage()), "the current epoch");
}

#[test]
fn a_base_from_an_epoch_the_server_does_not_list_is_lost() {
    assert!(!survives(&base(Some(3), Some(1)), &lineage()));
}

#[test]
fn a_base_with_no_epoch_or_revision_or_a_tombstone_is_no_evidence() {
    assert!(!survives(&base(None, Some(1)), &lineage()));
    assert!(!survives(&base(Some(2), None), &lineage()));
    let tombstone = BaseRow {
        deleted: Some(DeletedReason::User),
        ..base(Some(2), Some(1))
    };
    assert!(!survives(&tombstone, &lineage()));
}
