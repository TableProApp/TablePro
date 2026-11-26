// Each row as its non-key columns in 0054's value encoding (Integrity and freshness): per value one byte, 0 for null
// and 1 otherwise, then for a present value a u32 big-endian length and its bytes. Text is UTF-8, an integer or flag
// 8 bytes big-endian, bytes as they are. The file stores a row as its encoded primary key and these columns, so a
// table's rows read back in the byte order its digest takes them, and a row's digest bytes are the two joined.

use serde_json::Value;
use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, Origin, RequestId, ResetId, TeamId, Version};
use tablepro_keys::keys::{Ed25519Public, X25519Public};
use tablepro_keys::sas::{Role as ComparisonRole, SessionState};
use tablepro_keys::trust::{PinHow, Replaced};
use uuid::Uuid;

use crate::api::error::StateError;
use crate::api::ids::{
    ChangeTag, Cursor, DeviceRowId, EpochId, FileId, IdempotencyKey, KindName, RecordKey, ScopeName,
};
use crate::api::scopes::{LineageEpoch, Role, ScopePolicies};
use crate::api::state::{
    ApprovalDecision, ApprovalRow, BaseRow, BindingRow, ConflictRow, DeferredRow, DeletedHistoryRow, HeldReason,
    HeldRow, Holder, KeyComparisonRow, KeyDevicePinRow, KeyEnvelopeRow, KeyObjectRow, KeyPendingRow, KeyPinRow,
    KeyVersionRow, KeyVersionState, LegacyMirrorRow, MovePhase, MoveRow, OutboxRow, PendingFlow, Provider, PushWait,
    RefusedRow, Row, ScopeRow, Served, Standing, StandingRow, StoppedCause, StoreRow, StoresKindRow, Table,
};
use crate::api::transport::{DeletedReason, PulledRecord, ServiceMeta};

fn malformed(what: &str) -> StateError {
    StateError::Io {
        detail: format!("the state file holds a malformed {what}"),
    }
}

#[derive(Default)]
pub(crate) struct Writer(Vec<u8>);

impl Writer {
    pub(crate) fn finish(self) -> Vec<u8> {
        self.0
    }

    fn null(&mut self) -> &mut Self {
        self.0.push(0);
        self
    }

    pub(crate) fn bytes(&mut self, bytes: &[u8]) -> &mut Self {
        self.0.push(1);
        let length = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
        self.0.extend_from_slice(&length.to_be_bytes());
        self.0.extend_from_slice(bytes);
        self
    }

    fn text(&mut self, text: &str) -> &mut Self {
        self.bytes(text.as_bytes())
    }

    fn int(&mut self, value: u64) -> &mut Self {
        self.bytes(&value.to_be_bytes())
    }

    fn signed(&mut self, value: i64) -> &mut Self {
        self.bytes(&value.to_be_bytes())
    }

    fn flag(&mut self, value: bool) -> &mut Self {
        self.int(u64::from(value))
    }

    fn maybe<T>(&mut self, value: Option<T>, write: impl FnOnce(&mut Self, T) -> &mut Self) -> &mut Self {
        match value {
            Some(value) => write(self, value),
            None => self.null(),
        }
    }

    fn json(&mut self, value: &Value) -> &mut Self {
        self.text(&value.to_string())
    }
}

pub(crate) struct Reader<'a> {
    rest: &'a [u8],
}

impl<'a> Reader<'a> {
    pub(crate) fn new(bytes: &'a [u8]) -> Self {
        Self { rest: bytes }
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8], StateError> {
        if self.rest.len() < count {
            return Err(malformed("value"));
        }
        let (taken, rest) = self.rest.split_at(count);
        self.rest = rest;
        Ok(taken)
    }

    fn value(&mut self) -> Result<Option<&'a [u8]>, StateError> {
        match self.take(1)? {
            [0] => Ok(None),
            [1] => {
                let length: [u8; 4] = self.take(4)?.try_into().map_err(|_| malformed("length"))?;
                let length = usize::try_from(u32::from_be_bytes(length)).map_err(|_| malformed("length"))?;
                self.take(length).map(Some)
            }
            _ => Err(malformed("value marker")),
        }
    }

    fn present(&mut self, what: &str) -> Result<&'a [u8], StateError> {
        self.value()?.ok_or_else(|| malformed(what))
    }

    pub(crate) fn end(&self) -> Result<(), StateError> {
        if self.rest.is_empty() {
            Ok(())
        } else {
            Err(malformed("row length"))
        }
    }

    fn maybe<T>(&mut self, read: impl FnOnce(&'a [u8]) -> Result<T, StateError>) -> Result<Option<T>, StateError> {
        self.value()?.map(read).transpose()
    }

    fn bytes(&mut self, what: &str) -> Result<Vec<u8>, StateError> {
        self.present(what).map(<[u8]>::to_vec)
    }

    fn text(&mut self, what: &str) -> Result<String, StateError> {
        text(self.present(what)?)
    }

    fn int(&mut self, what: &str) -> Result<u64, StateError> {
        int(self.present(what)?)
    }

    fn signed(&mut self, what: &str) -> Result<i64, StateError> {
        signed(self.present(what)?)
    }

    fn flag(&mut self, what: &str) -> Result<bool, StateError> {
        match self.int(what)? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(malformed(what)),
        }
    }

    fn fixed<const N: usize>(&mut self, what: &str) -> Result<[u8; N], StateError> {
        fixed(self.present(what)?)
    }
}

