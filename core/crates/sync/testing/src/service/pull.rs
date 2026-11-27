// `GET /v2/sync/scopes/{scope}/changes` (0051, Pull): a snapshot up to a mark in pages, then the changes after it in
// revision order. A page with no records is caught up, and no page ends inside a change set.

use serde_json::Value;
use tablepro_records::limits;
use tablepro_sync::api::ids::{Cursor, ScopeName};
use tablepro_sync::api::transport::{PullRequest, PulledPage, PulledRecord, ServiceMeta, TransportError};
use uuid::Uuid;

use super::push::{expires_at, held_until};
use super::{Approval, CursorPhase, CursorState, FakeClient, ScopeData, ScopeOwner, State, StoredRecord};

pub const PAGE_RECORDS: usize = 500;
pub const PAGE_BYTES: usize = 4 << 20;

impl FakeClient {
    pub(crate) fn pull_page(&self, request: &PullRequest) -> Result<PulledPage, TransportError> {
        let mut state = self.server.lock();
        self.admit(&mut state, Some(request.scope))?;
        let approval = self.approval(&state, &request.proof);
        let pre_approval = match (request.scope, approval) {
            (ScopeName::Team(_), _) => false,
            (_, Approval::NoProof) | (ScopeName::History, Approval::Unapproved) => {
                return Err(TransportError::DeviceNotApproved);
            }
            (ScopeName::Personal, Approval::Unapproved) => true,
            (_, Approval::Approved) => false,
        };
        let owner = ScopeOwner::of(request.scope, self.account);
        let Some(data) = state.scopes.get(&owner).cloned() else {
            return Ok(PulledPage {
                records: Vec::new(),
                cursor: None,
                changes_cursor: None,
                caught_up: true,
                unread: Vec::new(),
            });
        };
        let limit = request
            .limit
            .map_or(PAGE_RECORDS, |limit| usize::try_from(limit).unwrap_or(PAGE_RECORDS))
            .clamp(1, PAGE_RECORDS);
        let phase = match &request.cursor {
            None if request.scope == ScopeName::History => CursorPhase::HistoryOlder {
                mark: data.horizon(),
                before: u64::MAX,
            },
            None => CursorPhase::Snapshot {
                mark: data.horizon(),
                after: None,
            },
            Some(cursor) => self.resume(&state, owner, cursor, pre_approval, &data)?,
        };
        let page = Page {
            owner,
            epoch: state.epoch(),
            pre_approval,
            limit,
        };
        Ok(page.read(&self.server, &data, phase))
    }

    fn resume(
        &self,
        state: &State,
        owner: ScopeOwner,
        cursor: &Cursor,
        pre_approval: bool,
        data: &ScopeData,
    ) -> Result<CursorPhase, TransportError> {
        let Cursor::Service(text) = cursor else {
            return Err(TransportError::CursorExpired);
        };
        let held = self.server.cursors().get(text).cloned();
        let Some(held) = held else {
            return Err(TransportError::CursorExpired);
        };
        let past_horizon = matches!(held.phase, CursorPhase::Delta { after } if after > data.horizon());
        let approved_since = held.pre_approval && !pre_approval;
        if held.owner != owner || held.epoch != state.epoch() || past_horizon || approved_since {
            return Err(TransportError::CursorExpired);
        }
        Ok(held.phase)
    }
}

struct Page {
    owner: ScopeOwner,
    epoch: tablepro_sync::api::ids::EpochId,
    pre_approval: bool,
    limit: usize,
}

