// The move back to iCloud (0054, Moving between providers, Back to iCloud): after a last service pull, each record the
// person deleted on the service that this device's CloudKit base still names is fetched from the zone, and deleted
// there when its content still equals that base. A `policy` tombstone deletes nothing, since the device keeps its copy
// of what a policy removed (0051), and a copy another device changed on iCloud stays, as a content edit wins.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use tablepro_records::merge::changes_content;
use tablepro_records::record_id::shortened;
use tablepro_records::schema::schema;

use super::{Mover, icloud_file};
use crate::api::cloudkit::{CloudKitFailure, CloudKitFetched, CloudKitOutcome, CloudKitTransport};
use crate::api::control::PassReason;
use crate::api::error::SyncError;
use crate::api::ids::{RecordKey, ScopeName};
use crate::api::state::{Row, RowKey, RowRange, StateStore, Table};
use crate::cloudkit::fetch::{read_everything_again, wire_fields};
use tablepro_records::cloudkit::record_name;

pub(super) struct MoveBack {
    transport: Option<Arc<dyn CloudKitTransport>>,
    account: String,
    state: Option<Arc<dyn StateStore>>,
    // The zone's record names to delete, with the key of each one's CloudKit base.
    deletions: Vec<(String, RecordKey)>,
    // The ids the device's personal stores hold, as the zone names them.
    held: HashSet<RecordKey>,
}

impl MoveBack {
    pub(super) fn len(&self) -> usize {
        self.deletions.len()
    }

    // CloudKit deletes without a change tag, so an edit saved between the fetch and this call is lost, as for any
    // iCloud deletion; the fetch keeps that window to one round trip.
    pub(super) async fn delete(&self) -> Result<(), SyncError> {
        let (Some(transport), Some(state)) = (&self.transport, &self.state) else {
            return Ok(());
        };
        if self.deletions.is_empty() {
            return Ok(());
        }
        let names: Vec<String> = self.deletions.iter().map(|(name, _)| name.clone()).collect();
        let outcomes = transport.modify(self.account.clone(), Vec::new(), names).await?;
        let keys: HashMap<&str, &RecordKey> = self.deletions.iter().map(|(name, key)| (name.as_str(), key)).collect();
        let mut txn = state.begin().await?;
        let mut failed = None;
        for outcome in outcomes {
            match outcome {
                CloudKitOutcome::Deleted { name } | CloudKitOutcome::UnknownItem { name } => {
                    if let Some(key) = keys.get(name.as_str()) {
                        txn.delete(&RowKey::Base((*key).clone())).await?;
                    }
                }
                CloudKitOutcome::Failed { code, .. } => failed = Some(code),
                CloudKitOutcome::Saved { .. } | CloudKitOutcome::ServerChanged { .. } => {}
            }
        }
        txn.commit().await?;
        // What did go is settled above; the rest is the person's to try again.
        match failed {
            Some(code) => Err(CloudKitFailure::Other { code }.into()),
            None => Ok(()),
        }
    }

    // The ids the personal stores hold once personal sync rests, so a pass that ran between the plan and the fence
    // leaves no base behind for a record it took off this device.
    pub(super) async fn held_now(&mut self, service: &crate::service::ServiceSync) -> Result<(), SyncError> {
        self.held = service
            .personal_ids()
            .await?
            .into_iter()
            .flat_map(|(kind, ids)| {
                ids.into_iter()
                    .map(move |id| RecordKey::new(ScopeName::Personal, kind, shortened(kind, id)))
            })
            .collect();
        Ok(())
    }

    // Nothing but what the person confirmed may go from the zone: any other CloudKit base the device's stores lack,
    // whatever the service did meanwhile, loses its base, so the iCloud engine sends no deletion for it, and the next
    // fetch reads the zone whole and brings the record back.
    pub(super) async fn keep_the_rest(&self) -> Result<(), SyncError> {
        let Some(state) = &self.state else {
            return Ok(());
        };
        let mut txn = state.begin().await?;
        for row in txn.scan(&RowRange::Scope(Table::Bases, ScopeName::Personal)).await? {
            if let Row::Base(base) = row
                && !self.held.contains(&base.key)
            {
                txn.delete(&RowKey::Base(base.key)).await?;
            }
        }
        // The file syncs on iCloud again once its move back ends.
        txn.delete(&RowKey::Move).await?;
        txn.commit().await?;
        read_everything_again(state.as_ref()).await
    }
}

impl Mover {
    pub(super) async fn move_back(&self) -> Result<MoveBack, SyncError> {
        if self.parts.icloud.is_some() {
            return Err(SyncError::NotAllowed {
                what: "move back to iCloud while iCloud is the provider",
            });
        }
        let transport = Arc::clone(self.transport()?);
        self.parts.service.run_pass(PassReason::Person).await?;
        let nothing = |account: String| MoveBack {
            transport: None,
            account,
            state: None,
            deletions: Vec::new(),
            held: HashSet::new(),
        };
        let Some(account) = self.parts.icloud_account.clone() else {
            return Ok(nothing(String::new()));
        };
        // Another Apple ID signed in meanwhile starts from a full fetch of its own zone, so nothing of this file applies.
        let signed_in = transport
            .account_status()
            .await
            .map_err(SyncError::from)?
            .user_record_name;
        if signed_in != account {
            return Ok(nothing(account));
        }
        let state = self.parts.files.open(icloud_file(&account)).await?;
        let mut asked: Vec<(String, RecordKey, serde_json::Value)> = Vec::new();
        let mut txn = state.begin().await?;
        for key in self.parts.service.deleted_by_the_person().await? {
            let Some(kind) = key.kind.known() else { continue };
            let named = RecordKey::new(ScopeName::Personal, kind, shortened(kind, key.record_id.clone()));
            let (Some(Row::Base(base)), Some(name)) = (
                txn.get(&RowKey::Base(named.clone())).await?,
                record_name(kind, &named.record_id),
            ) else {
                continue;
            };
            if let Some(fields) = base.fields {
                asked.push((name, named, fields));
            }
        }
        drop(txn);
        let mut deletions = Vec::new();
        if !asked.is_empty() {
            let names = asked.iter().map(|(name, ..)| name.clone()).collect();
            let fetched = transport.fetch_records(account.clone(), names).await?;
            let mut copies = HashMap::new();
            for answer in fetched {
                match answer {
                    CloudKitFetched::Found { record } => {
                        if let Some((_, fields)) = wire_fields(&record) {
                            copies.insert(record.name, fields);
                        }
                    }
                    CloudKitFetched::Missing { .. } => {}
                    CloudKitFetched::Failed { code, .. } => return Err(CloudKitFailure::Other { code }.into()),
                }
            }
            for (name, named, base) in asked {
                let Some(kind) = named.kind.known() else { continue };
                let unchanged = copies
                    .get(&name)
                    .is_some_and(|copy| !changes_content(&schema(kind), &base, copy));
                if unchanged {
                    deletions.push((name, named));
                }
            }
        }
        let held = self
            .parts
            .service
            .personal_ids()
            .await?
            .into_iter()
            .flat_map(|(kind, ids)| {
                ids.into_iter()
                    .map(move |id| RecordKey::new(ScopeName::Personal, kind, shortened(kind, id)))
            })
            .collect();
        Ok(MoveBack {
            transport: Some(transport),
            account,
            state: Some(state),
            deletions,
            held,
        })
    }
}
