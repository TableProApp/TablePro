// What this account writes into a team (0056, Teams): its certificates, a team creation, a confirmation, a rotation and
// a restart. Each change set goes up as one push and is kept as applied only once the server applied all of it.

use std::collections::BTreeSet;

use tablepro_keys::KeysError;
use tablepro_keys::body::{KeyBody, KeyObject};
use tablepro_keys::cert::{AccountCertificate, CertKind};
use tablepro_keys::encoding::{AccountId, TeamId, Version};
use tablepro_keys::keys::ScopeKey;
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::scope_key::Start;

use super::book::{TeamBook, account_holds};
use super::build::{self, NewVersion, Signer};
use super::facts::known_pin;
use super::roster;
use super::secrets;
use super::service_facts::{FactsCache, ServiceFacts};
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::Roster;
use crate::api::scopes::Role;
use crate::api::state::{Holder, KeyVersionRow, KeyVersionState, Row, StateTxn};
use crate::api::transport::{ChangeOutcome, RejectedCode};
use crate::keys::{KeyService, MetRotation, OwnAccount, create_change};

fn rejected(code: RejectedCode) -> SyncError {
    SyncError::Rejected { code }
}

// A change set applies whole: the first change's own refusal names it, the others answer `change_set`.
fn settle(outcomes: &[ChangeOutcome]) -> Result<(), SyncError> {
    if outcomes
        .iter()
        .all(|outcome| matches!(outcome, ChangeOutcome::Applied { .. }))
    {
        return Ok(());
    }
    let code = outcomes
        .iter()
        .find_map(|outcome| match outcome {
            ChangeOutcome::Rejected { code } if *code != RejectedCode::ChangeSet => Some(code.clone()),
            _ => None,
        })
        .unwrap_or(RejectedCode::ChangeSet);
    Err(rejected(code))
}

fn holders_of(recipients: &[AccountCertificate]) -> BTreeSet<Holder> {
    recipients
        .iter()
        .map(|certificate| Holder {
            account: certificate.account,
            ik: certificate.ik,
        })
        .collect()
}

fn team_row(team: TeamId, version: Version, record: [u8; 32], holders: BTreeSet<Holder>) -> KeyVersionRow {
    KeyVersionRow {
        scope: ScopeName::Team(team),
        purpose: tablepro_keys::encoding::KeyPurpose::Team,
        version,
        record,
        holders: holders.into_iter().collect(),
        state: KeyVersionState::Ok,
        stopped_cause: None,
        epoch: None,
    }
}

impl KeyService {
    async fn acting(&self, txn: &mut dyn StateTxn) -> Result<OwnAccount, SyncError> {
        self.may_handle_secrets()?;
        self.own_account(txn).await?.ok_or(SyncError::NotAllowed {
            what: "use team keys before this device holds the account's keys",
        })
    }