fn text(bytes: &[u8]) -> Result<String, StateError> {
    String::from_utf8(bytes.to_vec()).map_err(|_| malformed("text"))
}

fn int(bytes: &[u8]) -> Result<u64, StateError> {
    fixed::<8>(bytes).map(u64::from_be_bytes)
}

fn signed(bytes: &[u8]) -> Result<i64, StateError> {
    fixed::<8>(bytes).map(i64::from_be_bytes)
}

fn fixed<const N: usize>(bytes: &[u8]) -> Result<[u8; N], StateError> {
    bytes.try_into().map_err(|_| malformed("fixed-size value"))
}

fn uuid(bytes: &[u8]) -> Result<Uuid, StateError> {
    fixed::<16>(bytes).map(Uuid::from_bytes)
}

fn json(bytes: &[u8]) -> Result<Value, StateError> {
    serde_json::from_slice(bytes).map_err(|_| malformed("JSON"))
}

fn version(value: u64) -> Result<Version, StateError> {
    u32::try_from(value)
        .ok()
        .and_then(|value| Version::new(value).ok())
        .ok_or_else(|| malformed("key version"))
}

fn scope(bytes: &[u8]) -> Result<ScopeName, StateError> {
    ScopeName::parse(&text(bytes)?).map_err(|_| malformed("scope"))
}

fn kind(bytes: &[u8]) -> Result<KindName, StateError> {
    KindName::parse(&text(bytes)?).map_err(|_| malformed("kind"))
}

// A change tag or cursor: one byte saying whose, then its text or bytes.
fn tagged(service: Option<&str>, cloudkit: Option<&[u8]>) -> Vec<u8> {
    match (service, cloudkit) {
        (Some(text), _) => [&[1][..], text.as_bytes()].concat(),
        (None, Some(bytes)) => [&[2][..], bytes].concat(),
        (None, None) => Vec::new(),
    }
}

fn change_tag_bytes(tag: &ChangeTag) -> Vec<u8> {
    match tag {
        ChangeTag::Service(text) => tagged(Some(text), None),
        ChangeTag::CloudKit(bytes) => tagged(None, Some(bytes)),
    }
}

fn change_tag(bytes: &[u8]) -> Result<ChangeTag, StateError> {
    match bytes.split_first() {
        Some((1, rest)) => text(rest).map(ChangeTag::Service),
        Some((2, rest)) => Ok(ChangeTag::CloudKit(rest.to_vec())),
        _ => Err(malformed("change tag")),
    }
}

fn cursor_bytes(cursor: &Cursor) -> Vec<u8> {
    match cursor {
        Cursor::Service(text) => tagged(Some(text), None),
        Cursor::CloudKit(bytes) => tagged(None, Some(bytes)),
    }
}

fn cursor(bytes: &[u8]) -> Result<Cursor, StateError> {
    match bytes.split_first() {
        Some((1, rest)) => text(rest).map(Cursor::Service),
        Some((2, rest)) => Ok(Cursor::CloudKit(rest.to_vec())),
        _ => Err(malformed("cursor")),
    }
}

fn policies_bytes(policies: ScopePolicies) -> [u8; 3] {
    let switch = |value: Option<bool>| match value {
        None => 0,
        Some(false) => 1,
        Some(true) => 2,
    };
    [
        switch(policies.personal_sync),
        switch(policies.password_sync),
        switch(policies.history_sync),
    ]
}

fn policies(bytes: &[u8]) -> Result<ScopePolicies, StateError> {
    let switch = |byte: u8| match byte {
        0 => Ok(None),
        1 => Ok(Some(false)),
        2 => Ok(Some(true)),
        _ => Err(malformed("policy switch")),
    };
    let [personal, password, history] = fixed::<3>(bytes)?;
    Ok(ScopePolicies {
        personal_sync: switch(personal)?,
        password_sync: switch(password)?,
        history_sync: switch(history)?,
    })
}

