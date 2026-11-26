// Team envelopes (0056, Envelopes and history; Rollback, In order): sealed only under the version the device advanced
// to, by a holder of it, never while the team is due a rotation; opened under a version up to that one, never below the
// version in force at its place in the order or below the copy held. "Credentials to rotate" lists the envelopes an
// account that no longer holds the key could read (0056, Teams, Old data).

use std::collections::BTreeSet;

use secrecy::{ExposeSecret, SecretString};
use serde_json::Value;
use tablepro_keys::KeysError;
use tablepro_keys::body::{parse_sealed, sealed_json};
use tablepro_keys::check::check_not_below;
use tablepro_keys::encoding::{AccountId, Scope, TeamId, Version};
use tablepro_keys::envelope::{EnvelopeId, ParentKind, open_envelope, seal_envelope};
use tablepro_keys::json;
use tablepro_keys::wrap::Recipient;

use super::book::TeamBook;
use super::facts::TeamFacts;
use super::roster::holder_accounts;
use super::secrets;
use super::service_facts::{FactsCache, ServiceFacts};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{OpenedEnvelope, Roster};
use crate::api::scopes::Role;
use crate::api::state::{KeyEnvelopeRow, KeyVersionState, Row, RowKey, RowRange, StateTxn, Table};
use crate::api::transport::RejectedCode;
use crate::keys::KeyService;

fn team_envelope(envelope: &EnvelopeId) -> Result<(), SyncError> {
    if envelope.parent_kind == ParentKind::LibraryConnection {
        Ok(())
    } else {
        Err(KeysError::Encoding {
            what: "a team envelope belongs to a library connection",
        }
        .into())
    }
}

fn to_json(value: &Value) -> Result<json::JsonValue, SyncError> {
    let text = serde_json::to_vec(value).map_err(|_| SyncError::Malformed { what: "JSON value" })?;
    Ok(json::parse(&text)?)
}

fn from_json(value: &json::JsonValue) -> Result<Value, SyncError> {
    serde_json::from_str(&value.to_json()).map_err(|_| SyncError::Malformed { what: "JSON value" })
}

async fn held_kv(
    txn: &mut dyn StateTxn,
    scope: ScopeName,
    envelope: &EnvelopeId,
) -> Result<Option<Version>, SyncError> {
    Ok(match txn.get(&RowKey::KeyEnvelope(scope, envelope.to_wire())).await? {
        Some(Row::KeyEnvelope(row)) => Some(row.kv),
        _ => None,
    })
}

async fn keep_kv(
    txn: &mut dyn StateTxn,
    scope: ScopeName,
    envelope: &EnvelopeId,
    kv: Version,
) -> Result<(), SyncError> {
    if held_kv(txn, scope, envelope).await?.is_some_and(|held| held >= kv) {
        return Ok(());
    }
    txn.put(Row::KeyEnvelope(KeyEnvelopeRow {
        scope,
        record_id: envelope.to_wire(),
        kv,
    }))
    .await?;
    Ok(())
}

// An envelope in order counts only under the version in force at its place; one in a snapshot under any version the
// device holds. Neither is taken below the copy held (0056, Rollback, In order, Snapshots, Per envelope).
pub(crate) fn check_open_kv(
    kv: Version,
    in_force: Option<Version>,
    newest: Version,
    held: Option<Version>,
) -> Result<(), SyncError> {
    if let Some(in_force) = in_force {
        check_not_below(in_force, kv)?;
    }
    if kv > in_force.unwrap_or(newest).min(newest) {
        return Err(SyncError::NotAllowed {
            what: "open a team secret under a version this device has not taken",
        });
    }
    if let Some(held) = held {
        check_not_below(held, kv)?;
    }
    Ok(())
}

// While the team is due a rotation the engine holds new team envelopes in its queue, and a plain member writes none
// (0051, Teams, `rotation_due`; Roles in a team scope).
pub(crate) fn check_may_seal(roster: Option<&Roster>, scope_due: bool) -> Result<(), SyncError> {
    if scope_due || roster.is_some_and(|roster| roster.rotation_due) {
        return Err(SyncError::Rejected {
            code: RejectedCode::RotationDue,
        });
    }
    if roster.and_then(|roster| roster.role) == Some(Role::Member) {
        return Err(SyncError::Rejected {
            code: RejectedCode::Role,
        });
    }
    Ok(())
}

