// How personal data arriving on the service meets the device's records in its first snapshot (0054, Moving between
// providers): from iCloud, against the copy both providers last shared, with the move marker written by the first
// mover; from no provider, as a refill, where the server's copy wins.

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, PoisonError};

use serde_json::Value;
use tablepro_records::move_marker::{MEMBER, MoveMarker};
use tablepro_records::record_id::shortened;

use crate::api::ids::{ChangeTag, RecordKey, ScopeName};
use crate::api::state::BaseRow;
use crate::cloudkit::modify::IcloudCopy;
use crate::engine::{Pending, PendingOp};

pub(crate) enum Arrival {
    FromIcloud(FromIcloud),
    FirstUpload,
}

pub(crate) struct FromIcloud {
    // This device's CloudKit bases, by the ids the zone names records with (0052, Long ids).
    bases: HashMap<RecordKey, BaseRow>,
    // Every record a full fetch found in the zone; None when the zone could not be read, so no deletion is inferred.
    listed: Option<HashSet<RecordKey>>,
    // The markers the service's copies carried, by the service's ids, as the snapshot found them.
    markers: Mutex<HashMap<RecordKey, MoveMarker>>,
}

// The id the zone names a service record by.
fn in_zone(key: &RecordKey) -> Option<RecordKey> {
    let kind = key.kind.known()?;
    Some(RecordKey::new(
        ScopeName::Personal,
        kind,
        shortened(kind, key.record_id.clone()),
    ))
}

impl Arrival {
    pub(crate) fn from_icloud(copy: IcloudCopy) -> Self {
        Self::FromIcloud(FromIcloud {
            bases: copy
                .bases
                .into_iter()
                .filter(|base| base.deleted.is_none())
                .map(|base| (base.key.clone(), base))
                .collect(),
            listed: copy.listed.map(|listed| listed.into_iter().collect()),
            markers: Mutex::default(),
        })
    }

    fn icloud(&self) -> Option<&FromIcloud> {
        match self {
            Self::FromIcloud(icloud) => Some(icloud),
            Self::FirstUpload => None,
        }
    }

    pub(crate) const fn pull_wins(&self) -> bool {
        matches!(self, Self::FirstUpload)
    }

    // This device's CloudKit base of a service record, as the merge's base. Its tag is CloudKit's, which no service
    // copy ever matches, so the snapshot always merges against it.
    pub(crate) fn icloud_base(&self, key: &RecordKey) -> Option<BaseRow> {
        let base = self.icloud()?.bases.get(&in_zone(key)?)?;
        Some(BaseRow {
            key: key.clone(),
            ..base.clone()
        })
    }

    pub(crate) fn marked(&self, key: &RecordKey, marker: MoveMarker) {
        if let Some(icloud) = self.icloud() {
            icloud
                .markers
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(key.clone(), marker);
        }
    }

    pub(crate) fn marker(&self, key: &RecordKey) -> Option<MoveMarker> {
        self.icloud()?
            .markers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(key)
            .cloned()
    }

    // The zone no longer lists a record another device moved: a device still on iCloud deleted it since.
    pub(crate) fn gone(&self, key: &RecordKey) -> bool {
        let Some(icloud) = self.icloud() else {
            return false;
        };
        match (&icloud.listed, in_zone(key)) {
            (Some(listed), Some(named)) => !listed.contains(&named),
            _ => false,
        }
    }

    // The first device that moves a record creates it on the service with the marker of the CloudKit base it moved
    // from, in the patch only, so the base this device keeps never holds it. A copy the service already holds keeps the
    // marker it has, or none, so no later mover replaces the first one's.
    pub(crate) fn mark(&self, pending: &mut [Pending]) {
        let Some(icloud) = self.icloud() else {
            return;
        };
        let markers = icloud.markers.lock().unwrap_or_else(PoisonError::into_inner);
        for change in pending.iter_mut() {
            if change.base.is_some() || markers.contains_key(&change.key) {
                continue;
            }
            let PendingOp::Write { patch, .. } = &mut change.op else {
                continue;
            };
            let Some(base) = in_zone(&change.key).and_then(|named| icloud.bases.get(&named)) else {
                continue;
            };
            let (ChangeTag::CloudKit(system_fields), Some(fields)) = (&base.tag, &base.fields) else {
                continue;
            };
            if let Value::Object(members) = patch {
                members.insert(MEMBER.to_owned(), MoveMarker::of(fields, system_fields).to_value());
            }
        }
    }
}
