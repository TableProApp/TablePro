// A team connection's secrets as team envelopes (0056, Envelopes and history; 0079): sealed under the team key when a
// publish names them, kept sealed in the Team Library store beside the copy they belong to, sent and pulled as the
// engine sends and pulls any record, and opened only when the app asks for them, for the destination the store's copy
// names then. Nothing plaintext is written anywhere.

use std::collections::{HashMap, HashSet};

use secrecy::ExposeSecret;
use serde_json::Value;
use tablepro_keys::encoding::{TeamId, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_records::Kind;
use tablepro_records::envelope::{SecretKind, destination};
use tablepro_records::record_id::{library_ids_match, parse_envelope_id};
use tablepro_storage::{TeamLibraryEnvelope, TeamLibraryKind};

use super::super::scopes::kind_off;
use super::super::{ServiceSync, begin};
use crate::adapters::envelopes::team_envelope_of;
use crate::api::error::SyncError;
use crate::api::ids::{KindName, ScopeName};
use crate::api::scopes::{Role, ScopeInfo};
use crate::api::state::{Row, RowKey, RowRange, Table};
use crate::api::team_library::{SecretsLeftOut, TeamSecret};
use crate::api::transport::RejectedCode;

// A connection a publish carries secrets for: the id the team stores it under, the fields it goes up with, and every
// secret it signs in with.
pub(super) struct SecretTarget {
    pub(super) id: String,
    pub(super) fields: Value,
    pub(super) secrets: Vec<TeamSecret>,
}

// What a publish writes of the team's envelopes, and why it left its connections' secrets out, when it did.
#[derive(Debug, Default)]
pub(super) struct EnvelopeWrites {
    puts: Vec<TeamLibraryEnvelope>,
    removes: Vec<String>,
    pub(super) left_out: Option<SecretsLeftOut>,
}

impl EnvelopeWrites {
    pub(super) fn is_empty(&self) -> bool {
        self.puts.is_empty() && self.removes.is_empty()
    }

    pub(super) fn count(&self) -> usize {
        self.puts.len() + self.removes.len()
    }
}

// Whether the copy uses the secret at all: the SSH ones only through a tunnel that is on, the key passphrases only for a
// key file the copy names, and the TOTP secret only when it asks for a code. A driver's own fields have no store here.
fn applies(kind: &SecretKind, fields: &Value) -> bool {
    let ssh = fields
        .get("sshConfig")
        .filter(|ssh| ssh.get("enabled") == Some(&Value::Bool(true)));
    let names = |within: Option<&Value>, member: &str| {
        within
            .and_then(|within| within.get(member))
            .and_then(Value::as_str)
            .is_some_and(|text| !text.trim().is_empty())
    };
    match kind {
        SecretKind::Password => true,
        SecretKind::SslKeyPassphrase => names(fields.get("sslConfig"), "clientKeyPath"),
        SecretKind::SshPassword => ssh.is_some(),
        SecretKind::SshKeyPassphrase => names(ssh, "privateKeyPath"),
        SecretKind::SshTotpSecret => ssh
            .and_then(|ssh| ssh.get("totpMode"))
            .and_then(Value::as_str)
            .is_some_and(|mode| mode != "none"),
        SecretKind::Plugin(_) | SecretKind::AiKey(_) => false,
    }
}

// The connection a held envelope belongs to and the secret it holds, for a team connection's envelope only.
fn parent_of(envelope: &TeamLibraryEnvelope) -> Option<(&str, SecretKind)> {
    match parse_envelope_id(&envelope.id) {
        Some((Kind::LibraryConnection, parent, kind)) => Some((parent, kind)),
        _ => None,
    }
}

// Why a seal was refused, as the publish reports it; anything that is not about the keys fails the publish.
fn left_out(error: SyncError, role: Option<Role>) -> Result<SecretsLeftOut, SyncError> {
    match error {
        SyncError::Rejected {
            code: RejectedCode::RotationDue,
        } => Ok(SecretsLeftOut::RotationDue),
        SyncError::Rejected {
            code: RejectedCode::Role,
        } if role == Some(Role::Member) => Ok(SecretsLeftOut::Role),
        SyncError::Rejected {
            code: RejectedCode::Role,
        }
        | SyncError::NotAllowed { .. }
        | SyncError::Locked { .. }
        | SyncError::Keys(_)
        | SyncError::Unimplemented { .. } => Ok(SecretsLeftOut::NotConfirmed),
        error => Err(error),
    }
}

impl ServiceSync {
    async fn team_envelopes(&self, scope: ScopeName) -> Result<Vec<TeamLibraryEnvelope>, SyncError> {
        let team = scope.wire();
        let held = self.store_call(move |store| store.team_blocking(&team)).await?;
        Ok(held.map(|team| team.envelopes).unwrap_or_default())
    }

    // The copy a publish seals again, or the one it keeps: one that still opens to the same secret sealed for the same
    // destination under the version written now stays, so publishing twice sends nothing the second time.
    async fn still_opens(
        &self,
        team: TeamId,
        envelope: &EnvelopeId,
        held: &Value,
        secret: &TeamSecret,
        dest: &Value,
        version: Version,
    ) -> bool {
        match self
            .keys
            .open_held_team_envelope(team, envelope.clone(), held.clone())
            .await
        {
            Ok(opened) => {
                opened.kv == version
                    && opened.dest == *dest
                    && opened.secret.expose_secret() == secret.value.expose_secret()
            }
            Err(error) => {
                tracing::debug!(code = error.code(), "a held team envelope did not open to compare");
                false
            }
        }
    }

    // A removed connection's envelopes go with it. A connection whose secrets the publish names gets one sealed copy
    // per secret it uses and loses the rest, unless the team's or this device's password sync is off or this device
    // cannot seal: then no envelope of any connection changes, and the publish says why.
    pub(super) async fn envelope_writes(
        &self,
        scope: ScopeName,
        info: &ScopeInfo,
        targets: Vec<SecretTarget>,
        removed: &[String],
    ) -> Result<EnvelopeWrites, SyncError> {
        let ScopeName::Team(team) = scope else {
            return Ok(EnvelopeWrites::default());
        };
        if targets.is_empty() && removed.is_empty() {
            return Ok(EnvelopeWrites::default());
        }
        let held = self.team_envelopes(scope).await?;
        let of = |connection: &str| -> Vec<&TeamLibraryEnvelope> {
            held.iter()
                .filter(|envelope| parent_of(envelope).is_some_and(|(parent, _)| library_ids_match(parent, connection)))
                .collect()
        };
        let mut writes = EnvelopeWrites::default();
        for connection in removed {
            writes
                .removes
                .extend(of(connection).into_iter().map(|envelope| envelope.id.clone()));
        }
        if targets.is_empty() {
            return Ok(writes);
        }
        if kind_off(info.policies, scope, Kind::SecretEnvelope) || !self.categories().syncs(Kind::SecretEnvelope) {
            writes.left_out = Some(SecretsLeftOut::PasswordsOff);
            return Ok(writes);
        }
        let version = match self.keys.team_writing_version(team).await {
            Ok(version) => version,
            Err(error) => {
                writes.left_out = Some(left_out(error, info.role)?);
                return Ok(writes);
            }
        };
        let mut puts = Vec::new();
        let mut removes = Vec::new();
        for target in targets {
            let theirs = of(&target.id);
            let mut kept: HashSet<String> = HashSet::new();
            for secret in target
                .secrets
                .iter()
                .filter(|secret| applies(&secret.kind, &target.fields))
            {
                let Some(envelope) = team_envelope_of(&target.id, &secret.kind) else {
                    continue;
                };
                let id = envelope.to_wire();
                if !kept.insert(id.clone()) {
                    continue;
                }
                let dest = destination(Kind::LibraryConnection, &secret.kind, &target.fields);
                let current = match theirs.iter().find(|held| held.id == id) {
                    Some(held) => {
                        self.still_opens(team, &envelope, &held.fields, secret, &dest, version)
                            .await
                    }
                    None => false,
                };
                if current {
                    continue;
                }
                match self
                    .keys
                    .seal_team_envelope(team, envelope, secret.value.clone(), dest)
                    .await
                {
                    Ok(fields) => puts.push(TeamLibraryEnvelope { id, fields }),
                    Err(error) => {
                        writes.left_out = Some(left_out(error, info.role)?);
                        return Ok(writes);
                    }
                }
            }
            removes.extend(
                theirs
                    .into_iter()
                    .filter(|held| !kept.contains(&held.id))
                    .map(|held| held.id.clone()),
            );
        }
        writes.puts = puts;
        writes.removes.extend(removes);
        Ok(writes)
    }

    // Under the publish's session lock and policy read, each write checking the sign-in just before it lands.
    pub(super) async fn write_envelopes(&self, scope: ScopeName, writes: &EnvelopeWrites) -> Result<(), SyncError> {
        let team = scope.wire();
        if !writes.puts.is_empty() {
            let (team, puts) = (team.clone(), writes.puts.clone());
            self.team_commit_check()?;
            self.store_call(move |store| store.put_envelopes_blocking(&team, puts))
                .await?;
        }
        if !writes.removes.is_empty() {
            let removes = writes.removes.clone();
            self.team_commit_check()?;
            self.store_call(move |store| store.remove_envelopes_blocking(&team, &removes))
                .await?;
        }
        Ok(())
    }

    // The envelope writes the team has not taken yet: a copy the server's base does not hold as written, or a removal
    // whose base still stands.
    pub(super) async fn envelopes_waiting(
        &self,
        scope: ScopeName,
        writes: &EnvelopeWrites,
    ) -> Result<usize, SyncError> {
        if writes.is_empty() {
            return Ok(0);
        }
        let live: HashMap<String, Value> = self
            .bases_in(scope, Kind::SecretEnvelope)
            .await?
            .into_iter()
            .filter(|base| base.deleted.is_none())
            .filter_map(|base| base.fields.map(|fields| (base.key.record_id, fields)))
            .collect();
        let puts = writes
            .puts
            .iter()
            .filter(|put| live.get(&put.id) != Some(&put.fields))
            .count();
        let removes = writes.removes.iter().filter(|id| live.contains_key(*id)).count();
        Ok(puts + removes)
    }

    // An envelope written here that has not gone up yet is sealed again once the team key moved on, as after a rotation
    // between a publish and its push: the server takes a team envelope only under the current version, and a device
    // never writes under one below the highest it took (0056, Writing). One the keys cannot seal now waits as it is.
    pub(in crate::service) async fn reseal_unsent_envelopes(&self, scope: ScopeName) -> Result<(), SyncError> {
        let ScopeName::Team(team) = scope else {
            return Ok(());
        };
        if self.readable().is_err() {
            return Ok(());
        }
        let held = self.team_envelopes(scope).await?;
        if held.is_empty() {
            return Ok(());
        }
        let live: HashMap<String, Value> = self
            .bases_in(scope, Kind::SecretEnvelope)
            .await?
            .into_iter()
            .filter(|base| base.deleted.is_none())
            .filter_map(|base| base.fields.map(|fields| (base.key.record_id, fields)))
            .collect();
        let unsent: Vec<&TeamLibraryEnvelope> = held
            .iter()
            .filter(|envelope| live.get(&envelope.id) != Some(&envelope.fields))
            .collect();
        if unsent.is_empty() {
            return Ok(());
        }
        let Ok(version) = self.keys.team_writing_version(team).await else {
            return Ok(());
        };
        let mut puts = Vec::new();
        for envelope in unsent {
            let behind = envelope
                .fields
                .get("kv")
                .and_then(Value::as_u64)
                .is_some_and(|kv| kv < u64::from(version.get()));
            let Ok(id) = EnvelopeId::parse(&envelope.id) else {
                continue;
            };
            if !behind {
                continue;
            }
            self.check_stop()?;
            let opened = match self
                .keys
                .open_held_team_envelope(team, id.clone(), envelope.fields.clone())
                .await
            {
                Ok(opened) => opened,
                Err(error) => {
                    tracing::debug!(
                        code = error.code(),
                        "an unsent team envelope did not open to seal again"
                    );
                    continue;
                }
            };
            match self.keys.seal_team_envelope(team, id, opened.secret, opened.dest).await {
                Ok(fields) => puts.push(TeamLibraryEnvelope {
                    id: envelope.id.clone(),
                    fields,
                }),
                Err(error) => tracing::debug!(
                    code = error.code(),
                    "an unsent team envelope waits for keys that seal it"
                ),
            }
        }
        self.write_envelopes(
            scope,
            &EnvelopeWrites {
                puts,
                removes: Vec::new(),
                left_out: None,
            },
        )
        .await
    }

    // Why the server turned down an envelope write that still waits, for the publish to report.
    pub(super) async fn envelope_refusal(
        &self,
        scope: ScopeName,
        writes: &EnvelopeWrites,
    ) -> Result<Option<String>, SyncError> {
        let written: HashSet<&str> = writes
            .puts
            .iter()
            .map(|put| put.id.as_str())
            .chain(writes.removes.iter().map(String::as_str))
            .collect();
        Ok(self
            .refused_in(scope)
            .await?
            .into_iter()
            .find(|(key, _)| key.kind == KindName::of(Kind::SecretEnvelope) && written.contains(key.record_id.as_str()))
            .map(|(_, refusal)| refusal.code))
    }

    // A discard puts the team's sealed copies back as the server last agreed on them.
    pub(super) async fn revert_envelopes(&self, scope: ScopeName) -> Result<(), SyncError> {
        let live: HashMap<String, Value> = self
            .bases_in(scope, Kind::SecretEnvelope)
            .await?
            .into_iter()
            .filter(|base| base.deleted.is_none())
            .filter_map(|base| base.fields.map(|fields| (base.key.record_id, fields)))
            .collect();
        let held = self.team_envelopes(scope).await?;
        let removes: Vec<String> = held
            .iter()
            .filter(|envelope| !live.contains_key(&envelope.id))
            .map(|envelope| envelope.id.clone())
            .collect();
        let puts: Vec<TeamLibraryEnvelope> = live
            .into_iter()
            .filter(|(id, fields)| {
                !held
                    .iter()
                    .any(|envelope| envelope.id == *id && envelope.fields == *fields)
            })
            .map(|(id, fields)| TeamLibraryEnvelope { id, fields })
            .collect();
        self.write_envelopes(
            scope,
            &EnvelopeWrites {
                puts,
                removes,
                left_out: None,
            },
        )
        .await?;
        // A refusal goes with what it refused.
        let refused: Vec<RowKey> = begin(&self.state)
            .await?
            .scan(&RowRange::Scope(Table::Refused, scope))
            .await?
            .into_iter()
            .filter_map(|row| match row {
                Row::Refused(row) if row.key.kind == KindName::of(Kind::SecretEnvelope) => {
                    Some(RowKey::Refused(row.key))
                }
                _ => None,
            })
            .collect();
        if !refused.is_empty() {
            self.check_stop()?;
            let mut txn = begin(&self.state).await?;
            for key in refused {
                txn.delete(&key).await?;
            }
            txn.commit().await?;
        }
        Ok(())
    }

    // Each secret the team keeps for the connection that opens here, sealed for the destination the store's copy of it
    // names now. One sealed for another destination waits for a writer to seal it again; the app asks the person.
    pub(super) async fn connection_secrets(
        &self,
        scope: ScopeName,
        connection: &str,
    ) -> Result<Vec<TeamSecret>, SyncError> {
        let ScopeName::Team(team) = scope else {
            return Ok(Vec::new());
        };
        let team_id = scope.wire();
        let Some(held) = self.store_call(move |store| store.team_blocking(&team_id)).await? else {
            return Ok(Vec::new());
        };
        let mut copies = held
            .items
            .iter()
            .filter(|item| item.kind == TeamLibraryKind::Connection && library_ids_match(&item.id, connection));
        // Two copies whose ids match without case are the collision 0052 leaves both of out.
        let (Some(copy), None) = (copies.next(), copies.next()) else {
            return Ok(Vec::new());
        };
        let mut secrets: Vec<TeamSecret> = Vec::new();
        for envelope in &held.envelopes {
            let Some((parent, kind)) = parent_of(envelope) else {
                continue;
            };
            if !library_ids_match(parent, &copy.id) || secrets.iter().any(|secret| secret.kind == kind) {
                continue;
            }
            let Ok(id) = EnvelopeId::parse(&envelope.id) else {
                continue;
            };
            self.check_stop()?;
            match self
                .keys
                .open_held_team_envelope(team, id, envelope.fields.clone())
                .await
            {
                Ok(opened) if opened.dest == destination(Kind::LibraryConnection, &kind, &copy.fields) => {
                    secrets.push(TeamSecret {
                        kind,
                        value: opened.secret,
                    });
                }
                Ok(_) => tracing::debug!("a team secret was sealed for another destination"),
                Err(error) => tracing::debug!(code = error.code(), "a team secret did not open"),
            }
        }
        Ok(secrets)
    }
}

#[cfg(test)]
#[expect(
    clippy::disallowed_types,
    reason = "JSON in a test is written with json!; its key order means nothing here"
)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_secret_goes_up_only_when_the_copy_uses_it() {
        let plain = json!({"host": "db"});
        let tunnel = json!({"host": "db", "sshConfig": {"enabled": true, "host": "bastion", "privateKeyPath": "",
            "totpMode": "none"}});
        let keyed = json!({"host": "db", "sshConfig": {"enabled": true, "host": "bastion",
            "privateKeyPath": "~/.ssh/id", "totpMode": "Auto Generate"}, "sslConfig": {"clientKeyPath": "/k.pem"}});
        let off = json!({"host": "db", "sshConfig": {"enabled": false, "privateKeyPath": "~/.ssh/id"}});

        assert!(applies(&SecretKind::Password, &plain));
        assert!(!applies(&SecretKind::SshPassword, &plain));
        assert!(applies(&SecretKind::SshPassword, &tunnel));
        assert!(!applies(&SecretKind::SshKeyPassphrase, &tunnel));
        assert!(!applies(&SecretKind::SshTotpSecret, &tunnel));
        assert!(applies(&SecretKind::SshKeyPassphrase, &keyed));
        assert!(applies(&SecretKind::SshTotpSecret, &keyed));
        assert!(applies(&SecretKind::SslKeyPassphrase, &keyed));
        assert!(!applies(&SecretKind::SslKeyPassphrase, &plain));
        assert!(!applies(&SecretKind::SshKeyPassphrase, &off));
        assert!(!applies(&SecretKind::Plugin("token".to_owned()), &plain));
    }

    #[test]
    fn a_seal_the_keys_refuse_is_a_reason_and_any_other_failure_fails_the_publish() {
        let rejected = |code| SyncError::Rejected { code };

        assert_eq!(
            left_out(rejected(RejectedCode::RotationDue), Some(Role::Editor)).unwrap(),
            SecretsLeftOut::RotationDue
        );
        assert_eq!(
            left_out(rejected(RejectedCode::Role), Some(Role::Member)).unwrap(),
            SecretsLeftOut::Role
        );
        assert_eq!(
            left_out(rejected(RejectedCode::Role), Some(Role::Editor)).unwrap(),
            SecretsLeftOut::NotConfirmed
        );
        assert_eq!(
            left_out(SyncError::NotAllowed { what: "x" }, Some(Role::Owner)).unwrap(),
            SecretsLeftOut::NotConfirmed
        );
        assert!(left_out(SyncError::Malformed { what: "x" }, Some(Role::Owner)).is_err());
    }
}