impl KeyService {
    pub(super) async fn seal_team(
        &self,
        team: TeamId,
        envelope: &EnvelopeId,
        secret: &SecretString,
        dest: &Value,
    ) -> Result<Value, SyncError> {
        team_envelope(envelope)?;
        self.may_handle_secrets()?;
        let scope = ScopeName::Team(team);
        let mut txn = self.begin().await?;
        if self.own_account(&mut *txn).await?.is_none() {
            return Err(SyncError::NotAllowed {
                what: "seal a team secret before this device holds the account's keys",
            });
        }
        let due = self.scope_row(&mut *txn, scope).await?.rotation_due;
        check_may_seal(self.current_roster(&mut *txn, team).await?.as_ref(), due)?;
        let book = self.load_team(&mut *txn, team).await?;
        book.check_anchor()?;
        let Some(row) = book.row().filter(|row| row.state == KeyVersionState::Ok).cloned() else {
            return Err(SyncError::NotAllowed {
                what: "seal under a team key this device does not hold as current",
            });
        };
        let mut cache = FactsCache::default();
        let mut facts = ServiceFacts {
            service: self,
            txn: &mut *txn,
            scope,
            cache: &mut cache,
        };
        // A member not yet confirmed holds no key to seal with (0056, What the server stores and checks).
        if !book.own_holds(&mut facts).await? {
            return Err(SyncError::Rejected {
                code: RejectedCode::Role,
            });
        }
        let key = secrets::team_key(self, team, &book, &mut facts, row.version, row.version).await?;
        let sealed = seal_envelope(
            &key,
            self.origin(),
            Scope::Team(team),
            envelope,
            row.version,
            secret.expose_secret(),
            &to_json(dest)?,
        )?;
        // The copy this device holds is the server's: the `kv` it keeps moves when the pushed envelope comes back in a
        // pull, so a push the server refuses leaves the copy it holds openable.
        serde_json::from_str(&sealed_json(&sealed)).map_err(|_| SyncError::Malformed { what: "envelope" })
    }

    pub(super) async fn open_team(
        &self,
        team: TeamId,
        envelope: &EnvelopeId,
        fields: &Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        team_envelope(envelope)?;
        self.may_handle_secrets()?;
        let scope = ScopeName::Team(team);
        let text = serde_json::to_vec(fields).map_err(|_| SyncError::Malformed { what: "envelope" })?;
        let sealed = parse_sealed(&text)?;
        let mut txn = self.begin().await?;
        let book = self.load_team(&mut *txn, team).await?;
        book.check_anchor()?;
        let newest = book.row().map(|row| row.version).ok_or(SyncError::NotAllowed {
            what: "open a team secret before this device holds the team key",
        })?;
        // In order, an envelope counts only under the version in force at its place; a snapshot's may come under any
        // version the device holds (0056, Rollback, In order and Snapshots).
        check_open_kv(sealed.kv, in_force, newest, held_kv(&mut *txn, scope, envelope).await?)?;
        let mut cache = FactsCache::default();
        let mut facts = ServiceFacts {
            service: self,
            txn: &mut *txn,
            scope,
            cache: &mut cache,
        };
        let key = secrets::team_key(self, team, &book, &mut facts, sealed.kv, newest).await?;
        let opened = open_envelope(&key, self.origin(), Scope::Team(team), envelope, &sealed)?;
        keep_kv(&mut *txn, scope, envelope, sealed.kv).await?;
        txn.commit().await?;
        Ok(OpenedEnvelope {
            secret: opened.secret,
            dest: from_json(&opened.dest)?,
            kv: sealed.kv,
        })
    }

    // Every envelope held under a version a removed party could read, a reader of version w reading every version up
    // to w through the rings. A removed party is an account that no longer holds the team key, or the devices an
    // account left behind when its `av` moved past the one a wrap names, as a device removal does (0056, Teams, Old
    // data). A replace moves the `av` too, so the list can hold more than a removal exposed, never less.
    pub(super) async fn readable_by_removed(&self, scope: ScopeName) -> Result<Vec<EnvelopeId>, SyncError> {
        let ScopeName::Team(team) = scope else {
            return Err(SyncError::NotAllowed {
                what: "list credentials to rotate outside a team",
            });
        };
        let mut txn = self.begin().await?;
        let book = self.load_team(&mut *txn, team).await?;
        let Some(row) = book.row().cloned() else {
            return Ok(Vec::new());
        };
        let current = holder_accounts(&row.holders);
        let mut cache = FactsCache::default();
        let mut facts = ServiceFacts {
            service: self,
            txn: &mut *txn,
            scope,
            cache: &mut cache,
        };
        let versions: Vec<Version> = book
            .versions()
            .map(|record| record.key.version)
            .filter(|version| *version <= row.version)
            .collect();
        let mut limit = None;
        for version in versions {
            if read_by_removed(&book, &mut facts, &current, version).await? {
                limit = limit.max(Some(version));
            }
        }
        let Some(limit) = limit else {
            return Ok(Vec::new());
        };
        let held = txn.scan(&RowRange::Scope(Table::KeyEnvelopes, scope)).await?;
        Ok(held
            .iter()
            .filter_map(|row| match row {
                Row::KeyEnvelope(row) if row.kv <= limit => EnvelopeId::parse(&row.record_id).ok(),
                _ => None,
            })
            .collect())
    }
}

async fn read_by_removed(
    book: &TeamBook,
    facts: &mut dyn TeamFacts,
    current: &BTreeSet<AccountId>,
    version: Version,
) -> Result<bool, SyncError> {
    let mut readers: Vec<(AccountId, Version)> = book
        .wraps_of(version)
        .filter_map(|wrap| match wrap.target.recipient {
            Recipient::Account(account) => Some((account, wrap.target.recipient_version)),
            Recipient::Device(_) => None,
        })
        .collect();
    if let Some(record) = book.version_record(version) {
        readers.push((record.signer, record.signer_av));
    }
    for (account, av) in readers {
        // Any certificate the team holds counts, whatever its IK, so a reset still under an open alert shows too.
        let newest = facts
            .chain(account)
            .await?
            .iter()
            .map(|certificate| certificate.av)
            .max();
        if !current.contains(&account) || newest.is_some_and(|newest| av < newest) {
            return Ok(true);
        }
    }
    Ok(false)
}
