// The device's key state, the recovery key as a person sees it once, and Genesis (0056, The recovery key; Account
// flows, Genesis).

use secrecy::ExposeSecret;
use tablepro_keys::body::KeyObject;
use tablepro_keys::cert::CertKind;
use tablepro_keys::encoding::{KeyPurpose, Version, random_uuid};
use tablepro_keys::keys::{AccountKeys, DeviceKeys, ScopeKey};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::Start;
use zeroize::Zeroizing;

use super::{AccountObjectsPlan, KeptDevice, KeyService, ScopeKeyPlan, create_change};
use crate::api::device_store::DeviceStoreError;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{DraftId, GenesisOutcome, KeyState, LockCause, RecoveryKeyDraft, TypedBack};
use crate::api::state::{KeyVersionState, PendingFlow, Row, RowKey, RowRange, StateTxn, Table};
use crate::api::transport::{ChangeOutcome, RejectedCode};

const GROUPS: u8 = 14;

// A recovery key shown and not yet typed back, with the two groups asked for.
pub(crate) struct ShownKey {
    pub(crate) key: RecoveryKey,
    pub(crate) check: [u8; 2],
}

impl ShownKey {
    pub(crate) fn new() -> Result<Self, SyncError> {
        let random = random_uuid()?.into_bytes();
        let first = random[0] % GROUPS;
        let second = (first + 1 + random[1] % (GROUPS - 1)) % GROUPS;
        Ok(Self {
            key: RecoveryKey::generate()?,
            check: [first, second],
        })
    }

    pub(crate) fn draft(&self, draft: DraftId) -> Result<RecoveryKeyDraft, SyncError> {
        Ok(RecoveryKeyDraft {
            draft,
            text: self.key.to_text()?,
            check: self.check,
        })
    }

    // Reading drops hyphens and spaces, upper-cases, and reads `O` as `0` and `I` and `L` as `1` (0056, Text).
    pub(crate) fn check_typed_back(&self, typed: &TypedBack) -> Result<(), SyncError> {
        let text = self.key.to_text()?;
        let groups: Vec<&str> = text.expose_secret().split('-').collect();
        let matches = self.check.iter().zip(&typed.groups).all(|(index, typed)| {
            let normalized: Zeroizing<String> = Zeroizing::new(
                typed
                    .expose_secret()
                    .chars()
                    .filter(|character| !matches!(character, '-' | ' '))
                    .map(|character| match character.to_ascii_uppercase() {
                        'O' => '0',
                        'I' | 'L' => '1',
                        other => other,
                    })
                    .collect(),
            );
            groups
                .get(usize::from(*index))
                .is_some_and(|group| *group == normalized.as_str())
        });
        if matches {
            Ok(())
        } else {
            Err(SyncError::TypedBackWrong)
        }
    }
}

struct GenesisDraft {
    // Wiped once the change set is built: the recovery key is not needed again (0056, Rotation, step 4).
    shown: Option<ShownKey>,
    // Built once and pushed again as it is after a failed try, so nothing is sealed twice (0056, Nonce budget).
    built: Option<(Vec<KeyObject>, AccountKeys)>,
}