// A `u32` count, then per epoch its 16-byte id and its kept revision.
fn lineage_bytes(lineage: &[LineageEpoch]) -> Vec<u8> {
    let mut out = u32::try_from(lineage.len()).unwrap_or(u32::MAX).to_be_bytes().to_vec();
    for epoch in lineage {
        out.extend_from_slice(epoch.id.0.as_bytes());
        out.extend_from_slice(&epoch.kept_revision.to_be_bytes());
    }
    out
}

fn counted<T>(bytes: &[u8], size: usize, read: impl Fn(&[u8]) -> Result<T, StateError>) -> Result<Vec<T>, StateError> {
    let (count, rest) = bytes.split_at_checked(4).ok_or_else(|| malformed("count"))?;
    let count = usize::try_from(u32::from_be_bytes(fixed(count)?)).map_err(|_| malformed("count"))?;
    if rest.len() != count.saturating_mul(size) {
        return Err(malformed("list length"));
    }
    rest.chunks_exact(size).map(read).collect()
}

fn lineage(bytes: &[u8]) -> Result<Vec<LineageEpoch>, StateError> {
    counted(bytes, 24, |chunk| {
        let (id, kept) = chunk.split_at(16);
        Ok(LineageEpoch {
            id: EpochId(uuid(id)?),
            kept_revision: int(kept)?,
        })
    })
}

// 0054, `key_versions`: a `u32` count, then per pair the 16-byte account id and the 32-byte IK.
fn holders_bytes(holders: &[Holder]) -> Vec<u8> {
    let mut out = u32::try_from(holders.len()).unwrap_or(u32::MAX).to_be_bytes().to_vec();
    for holder in holders {
        out.extend_from_slice(holder.account.0.as_bytes());
        out.extend_from_slice(&holder.ik.0);
    }
    out
}

fn holders(bytes: &[u8]) -> Result<Vec<Holder>, StateError> {
    counted(bytes, 48, |chunk| {
        let (account, ik) = chunk.split_at(16);
        Ok(Holder {
            account: AccountId(uuid(account)?),
            ik: Ed25519Public(fixed(ik)?),
        })
    })
}

fn provider_name(provider: Provider) -> &'static str {
    match provider {
        Provider::Service => "service",
        Provider::ICloud => "icloud",
    }
}

fn provider(text: &str) -> Result<Provider, StateError> {
    match text {
        "service" => Ok(Provider::Service),
        "icloud" => Ok(Provider::ICloud),
        _ => Err(malformed("provider")),
    }
}

fn deleted(text: &str) -> Result<DeletedReason, StateError> {
    match text {
        "user" => Ok(DeletedReason::User),
        "policy" => Ok(DeletedReason::Policy),
        _ => Err(malformed("deleted reason")),
    }
}

const MOVE_PHASES: [(MovePhase, &str); 2] = [(MovePhase::Open, "open"), (MovePhase::Done, "done")];

const STANDINGS: [(Standing, &str); 3] = [
    (Standing::Syncs, "syncs"),
    (Standing::LocalOnly, "local_only"),
    (Standing::Unknown, "unknown"),
];

const HELD_REASONS: [(HeldReason, &str); 4] = [
    (HeldReason::Unreadable, "unreadable"),
    (HeldReason::UnknownKind, "unknown_kind"),
    (HeldReason::AwaitingApproval, "awaiting_approval"),
    (HeldReason::AwaitingDeviceApproval, "awaiting_device_approval"),
];

const VERSION_STATES: [(KeyVersionState, &str); 3] = [
    (KeyVersionState::Ok, "ok"),
    (KeyVersionState::Stopped, "stopped"),
    (KeyVersionState::Ended, "ended"),
];

const SESSION_STATES: [(SessionState, &str); 7] = [
    (SessionState::Open, "open"),
    (SessionState::Chosen, "chosen"),
    (SessionState::Revealed, "revealed"),
    (SessionState::Compared, "compared"),
    (SessionState::Confirmed, "confirmed"),
    (SessionState::Cancelled, "cancelled"),
    (SessionState::Expired, "expired"),
];

const COMPARISON_ROLES: [(ComparisonRole, &str); 2] = [
    (ComparisonRole::NewDevice, "new_device"),
    (ComparisonRole::Approver, "approver"),
];