impl Page {
    fn read(&self, server: &super::FakeServer, data: &ScopeData, phase: CursorPhase) -> PulledPage {
        let visible = |record: &&StoredRecord| !self.pre_approval || record.kind.is_key();
        match phase {
            CursorPhase::Snapshot { mark, after } => {
                let rest: Vec<&StoredRecord> = data
                    .records
                    .iter()
                    .filter(|(key, _)| after.as_ref().is_none_or(|after| *key > after))
                    .map(|(_, record)| record)
                    .filter(|record| record.revision <= mark)
                    .filter(visible)
                    .collect();
                if rest.is_empty() {
                    return self.read(server, data, CursorPhase::Delta { after: mark });
                }
                let taken = self.cap(rest);
                let last = taken
                    .last()
                    .map(|record| (record.kind.as_str().to_owned(), record.record_id.clone()));
                let next = CursorPhase::Snapshot { mark, after: last };
                self.page(server, &taken, Some(next), None, false)
            }
            CursorPhase::HistoryOlder { mark, before } => {
                let mut rest: Vec<&StoredRecord> = data
                    .records
                    .values()
                    .filter(|record| record.revision <= mark && record.revision < before)
                    .collect();
                rest.sort_by_key(|record| std::cmp::Reverse(record.revision));
                let taken = self.cap(rest);
                let older = taken.last().map(|record| CursorPhase::HistoryOlder {
                    mark,
                    before: record.revision,
                });
                let changes = CursorPhase::Delta { after: mark };
                self.page(server, &taken, older, Some(changes), false)
            }
            CursorPhase::Delta { after } => {
                let mut rest: Vec<&StoredRecord> = data
                    .records
                    .values()
                    .filter(|record| record.revision > after)
                    .filter(visible)
                    .collect();
                rest.sort_by_key(|record| record.revision);
                let taken = self.whole_sets(self.cap(rest.clone()), &rest, data);
                let caught_up = taken.is_empty();
                let last = taken.last().map_or(after, |record| record.revision);
                self.page(
                    server,
                    &taken,
                    Some(CursorPhase::Delta { after: last }),
                    None,
                    caught_up,
                )
            }
        }
    }

    // At most `limit` records or 4 MiB of fields, and always one.
    fn cap<'a>(&self, records: Vec<&'a StoredRecord>) -> Vec<&'a StoredRecord> {
        let mut bytes = 0;
        let mut taken = Vec::new();
        for record in records {
            let size = record.fields.as_ref().map_or(0, limits::encoded_len);
            if !taken.is_empty() && (taken.len() == self.limit || bytes + size > PAGE_BYTES) {
                break;
            }
            bytes += size;
            taken.push(record);
        }
        taken
    }

    // A page that holds a change set's first record holds its last, past the caps if it must.
    fn whole_sets<'a>(
        &self,
        mut taken: Vec<&'a StoredRecord>,
        rest: &[&'a StoredRecord],
        data: &ScopeData,
    ) -> Vec<&'a StoredRecord> {
        let Some(last) = taken.last().map(|record| record.revision) else {
            return taken;
        };
        let end = data
            .change_sets
            .iter()
            .find(|(first, end)| *first <= last && last < *end)
            .map(|(_, end)| *end);
        if let Some(end) = end {
            taken.extend(
                rest.iter()
                    .filter(|record| record.revision > last && record.revision <= end),
            );
        }
        taken
    }

    fn page(
        &self,
        server: &super::FakeServer,
        taken: &[&StoredRecord],
        next: Option<CursorPhase>,
        changes: Option<CursorPhase>,
        caught_up: bool,
    ) -> PulledPage {
        PulledPage {
            records: taken.iter().map(|record| pulled(record)).collect(),
            cursor: next.map(|phase| self.cursor(server, phase)),
            changes_cursor: changes.map(|phase| self.cursor(server, phase)),
            caught_up,
            unread: Vec::new(),
        }
    }

    fn cursor(&self, server: &super::FakeServer, phase: CursorPhase) -> Cursor {
        let text = Uuid::new_v4().simple().to_string();
        server.cursors().insert(
            text.clone(),
            CursorState {
                owner: self.owner,
                epoch: self.epoch,
                phase,
                pre_approval: self.pre_approval,
            },
        );
        Cursor::Service(text)
    }
}

fn pulled(record: &StoredRecord) -> PulledRecord {
    PulledRecord {
        kind: record.kind.clone(),
        record_id: record.record_id.clone(),
        tag: record.change_tag(),
        // `/v2/sync` sends no tombstone's fields.
        fields: if record.deleted.is_some() {
            None
        } else {
            record.fields.clone()
        },
        fields_json: if record.deleted.is_some() {
            None
        } else {
            record.fields.as_ref().map(Value::to_string)
        },
        deleted: record.deleted,
        service: Some(ServiceMeta {
            version: record.version,
            revision: record.revision,
            epoch: record.written_epoch,
            updated_at_us: record.updated_at_us,
            taken_at_us: record.taken_at_us,
            held_until_us: held_until(record),
            expires_at_us: expires_at(record),
            updated_by: record.updated_by.map(|account| account.to_wire()),
            updated_device: record.updated_device.clone(),
            updated_by_name: None,
        }),
    }
}