    fn signer<'a>(&self, own: &'a OwnAccount) -> Signer<'a> {
        Signer {
            account: self.account(),
            av: own.av,
            keys: &own.keys,
            key_device: own.device.key_device,
        }
    }

    // Nothing is held before the server applied the whole set, so a refused or lost push leaves no candidate behind; a
    // lost answer heals on the next pull, which serves the objects this device wrote.
    async fn push_team_set(&self, team: TeamId, objects: &[KeyObject]) -> Result<Box<dyn StateTxn>, SyncError> {
        Ok(self.push_team_set_at(team, objects).await?.0)
    }

    // With the highest revision the set applied at.
    async fn push_team_set_at(
        &self,
        team: TeamId,
        objects: &[KeyObject],
    ) -> Result<(Box<dyn StateTxn>, Option<u64>), SyncError> {
        let scope = ScopeName::Team(team);
        let changes = objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let outcomes = self.push_change_set(scope, changes, self.dpop_key().await?).await?;
        settle(&outcomes)?;
        let revision = outcomes
            .iter()
            .filter_map(|outcome| match outcome {
                ChangeOutcome::Applied {
                    service: Some(stamp), ..
                } => Some(stamp.revision),
                _ => None,
            })
            .max();
        let mut txn = self.begin().await?;
        for object in objects {
            self.hold_object(&mut *txn, scope, object, true).await?;
        }
        Ok((txn, revision))
    }

    // This account's certificates the team lacks: the current one, every replace it made, and every `av` from its
    // first copy in the team up, so a teammate can walk its replaces with no `av` missing (0056, Teams, Certificates in
    // the team).
    // `again` sends the current certificate even when the team holds it, as a member does that sees a wrap to an `av`
    // it left (0056, Teams, A member checks what reaches it).
    pub(super) async fn publish_certificates(&self, team: TeamId, again: bool) -> Result<(), SyncError> {
        let scope = ScopeName::Team(team);
        let mut txn = self.begin().await?;
        // Certificates are public, so this needs the account's keys held but no check on the key tables' secrets.
        let own = self.own_account(&mut *txn).await?.ok_or(SyncError::NotAllowed {
            what: "copy a certificate into a team before this device holds the account's keys",
        })?;
        let me = self.account();
        let in_team: BTreeSet<Version> = self
            .held_objects(&mut *txn, scope, KeyKind::Member)
            .await?
            .iter()
            .filter_map(|held| match held.object.id {
                KeyRecordId::Member { account, av } if account == me => Some(av),
                _ => None,
            })
            .collect();
        let first = in_team.first().copied();
        let mut certificates: Vec<AccountCertificate> = self
            .applied_objects(&mut *txn, ScopeName::Personal, KeyKind::Account)
            .await?
            .into_iter()
            .filter_map(|object| match (object.id, object.body) {
                (KeyRecordId::Account { account, av }, KeyBody::Account(body)) if account == me => {
                    Some(body.certificate(account, av))
                }
                _ => None,
            })
            .filter(|certificate| {
                certificate.av <= own.av
                    && (!in_team.contains(&certificate.av) || again && certificate.av == own.av)
                    && (certificate.av == own.av
                        || certificate.kind == CertKind::Replace
                        || first.is_some_and(|first| certificate.av > first))
            })
            .collect();
        drop(txn);
        certificates.sort_by_key(|certificate| certificate.av);
        let objects: Vec<KeyObject> = certificates.iter().map(build::member_object).collect();
        if objects.is_empty() {
            return Ok(());
        }
        let changes = objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let outcomes = self.push_change_set(scope, changes, self.dpop_key().await?).await?;
        let mut txn = self.begin().await?;
        let mut refusal = None;
        for (object, outcome) in objects.iter().zip(&outcomes) {
            match outcome {
                ChangeOutcome::Applied { .. } => self.hold_object(&mut *txn, scope, object, true).await?,
                ChangeOutcome::Rejected { code } => refusal = refusal.or_else(|| Some(code.clone())),
                _ => refusal = refusal.or(Some(RejectedCode::Other("unexpected".to_owned()))),
            }
        }
        txn.commit().await?;
        refusal.map_or(Ok(()), |code| Err(rejected(code)))
    }

    // A team creation: this owner's certificate, TK v1 with `start` 1, and its wrap to the owner's AEK, as one change
    // set (0056, Teams, Creating a team).
    pub(super) async fn create_team(&self, team: TeamId) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        let own = self.acting(&mut *txn).await?;
        let roster = self.roster_of(&mut *txn, team).await?;
        if roster.role != Some(Role::Owner) {
            return Err(rejected(RejectedCode::Role));
        }
        let book = self.load_team(&mut *txn, team).await?;
        if book.row().is_some() || book.versions().next().is_some() {
            return Err(SyncError::NotAllowed {
                what: "create keys for a team that has them",
            });
        }
        let certificate = self
            .certificate_at(&mut *txn, ScopeName::Personal, self.account(), own.av)
            .await?
            .ok_or(SyncError::NotAllowed {
                what: "create a team key before this account's certificate is held",
            })?;
        drop(txn);
        let key = ScopeKey::generate()?;
        let recipients = [certificate.clone()];
        let plan = NewVersion {
            team,
            version: Version::FIRST,
            start: Start::Over,
            scope_key: &key,
            previous: None,
            recipients: &recipients,
        };
        let (record, mut objects) = build::version_objects(self.origin(), &plan, &self.signer(&own))?;
        objects.insert(0, build::member_object(&certificate));
        let mut txn = self.push_team_set(team, &objects).await?;
        let row = team_row(
            team,
            Version::FIRST,
            record.digest(self.origin())?,
            holders_of(&recipients),
        );
        self.put_team_row(&mut *txn, None, &row).await?;
        txn.commit().await?;
        // A creator copies in every replace it made too, as a member that joins does.
        self.publish_certificates(team, false).await
    }

    // The team as this account acts on it now: its own keys, the roster, and a current version it holds.
    async fn held_team(
        &self,
        txn: &mut dyn StateTxn,
        team: TeamId,
    ) -> Result<(OwnAccount, Roster, TeamBook, KeyVersionRow), SyncError> {
        let own = self.acting(txn).await?;
        let roster = self.roster_of(txn, team).await?;
        let book = self.load_team(txn, team).await?;
        book.check_anchor()?;
        let row = book
            .row()
            .filter(|row| row.state == KeyVersionState::Ok)
            .cloned()
            .ok_or(SyncError::NotAllowed {
                what: "change a team key this device does not hold as current",
            })?;
        Ok((own, roster, book, row))
    }

    // An owner's or admin's Confirm: the current version wrapped to the member's newest certificate, which is pinned on
    // first use. A member under an alert is re-confirmed only after the person compares or accepts its new key.
    pub(super) async fn confirm(&self, team: TeamId, account: AccountId) -> Result<(), SyncError> {
        self.publish_certificates(team, false).await?;
        let scope = ScopeName::Team(team);
        let mut txn = self.begin().await?;
        let (own, roster, book, row) = self.held_team(&mut *txn, team).await?;
        if !roster.role.is_some_and(Role::manages_keys) {
            return Err(rejected(RejectedCode::Role));
        }
        if !roster.members.iter().any(|member| member.account == account) {
            return Err(SyncError::Unknown { what: "member" });
        }
        let mut cache = FactsCache::default();
        let mut facts = ServiceFacts {
            service: self,
            txn: &mut *txn,
            scope,
            cache: &mut cache,
        };
        if !book.own_holds(&mut facts).await? {
            return Err(KeysError::NotHolder.into());
        }
        let newest = facts.chain_newest(account).await?.ok_or(SyncError::NotAllowed {
            what: "confirm a member with no keys",
        })?;
        facts.offer(&newest).await?;
        let certificate = match known_pin(&mut facts, account).await? {
            Some(pin) if !pin.alert => roster::current_certificate(&mut facts, account).await?,
            _ => None,
        }
        .ok_or(SyncError::NotAllowed {
            what: "confirm a member under an alert",
        })?;
        if account_holds(self.origin(), &mut facts, &row.holders, account).await? {
            txn.commit().await?;
            return Ok(());
        }
        roster::check_room(&roster, &row.holders, account)?;
        let key = secrets::team_key(self, team, &book, &mut facts, row.version, row.version).await?;
        let wrap = build::wrap_to(
            self.origin(),
            build::team_key(team, row.version),
            &key,
            &certificate,
            &self.signer(&own),
        )?;
        txn.commit().await?;
        let mut txn = match self.push_team_set(team, std::slice::from_ref(&wrap)).await {
            Ok(txn) => txn,
            // Another owner or admin confirmed the member first, at the same wrap id.
            Err(SyncError::Rejected {
                code: RejectedCode::CreateOnly,
            }) => return Ok(()),
            Err(other) => return Err(other),
        };
        let mut holders: BTreeSet<Holder> = row.holders.iter().copied().collect();
        holders.insert(Holder {
            account,
            ik: certificate.ik,
        });
        let after = KeyVersionRow {
            holders: holders.into_iter().collect(),
            ..row.clone()
        };
        self.put_team_row(&mut *txn, Some(&row), &after).await?;
        txn.commit().await?;
        Ok(())
    }

    // The next version, its ring and a wrap to each holder on the roster without an open alert, less `remove`. An
    // owner or admin rotates at any time and any other holder only while the team is due (0051, Roles in a team
    // scope). The server judges that: the mark this device last read can lag behind its own account rotation, after
    // which its review's team rotations come at once. A holder of a stopped device's version confirms it again this
    // way.
    pub(super) async fn rotate(&self, team: TeamId, remove: &[AccountId]) -> Result<(), SyncError> {
        self.publish_certificates(team, false).await?;
        let scope = ScopeName::Team(team);
        let mut txn = self.begin().await?;
        let (own, roster, book, row) = self.held_team(&mut *txn, team).await?;
        let mut cache = FactsCache::default();
        let mut facts = ServiceFacts {
            service: self,
            txn: &mut *txn,
            scope,
            cache: &mut cache,
        };
        if !book.own_holds(&mut facts).await? {
            return Err(KeysError::NotHolder.into());
        }
        let recipients =
            roster::rotation_recipients(self.origin(), &mut facts, &roster, &row.holders, self.account(), remove)
                .await?;
        roster::check_fits(recipients.len())?;
        let previous = secrets::team_key(self, team, &book, &mut facts, row.version, row.version).await?;
        drop(txn);
        let next = row.version.next()?;
        let key = ScopeKey::generate()?;
        let plan = NewVersion {
            team,
            version: next,
            start: Start::Next,
            scope_key: &key,
            previous: Some(&previous),
            recipients: &recipients,
        };
        self.push_version(team, &row, &plan, &own).await
    }

    // An owner's restart once no member on the roster holds the current version: the next version with `start` 1, a
    // ring when this device still holds the current key, and wraps to this account and the members it confirms.
    pub(super) async fn restart(&self, team: TeamId, confirm: &[AccountId]) -> Result<(), SyncError> {
        self.publish_certificates(team, false).await?;
        let scope = ScopeName::Team(team);
        let mut txn = self.begin().await?;
        let (own, roster, book, row) = self.held_team(&mut *txn, team).await?;
        if roster.role != Some(Role::Owner) {
            return Err(rejected(RejectedCode::Role));
        }
        let mut cache = FactsCache::default();
        let mut facts = ServiceFacts {
            service: self,
            txn: &mut *txn,
            scope,
            cache: &mut cache,
        };
        for member in &roster.members {
            if account_holds(self.origin(), &mut facts, &row.holders, member.account).await? {
                return Err(SyncError::NotAllowed {
                    what: "restart a team key a member on the roster holds",
                });
            }
        }
        let mut accounts: BTreeSet<AccountId> = confirm.iter().copied().collect();
        accounts.insert(self.account());
        let mut recipients = Vec::new();
        for account in accounts {
            if !roster.members.iter().any(|member| member.account == account) {
                return Err(SyncError::Unknown { what: "member" });
            }
            if let Some(newest) = facts.chain_newest(account).await? {
                facts.offer(&newest).await?;
            }
            let certificate = match known_pin(&mut facts, account).await? {
                Some(pin) if !pin.alert => roster::current_certificate(&mut facts, account).await?,
                _ => None,
            }
            .ok_or(SyncError::NotAllowed {
                what: "wrap a team key to a member with no keys or under an alert",
            })?;
            recipients.push(certificate);
        }
        roster::check_fits(recipients.len())?;
        let previous = match secrets::team_key(self, team, &book, &mut facts, row.version, row.version).await {
            Ok(key) => Some(key),
            Err(SyncError::NotAllowed { .. }) => None,
            Err(other) => return Err(other),
        };
        drop(txn);
        let next = row.version.next()?;
        let key = ScopeKey::generate()?;
        let plan = NewVersion {
            team,
            version: next,
            start: Start::Over,
            scope_key: &key,
            previous: previous.as_ref(),
            recipients: &recipients,
        };
        self.push_version(team, &row, &plan, &own).await
    }

    // A rotation or restart as one change set. The server checks every wrap against the roster and each recipient's
    // current `av` as it applies, so a refusal leaves nothing here and the person or the next roster read builds it
    // again after a pull.
    async fn push_version(
        &self,
        team: TeamId,
        row: &KeyVersionRow,
        plan: &NewVersion<'_>,
        own: &OwnAccount,
    ) -> Result<(), SyncError> {
        let (record, objects) = build::version_objects(self.origin(), plan, &self.signer(own))?;
        let (mut txn, revision) = self.push_team_set_at(team, &objects).await?;
        let after = team_row(
            team,
            plan.version,
            record.digest(self.origin())?,
            holders_of(plan.recipients),
        );
        self.put_team_row(&mut *txn, Some(row), &after).await?;
        // A whole team rotation change set applied, which meets every `rotation_due` mark set before it.
        let scope = ScopeName::Team(team);
        let mut scope_row = self.scope_row(&mut *txn, scope).await?;
        let epoch = scope_row.epoch;
        if scope_row.rotation_due {
            scope_row.rotation_due = false;
            txn.put(Row::Scope(scope_row)).await?;
        }
        txn.commit().await?;
        if let Some(mut roster) = self.rosters().get(team) {
            roster.rotation_due = false;
            self.rosters().put(team, roster);
        }
        if let (Some(epoch), Some(revision)) = (epoch, revision) {
            self.met_rotations().insert(team, MetRotation { epoch, revision });
        }
        Ok(())
    }
}