fn name_of<T: PartialEq + Copy>(table: &[(T, &'static str)], value: T) -> &'static str {
    table
        .iter()
        .find(|(held, _)| *held == value)
        .map_or("", |(_, name)| name)
}

fn named<T: Copy>(table: &[(T, &'static str)], text: &str, what: &str) -> Result<T, StateError> {
    table
        .iter()
        .find(|(_, name)| *name == text)
        .map(|(value, _)| *value)
        .ok_or_else(|| malformed(what))
}

fn pulled_bytes(record: &PulledRecord) -> Vec<u8> {
    let mut out = Writer::default();
    out.text(record.kind.as_str())
        .text(&record.record_id)
        .bytes(&change_tag_bytes(&record.tag))
        .maybe(record.fields.as_ref(), Writer::json)
        .maybe(record.fields_json.as_deref(), Writer::text)
        .maybe(record.deleted, |out, reason| out.text(reason.as_str()))
        .maybe(record.service.as_ref(), |out, meta| out.bytes(&meta_bytes(meta)));
    out.finish()
}

fn meta_bytes(meta: &ServiceMeta) -> Vec<u8> {
    let mut out = Writer::default();
    out.int(meta.version)
        .int(meta.revision)
        .bytes(meta.epoch.0.as_bytes())
        .signed(meta.updated_at_us)
        .signed(meta.taken_at_us)
        .maybe(meta.held_until_us, Writer::signed)
        .maybe(meta.expires_at_us, Writer::signed)
        .maybe(meta.updated_by.as_deref(), Writer::text)
        .maybe(meta.updated_device.as_ref(), |out, device| out.text(&device.0))
        .maybe(meta.updated_by_name.as_deref(), Writer::text);
    out.finish()
}

fn pulled(bytes: &[u8]) -> Result<PulledRecord, StateError> {
    let mut read = Reader::new(bytes);
    let record = PulledRecord {
        kind: kind(read.present("kind")?)?,
        record_id: read.text("record id")?,
        tag: change_tag(read.present("change tag")?)?,
        fields: read.maybe(json)?,
        fields_json: read.maybe(text)?,
        deleted: read.maybe(|bytes| deleted(&text(bytes)?))?,
        service: read.maybe(meta)?,
    };
    read.end()?;
    Ok(record)
}

fn meta(bytes: &[u8]) -> Result<ServiceMeta, StateError> {
    let mut read = Reader::new(bytes);
    let meta = ServiceMeta {
        version: read.int("version")?,
        revision: read.int("revision")?,
        epoch: EpochId(uuid(read.present("epoch")?)?),
        updated_at_us: read.signed("updated at")?,
        taken_at_us: read.signed("taken at")?,
        held_until_us: read.maybe(signed)?,
        expires_at_us: read.maybe(signed)?,
        updated_by: read.maybe(text)?,
        updated_device: read.maybe(|bytes| text(bytes).map(DeviceRowId))?,
        updated_by_name: read.maybe(text)?,
    };
    read.end()?;
    Ok(meta)
}

// The non-key columns of a row, in the order its table lists them.
pub(crate) fn columns(row: &Row) -> Vec<u8> {
    let mut out = Writer::default();
    match row {
        Row::Binding(row) => binding_columns(&mut out, row),
        Row::Scope(row) => scope_columns(&mut out, row),
        Row::Store(row) => {
            out.bytes(row.generation.as_bytes()).int(row.sequence);
        }
        Row::StoresKind(_) | Row::DeletedHistory(_) => {}
        Row::Base(row) | Row::PendingBase(row) => base_columns(&mut out, row),
        Row::Standing(row) => {
            out.text(name_of(&STANDINGS, row.standing));
        }
        Row::Held(row) => {
            out.text(name_of(&HELD_REASONS, row.reason))
                .bytes(&pulled_bytes(&row.record));
        }
        Row::Deferred(row) => {
            out.bytes(&pulled_bytes(&row.record));
        }
        Row::Outbox(row) => {
            out.text(&row.idempotency_key.0)
                .bytes(&row.request_digest)
                .signed(row.created_at_ms);
        }
        Row::Refused(row) => {
            out.bytes(&row.digest).text(&row.code);
        }
        Row::Approval(row) => approval_columns(&mut out, row),
        Row::Conflict(row) => {
            out.maybe(row.base.as_ref(), Writer::json)
                .maybe(row.mine.as_ref(), Writer::json)
                .maybe(row.theirs.as_ref(), Writer::json);
        }
        Row::LegacyMirror(row) => {
            out.bytes(&row.value);
        }
        Row::Move(row) => {
            out.maybe(row.from, |out, from| out.text(provider_name(from)))
                .text(provider_name(row.target))
                .text(name_of(&MOVE_PHASES, row.phase));
        }
        key_row => key_columns(&mut out, key_row),
    }
    out.finish()
}

fn binding_columns(out: &mut Writer, row: &BindingRow) {
    binding_sealed_columns(out, row);
    out.bytes(&row.state_mac);
}

fn binding_sealed_columns(out: &mut Writer, row: &BindingRow) {
    out.text(provider_name(row.provider))
        .maybe(row.origin.as_ref(), |out, origin| out.text(origin.as_str()))
        .text(&row.account)
        .text(&row.device)
        .int(u64::from(row.schema_version))
        .bytes(&row.file_id.0)
        .int(row.counter);
}

// The binding's columns as the sync digest takes them: without the state MAC, which is computed over that digest.
pub(crate) fn binding_digest_columns(row: &BindingRow) -> Vec<u8> {
    let mut out = Writer::default();
    binding_sealed_columns(&mut out, row);
    out.finish()
}

fn scope_columns(out: &mut Writer, row: &ScopeRow) {
    out.maybe(row.role, |out, role| out.text(role.as_str()))
        .maybe(row.epoch, |out, epoch| out.bytes(epoch.0.as_bytes()))
        .maybe(row.cursor.as_ref(), |out, cursor| out.bytes(&cursor_bytes(cursor)))
        .maybe(row.key_version, |out, version| out.int(u64::from(version.get())))
        .maybe(row.horizon, Writer::int)
        .bytes(&policies_bytes(row.policies))
        .bytes(&lineage_bytes(&row.lineage))
        .maybe(row.older_cursor.as_ref(), |out, cursor| {
            out.bytes(&cursor_bytes(cursor))
        })
        .bytes(&kinds_bytes(&row.read_kinds))
        .flag(row.refill)
        .flag(row.rotation_due)
        .flag(row.caught_up)
        .maybe(row.push_wait, |out, wait| out.bytes(&push_wait_bytes(wait)));
}

// The wait's name, then for an account choice the count of changes left unsent.
fn push_wait_bytes(wait: PushWait) -> Vec<u8> {
    let mut out = Writer::default();
    out.text(wait.name());
    if let PushWait::AccountChoice { unsent } = wait {
        out.int(unsent);
    }
    out.finish()
}

fn push_wait(bytes: &[u8]) -> Result<PushWait, StateError> {
    let mut read = Reader::new(bytes);
    let wait = match read.text("push wait")?.as_str() {
        "account_choice" => PushWait::AccountChoice {
            unsent: read.int("unsent changes")?,
        },
        "upload_again" => PushWait::UploadAgain,
        _ => return Err(malformed("push wait")),
    };
    read.end()?;
    Ok(wait)
}

fn base_columns(out: &mut Writer, row: &BaseRow) {
    out.bytes(&change_tag_bytes(&row.tag))
        .maybe(row.version, Writer::int)
        .maybe(row.revision, Writer::int)
        .maybe(row.epoch, |out, epoch| out.bytes(epoch.0.as_bytes()))
        .maybe(row.deleted, |out, reason| out.text(reason.as_str()))
        .maybe(row.fields.as_ref(), Writer::json)
        .maybe(row.created_ms, Writer::signed);
}

// Each kind name as its length and its text, in the row's order.
fn kinds_bytes(kinds: &[KindName]) -> Vec<u8> {
    let mut out = Writer::default();
    for kind in kinds {
        out.text(kind.as_str());
    }
    out.finish()
}

fn kinds(bytes: &[u8]) -> Result<Vec<KindName>, StateError> {
    let mut read = Reader::new(bytes);
    let mut out = Vec::new();
    while !read.rest.is_empty() {
        out.push(kind(read.present("read kind")?)?);
    }
    Ok(out)
}

fn approval_columns(out: &mut Writer, row: &ApprovalRow) {
    out.json(&row.pulled);
    match &row.decision {
        ApprovalDecision::Waiting => out.text("waiting").null(),
        ApprovalDecision::Approved => out.text("approved").null(),
        ApprovalDecision::Rejected { local } => out.text("rejected").json(local),
    };
}

fn key_columns(out: &mut Writer, row: &Row) {
    match row {
        Row::KeyObject(row) => {
            out.text(&row.fields)
                .flag(row.applied)
                .maybe(row.served, |out, served| out.bytes(&served_bytes(served)));
        }
        Row::KeyPin(row) => {
            let replaced: Vec<u8> = row
                .replaced
                .iter()
                .flat_map(|entry| [&entry.ik.0[..], &entry.av.get().to_be_bytes()].concat())
                .collect();
            out.bytes(&row.ik.0)
                .int(u64::from(row.av.get()))
                .text(row.how.name())
                .flag(row.alert)
                .bytes(&replaced);
        }
        Row::KeyDevicePin(row) => {
            out.bytes(&row.dek.0).bytes(&row.dsk.0);
        }
        Row::KeyVersion(row) => {
            out.int(u64::from(row.version.get()))
                .bytes(&row.record)
                .bytes(&holders_bytes(&row.holders))
                .text(row.state.as_str())
                .maybe(row.stopped_cause, |out, cause| out.text(cause.as_str()))
                .maybe(row.epoch, |out, epoch| out.bytes(epoch.0.as_bytes()));
        }
        Row::KeyEnvelope(row) => {
            out.int(u64::from(row.kv.get()));
        }
        Row::KeyComparison(row) => {
            out.text(name_of(&COMPARISON_ROLES, row.role))
                .bytes(&row.peer)
                .bytes(&row.view)
                .text(name_of(&SESSION_STATES, row.state))
                .signed(row.expires_at_us);
        }
        Row::KeyPending(row) => {
            out.bytes(&row.state);
        }
        _ => {}
    }
}

// 0066, `key_objects.served`: `taken_at`, then on a `key.reset` `held_until`, 8 bytes big-endian each.
fn served_bytes(served: Served) -> Vec<u8> {
    let mut out = served.taken_at_us.to_be_bytes().to_vec();
    if let Some(held_until) = served.held_until_us {
        out.extend_from_slice(&held_until.to_be_bytes());
    }
    out
}

fn served(bytes: &[u8]) -> Result<Served, StateError> {
    match bytes.len() {
        8 => Ok(Served {
            taken_at_us: signed(bytes)?,
            held_until_us: None,
        }),
        16 => {
            let (taken_at, held_until) = bytes.split_at(8);
            Ok(Served {
                taken_at_us: signed(taken_at)?,
                held_until_us: Some(signed(held_until)?),
            })
        }
        _ => Err(malformed("served times")),
    }
}

// Schema 1 kept no replace point, and the replace certificate that sets one is not in the pin (0066, Replace points).
// At 1 no certificate under the IK verifies as history, which refuses rather than guesses.
const SCHEMA_1_REPLACE_POINT: u32 = 1;

// A row's columns as schema 1 stored them, in this schema's encoding: a scope and a key object end in a null
// `push_wait` and `served`, and each replaced IK of a pin gains its replace point.
pub(crate) fn schema_1_columns(table: Table, columns: &[u8]) -> Result<Vec<u8>, StateError> {
    match table {
        Table::Scopes | Table::KeyObjects => {
            let mut out = Writer(columns.to_vec());
            out.null();
            Ok(out.finish())
        }
        Table::KeyPins => {
            let mut read = Reader::new(columns);
            for what in ["IK", "av", "pin how", "alert"] {
                read.present(what)?;
            }
            let kept = columns.len() - read.rest.len();
            let replaced = read.bytes("replaced")?;
            read.end()?;
            let (chunks, rest) = replaced.as_chunks::<32>();
            if !rest.is_empty() {
                return Err(malformed("replaced IKs"));
            }
            let entries: Vec<u8> = chunks
                .iter()
                .flat_map(|ik| [&ik[..], &SCHEMA_1_REPLACE_POINT.to_be_bytes()].concat())
                .collect();
            let mut out = Writer(columns[..kept].to_vec());
            out.bytes(&entries);
            Ok(out.finish())
        }
        _ => Ok(columns.to_vec()),
    }
}

// The row a table's stored key and columns hold.
pub(crate) fn decode(table: Table, key: &[u8], columns: &[u8]) -> Result<Row, StateError> {
    let mut keys = Reader::new(key);
    let mut read = Reader::new(columns);
    let row = match table {
        Table::Binding => Row::Binding(binding(&mut read)?),
        Table::Scopes => Row::Scope(scope_row(scope(keys.present("scope")?)?, &mut read)?),
        Table::Stores => Row::Store(StoreRow {
            store: keys.text("store")?,
            generation: uuid(read.present("generation")?)?,
            sequence: read.int("sequence")?,
        }),
        Table::StoresKinds => Row::StoresKind(StoresKindRow {
            store: keys.text("store")?,
            kind: kind(keys.present("kind")?)?,
        }),
        Table::Bases => Row::Base(base_row(record_key(&mut keys)?, &mut read)?),
        Table::PendingBases => Row::PendingBase(base_row(record_key(&mut keys)?, &mut read)?),
        Table::Standing => Row::Standing(StandingRow {
            key: record_key(&mut keys)?,
            standing: named(&STANDINGS, &read.text("standing")?, "standing")?,
        }),
        Table::Held => Row::Held(HeldRow {
            key: record_key(&mut keys)?,
            reason: named(&HELD_REASONS, &read.text("held reason")?, "held reason")?,
            record: pulled(read.present("held record")?)?,
        }),
        Table::Deferred => Row::Deferred(DeferredRow {
            key: record_key(&mut keys)?,
            record: pulled(read.present("deferred record")?)?,
        }),
        Table::Outbox => Row::Outbox(OutboxRow {
            scope: scope(keys.present("scope")?)?,
            idempotency_key: IdempotencyKey(read.text("idempotency key")?),
            request_digest: read.fixed("request digest")?,
            created_at_ms: read.signed("created at")?,
        }),
        Table::Refused => Row::Refused(RefusedRow {
            key: record_key(&mut keys)?,
            digest: read.fixed("refused digest")?,
            code: read.text("refused code")?,
        }),
        Table::Approvals => Row::Approval(approval_row(record_key(&mut keys)?, keys.text("field")?, &mut read)?),
        Table::Conflicts => Row::Conflict(ConflictRow {
            key: record_key(&mut keys)?,
            base: read.maybe(json)?,
            mine: read.maybe(json)?,
            theirs: read.maybe(json)?,
        }),
        Table::LegacyMirror => Row::LegacyMirror(LegacyMirrorRow {
            item: keys.text("item")?,
            value: read.bytes("value")?,
        }),
        Table::Moves => Row::Move(MoveRow {
            from: read.maybe(|bytes| provider(&text(bytes)?))?,
            target: provider(&read.text("move target")?)?,
            phase: named(&MOVE_PHASES, &read.text("move phase")?, "move phase")?,
        }),
        key_table => key_row(key_table, &mut keys, &mut read)?,
    };
    keys.end()?;
    read.end()?;
    Ok(row)
}

fn record_key(keys: &mut Reader<'_>) -> Result<RecordKey, StateError> {
    Ok(RecordKey {
        scope: scope(keys.present("scope")?)?,
        kind: kind(keys.present("kind")?)?,
        record_id: keys.text("record id")?,
    })
}

fn binding(read: &mut Reader<'_>) -> Result<BindingRow, StateError> {
    Ok(BindingRow {
        provider: provider(&read.text("provider")?)?,
        origin: read.maybe(|bytes| Origin::parse(&text(bytes)?).map_err(|_| malformed("origin")))?,
        account: read.text("account")?,
        device: read.text("device")?,
        schema_version: u32::try_from(read.int("schema version")?).map_err(|_| malformed("schema version"))?,
        file_id: FileId(read.fixed("file id")?),
        counter: read.int("counter")?,
        state_mac: read.fixed("state MAC")?,
    })
}

fn scope_row(scope: ScopeName, read: &mut Reader<'_>) -> Result<ScopeRow, StateError> {
    Ok(ScopeRow {
        scope,
        role: read.maybe(|bytes| Role::parse(&text(bytes)?).ok_or_else(|| malformed("role")))?,
        epoch: read.maybe(|bytes| uuid(bytes).map(EpochId))?,
        cursor: read.maybe(cursor)?,
        key_version: read.maybe(|bytes| version(int(bytes)?))?,
        horizon: read.maybe(int)?,
        policies: policies(read.present("policies")?)?,
        lineage: lineage(read.present("lineage")?)?,
        older_cursor: read.maybe(cursor)?,
        read_kinds: kinds(read.present("read kinds")?)?,
        refill: read.flag("refill")?,
        rotation_due: read.flag("rotation due")?,
        caught_up: read.flag("caught up")?,
        push_wait: read.maybe(push_wait)?,
    })
}

fn base_row(key: RecordKey, read: &mut Reader<'_>) -> Result<BaseRow, StateError> {
    Ok(BaseRow {
        key,
        tag: change_tag(read.present("change tag")?)?,
        version: read.maybe(int)?,
        revision: read.maybe(int)?,
        epoch: read.maybe(|bytes| uuid(bytes).map(EpochId))?,
        deleted: read.maybe(|bytes| deleted(&text(bytes)?))?,
        fields: read.maybe(json)?,
        created_ms: read.maybe(signed)?,
    })
}

fn approval_row(key: RecordKey, field: String, read: &mut Reader<'_>) -> Result<ApprovalRow, StateError> {
    let pulled = json(read.present("pulled value")?)?;
    let decision = match (read.text("decision")?.as_str(), read.maybe(json)?) {
        ("waiting", None) => ApprovalDecision::Waiting,
        ("approved", None) => ApprovalDecision::Approved,
        ("rejected", Some(local)) => ApprovalDecision::Rejected { local },
        _ => return Err(malformed("approval decision")),
    };
    Ok(ApprovalRow {
        key,
        field,
        pulled,
        decision,
    })
}

fn key_row(table: Table, keys: &mut Reader<'_>, read: &mut Reader<'_>) -> Result<Row, StateError> {
    Ok(match table {
        Table::KeyObjects => Row::KeyObject(KeyObjectRow {
            scope: scope(keys.present("scope")?)?,
            kind: kind(keys.present("kind")?)?,
            record_id: keys.text("record id")?,
            fields: read.text("fields")?,
            applied: read.flag("applied")?,
            served: read.maybe(served)?,
        }),
        Table::KeyPins => Row::KeyPin(pin_row(AccountId(uuid(keys.present("account")?)?), read)?),
        Table::KeyDevicePins => Row::KeyDevicePin(KeyDevicePinRow {
            key_device: KeyDeviceId(uuid(keys.present("key device")?)?),
            dek: X25519Public(read.fixed("DEK")?),
            dsk: Ed25519Public(read.fixed("DSK")?),
        }),
        Table::KeyVersions => Row::KeyVersion(version_row(keys, read)?),
        Table::KeyEnvelopes => Row::KeyEnvelope(KeyEnvelopeRow {
            scope: scope(keys.present("scope")?)?,
            record_id: keys.text("record id")?,
            kv: version(read.int("kv")?)?,
        }),
        Table::KeyComparisons => Row::KeyComparison(KeyComparisonRow {
            session: RequestId(uuid(keys.present("session")?)?),
            role: named(&COMPARISON_ROLES, &read.text("role")?, "comparison role")?,
            peer: read.bytes("peer")?,
            view: read.bytes("view")?,
            state: named(&SESSION_STATES, &read.text("session state")?, "session state")?,
            expires_at_us: read.signed("expires at")?,
        }),
        Table::KeyPending => Row::KeyPending(KeyPendingRow {
            flow: pending_flow(&keys.text("flow")?)?,
            state: read.bytes("flow state")?,
        }),
        Table::DeletedHistory => Row::DeletedHistory(DeletedHistoryRow {
            record_id: keys.text("record id")?,
        }),
        _ => return Err(malformed("table")),
    })
}

fn pin_row(account: AccountId, read: &mut Reader<'_>) -> Result<KeyPinRow, StateError> {
    let ik = Ed25519Public(read.fixed("IK")?);
    let av = version(read.int("av")?)?;
    let how = PinHow::parse(&read.text("pin how")?).map_err(|_| malformed("pin how"))?;
    let alert = read.flag("alert")?;
    let replaced = read.bytes("replaced")?;
    // 0066: per entry the IK's 32 bytes, then the replace `av` as a `u32` big-endian.
    let (chunks, rest) = replaced.as_chunks::<36>();
    if !rest.is_empty() {
        return Err(malformed("replaced IKs"));
    }
    let replaced = chunks
        .iter()
        .map(|chunk| {
            let (ik, av) = chunk.split_at(32);
            Ok(Replaced {
                ik: Ed25519Public(fixed(ik)?),
                av: version(u64::from(u32::from_be_bytes(fixed(av)?)))?,
            })
        })
        .collect::<Result<_, StateError>>()?;
    Ok(KeyPinRow {
        account,
        ik,
        av,
        how,
        alert,
        replaced,
    })
}

fn version_row(keys: &mut Reader<'_>, read: &mut Reader<'_>) -> Result<KeyVersionRow, StateError> {
    Ok(KeyVersionRow {
        scope: scope(keys.present("scope")?)?,
        purpose: KeyPurpose::parse(&keys.text("purpose")?).map_err(|_| malformed("key purpose"))?,
        version: version(read.int("version")?)?,
        record: read.fixed("version record digest")?,
        holders: holders(read.present("holders")?)?,
        state: named(&VERSION_STATES, &read.text("version state")?, "version state")?,
        stopped_cause: read
            .maybe(|bytes| StoppedCause::parse(&text(bytes)?).ok_or_else(|| malformed("stopped cause")))?,
        epoch: read.maybe(|bytes| uuid(bytes).map(EpochId))?,
    })
}

// The inverse of `PendingFlow::key_text`.
fn pending_flow(text: &str) -> Result<PendingFlow, StateError> {
    let (name, value) = text.split_once('/').ok_or_else(|| malformed("pending flow"))?;
    let bad = |_| malformed("pending flow");
    Ok(match name {
        "rotation" => PendingFlow::AccountRotation {
            av: version(value.parse::<u64>().map_err(|_| malformed("pending flow"))?)?,
        },
        "approval" => PendingFlow::Approval {
            request: RequestId::from_wire(value).map_err(bad)?,
        },
        "reset" => PendingFlow::ResetProposal {
            reset: ResetId::from_wire(value).map_err(bad)?,
        },
        "withdraw" => PendingFlow::StopWithdrawal {
            team: TeamId::from_wire(value).map_err(bad)?,
        },
        _ => return Err(malformed("pending flow")),
    })
}