impl KeyService {
    pub(crate) async fn state_of_keys(&self, txn: &mut dyn StateTxn) -> Result<KeyState, SyncError> {
        let device = match self.device_keys().await {
            Err(SyncError::DeviceStore(DeviceStoreError::Unavailable { .. })) => return Ok(KeyState::NoDeviceStore),
            other => other?,
        };
        let Some(pin) = self.pin(txn, self.account()).await? else {
            if self.account_has_keys(txn).await? {
                return Ok(KeyState::NeedsApproval {
                    request: pending_request(txn).await?,
                });
            }
            let read = match txn.get(&RowKey::Scope(ScopeName::Personal)).await? {
                Some(Row::Scope(row)) => row.caught_up || row.cursor.is_some(),
                _ => false,
            };
            return Ok(if read { KeyState::NoKeys } else { KeyState::Unknown });
        };
        if self.is_unanchored() {
            return Ok(locked(LockCause::Unanchored));
        }
        if pin.alert {
            return Ok(locked(LockCause::OwnAccountReset));
        }
        for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
            match self.personal_row(txn, purpose).await?.map(|row| row.state) {
                Some(KeyVersionState::Ended) => return Ok(locked(LockCause::AccountEnded)),
                Some(KeyVersionState::Stopped) => return Ok(locked(LockCause::PersonalStopped)),
                _ => {}
            }
        }
        match self.own_account(txn).await? {
            Some(own) => Ok(KeyState::Approved {
                av: own.av,
                key_device: own.device.key_device,
            }),
            None if device.current.is_none() => Ok(KeyState::NeedsApproval {
                request: pending_request(txn).await?,
            }),
            None => Ok(locked(LockCause::LeftOutOfRotation)),
        }
    }

    pub(crate) async fn start_genesis(&self) -> Result<RecoveryKeyDraft, SyncError> {
        let _serial = self.serialized().await;
        let mut txn = self.begin().await?;
        // A genesis this device pushed and never heard the end of goes up again, the same objects, before any new
        // one: a second set of keys must never stand in for one that applied (0054, `key_objects`).
        if let Some(candidates) = self.genesis_candidates(txn.as_mut()).await? {
            drop(txn);
            match self.push_genesis(&candidates).await {
                // Refused whole: nothing of it applied, and it is gone.
                Err(SyncError::Rejected { .. }) => {}
                Ok(_) => {
                    return Err(SyncError::NotAllowed {
                        what: "start keys on an account that has them",
                    });
                }
                Err(error) => return Err(error),
            }
            txn = self.begin().await?;
        }
        if self.state_of_keys(txn.as_mut()).await? != KeyState::NoKeys {
            return Err(SyncError::NotAllowed {
                what: "start keys on an account that has them",
            });
        }
        let shown = ShownKey::new()?;
        let recovery = shown.draft(DraftId(uuid::Uuid::nil()))?;
        let draft = self.drafts().put(GenesisDraft {
            shown: Some(shown),
            built: None,
        })?;
        Ok(RecoveryKeyDraft { draft, ..recovery })
    }

    pub(crate) async fn complete_genesis(
        &self,
        draft: DraftId,
        typed: &TypedBack,
    ) -> Result<GenesisOutcome, SyncError> {
        let _serial = self.serialized().await;
        let built = self
            .drafts()
            .with(draft, |held: &mut GenesisDraft| held.built.clone())?;
        if built.is_none() {
            self.drafts().with(draft, |held: &mut GenesisDraft| {
                held.shown
                    .as_ref()
                    .ok_or(SyncError::Unknown { what: "draft" })
                    .and_then(|shown| shown.check_typed_back(typed))
            })??;
        }
        let mut txn = self.begin().await?;
        if self.account_has_keys(txn.as_mut()).await? {
            // The genesis that applied may be this device's own, its answer lost and no pull since.
            self.adopt_own_genesis(txn.as_mut()).await?;
            let ours = self.own_account(txn.as_mut()).await?.is_some();
            txn.commit().await?;
            self.drafts().remove(draft);
            if ours {
                return Ok(GenesisOutcome::Created);
            }
            let objects = built.map(|(objects, _)| objects).unwrap_or_default();
            self.discard_losing_genesis(&objects).await?;
            self.hooks().pass_soon();
            return Ok(GenesisOutcome::AnotherDeviceWon);
        }
        let candidates = self.genesis_candidates(txn.as_mut()).await?;
        drop(txn);
        let ours = |objects: &[KeyObject]| {
            candidates
                .as_ref()
                .is_none_or(|held| held.len() == objects.len() && objects.iter().all(|object| held.contains(object)))
        };
        let (objects, keys) = match built {
            Some(built) if ours(&built.0) => built,
            None if candidates.is_none() => {
                let device = self.ensure_device_keys().await?;
                self.drafts().with(draft, |held: &mut GenesisDraft| {
                    let shown = held.shown.take().ok_or(SyncError::Unknown { what: "draft" })?;
                    let built = self.genesis_objects(&shown.key, &device)?;
                    held.built = Some(built.clone());
                    Ok::<_, SyncError>(built)
                })??
            }
            _ => {
                return Err(SyncError::NotAllowed {
                    what: "finish a genesis while an earlier one on this device is unresolved",
                });
            }
        };
        self.store_account_keys(Version::FIRST, &keys).await?;
        let mut txn = self.begin().await?;
        for object in &objects {
            self.hold_object(txn.as_mut(), ScopeName::Personal, object, false)
                .await?;
        }
        txn.commit().await?;
        let outcome = self.push_genesis(&objects).await;
        if !matches!(outcome, Err(SyncError::Transport(_))) {
            self.drafts().remove(draft);
        }
        outcome
    }

    // Pushes this device's genesis objects as one change set, and settles what the answer says: adopted, given way
    // to another device's, or refused and gone. A failed call leaves them as candidates to push again.
    async fn push_genesis(&self, objects: &[KeyObject]) -> Result<GenesisOutcome, SyncError> {
        let changes = objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let proof = self.dpop_key().await?;
        let outcomes = self.push_change_set(ScopeName::Personal, changes, proof).await?;
        match refusal(&outcomes) {
            None => {
                let mut txn = self.begin().await?;
                self.adopt_account_change_set(txn.as_mut(), objects).await?;
                txn.commit().await?;
                self.hooks().pass_soon();
                Ok(GenesisOutcome::Created)
            }
            Some(RejectedCode::CreateOnly) => {
                self.discard_losing_genesis(objects).await?;
                self.hooks().pass_soon();
                Ok(GenesisOutcome::AnotherDeviceWon)
            }
            Some(code) => {
                self.discard_losing_genesis(objects).await?;
                Err(SyncError::Rejected { code })
            }
        }
    }

    // The certificate at `av` 1, the recovery blob, this device's certificate, and PK and HK version 1 with `start` 1
    // and their wraps to AEK.
    fn genesis_objects(
        &self,
        recovery: &RecoveryKey,
        device: &DeviceKeys,
    ) -> Result<(Vec<KeyObject>, AccountKeys), SyncError> {
        let keys = AccountKeys::generate()?;
        let ik = recovery.identity_seed(self.origin(), self.account())?;
        let mut objects = self.account_objects(&AccountObjectsPlan {
            av: Version::FIRST,
            kind: CertKind::GenesisOrRotation,
            ik: &ik,
            endorsing_ik: None,
            recovery,
            keys: &keys,
            devices: &[KeptDevice::of(device)?],
            wrapper: None,
        })?;
        for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
            let key = ScopeKey::generate()?;
            objects.extend(self.personal_version_objects(
                purpose,
                &ScopeKeyPlan {
                    version: Version::FIRST,
                    key: &key,
                    start: Start::Over,
                    previous: None,
                },
                Version::FIRST,
                &keys,
                device.key_device,
            )?);
        }
        Ok((objects, keys))
    }

    // A certificate the server served, not this device's own candidate that never applied.
    async fn account_has_keys(&self, txn: &mut dyn StateTxn) -> Result<bool, SyncError> {
        Ok(!self
            .applied_objects(txn, ScopeName::Personal, KeyKind::Account)
            .await?
            .is_empty())
    }

    // This device's own genesis objects that never applied, in the order a genesis sends them; None when it has no
    // genesis certificate of its own waiting.
    async fn genesis_candidates(&self, txn: &mut dyn StateTxn) -> Result<Option<Vec<KeyObject>>, SyncError> {
        let first = KeyRecordId::Account {
            account: self.account(),
            av: Version::FIRST,
        };
        let waiting = self
            .held_object(txn, ScopeName::Personal, KeyKind::Account, &first.to_wire())
            .await?
            .is_some_and(|held| !held.applied);
        if !waiting {
            return Ok(None);
        }
        let mut objects = Vec::new();
        for kind in [
            KeyKind::Account,
            KeyKind::Recovery,
            KeyKind::Device,
            KeyKind::Version,
            KeyKind::Wrap,
        ] {
            for held in self.held_objects(txn, ScopeName::Personal, kind).await? {
                if !held.applied && genesis_object(&held.object) {
                    objects.push(held.object);
                }
            }
        }
        Ok(Some(objects))
    }

    // The objects go, and so do the account keys at `av` 1 unless they are the ones the certificate in force names:
    // those are this device's own genesis after all.
    async fn discard_losing_genesis(&self, objects: &[KeyObject]) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        self.drop_candidates(txn.as_mut(), ScopeName::Personal, objects).await?;
        let applied = self.own_certificate(txn.as_mut(), Version::FIRST).await?;
        txn.commit().await?;
        if let Some(keys) = self.account_keys(Version::FIRST).await?
            && applied.is_none_or(|certificate| keys.check_against(&certificate.ask, &certificate.aek).is_err())
        {
            self.erase_account_keys(Version::FIRST).await?;
        }
        Ok(())
    }
}

// An object a genesis sends: everything at `av` 1.
fn genesis_object(object: &KeyObject) -> bool {
    match &object.id {
        KeyRecordId::Account { av, .. } | KeyRecordId::Recovery { av, .. } | KeyRecordId::Device { av, .. } => {
            *av == Version::FIRST
        }
        KeyRecordId::Version(_) => object
            .version_record()
            .is_some_and(|record| record.signer_av == Version::FIRST && record.key.version == Version::FIRST),
        KeyRecordId::Wrap(target) => target.version == Version::FIRST && target.recipient_version == Version::FIRST,
        _ => false,
    }
}

fn locked(cause: LockCause) -> KeyState {
    KeyState::Locked { cause }
}

// The approval request this device has in flight, which K7-2's flow keeps in `key_pending`.
async fn pending_request(txn: &mut dyn StateTxn) -> Result<Option<tablepro_keys::encoding::RequestId>, SyncError> {
    Ok(txn
        .scan(&RowRange::Table(Table::KeyPending))
        .await?
        .iter()
        .find_map(|row| match row {
            Row::KeyPending(pending) => match pending.flow {
                PendingFlow::Approval { request } => Some(request),
                _ => None,
            },
            _ => None,
        }))
}

// The code that refused a change set: the refused change's own, never the `change_set` the rest answer.
pub(crate) fn refusal(outcomes: &[ChangeOutcome]) -> Option<RejectedCode> {
    let mut codes = outcomes.iter().filter_map(|outcome| match outcome {
        ChangeOutcome::Applied { .. } => None,
        ChangeOutcome::Rejected { code } => Some(code.clone()),
        ChangeOutcome::Conflict { .. } | ChangeOutcome::Gone | ChangeOutcome::Failed { .. } => {
            Some(RejectedCode::Other("unexpected".to_owned()))
        }
    });
    let first = codes.next()?;
    if first != RejectedCode::ChangeSet {
        return Some(first);
    }
    Some(codes.find(|code| *code != RejectedCode::ChangeSet).unwrap_or(first))
}
