// The device's key state, the recovery key as a person sees it once, and Genesis (0056, The recovery key; Account
// flows, Genesis).

use std::sync::Arc;

use secrecy::ExposeSecret;
use tablepro_keys::body::KeyObject;
use tablepro_keys::cert::CertKind;
use tablepro_keys::encoding::{KeyPurpose, Version, random_uuid};
use tablepro_keys::keys::{AccountKeys, DeviceKeys, ScopeKey};
use tablepro_keys::record_id::KeyKind;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::Start;
use zeroize::Zeroizing;

use super::{AccountObjectsPlan, KeptDevice, KeyService, ScopeKeyPlan, create_change};
use crate::api::device_store::DeviceStoreError;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::{DraftId, GenesisOutcome, KeyState, LockCause, RecoveryKeyDraft, TypedBack};
use crate::api::state::{KeyVersionState, PendingFlow, Row, RowKey, RowRange, StateTxn, Table};
use crate::api::transport::{ChangeOutcome, DpopKey, RejectedCode};

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
    shown: ShownKey,
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
        if self.state_of_keys(txn.as_mut()).await? != KeyState::NoKeys {
            return Err(SyncError::NotAllowed {
                what: "start keys on an account that has them",
            });
        }
        let shown = ShownKey::new()?;
        let draft = self.drafts().put(GenesisDraft { shown, built: None })?;
        self.drafts()
            .with(draft, |held: &mut GenesisDraft| held.shown.draft(draft))?
    }

    pub(crate) async fn complete_genesis(
        &self,
        draft: DraftId,
        typed: &TypedBack,
    ) -> Result<GenesisOutcome, SyncError> {
        let _serial = self.serialized().await;
        self.drafts()
            .with(draft, |held: &mut GenesisDraft| held.shown.check_typed_back(typed))??;
        let mut txn = self.begin().await?;
        if self.account_has_keys(txn.as_mut()).await? {
            // A pull already took this device's own genesis back after its answer was lost.
            if self.own_account(txn.as_mut()).await?.is_some() {
                self.drafts().remove(draft);
                return Ok(GenesisOutcome::Created);
            }
            drop(txn);
            return self.another_genesis_won(draft, &[]).await;
        }
        drop(txn);
        let device = self.ensure_device_keys().await?;
        let built = self
            .drafts()
            .with(draft, |held: &mut GenesisDraft| held.built.clone())?;
        let (objects, keys) = match built {
            Some(built) => built,
            None => {
                let built = self.drafts().with(draft, |held: &mut GenesisDraft| {
                    self.genesis_objects(&held.shown.key, &device)
                })??;
                self.drafts()
                    .with(draft, |held: &mut GenesisDraft| held.built = Some(built.clone()))?;
                built
            }
        };
        self.store_account_keys(Version::FIRST, &keys).await?;
        let mut txn = self.begin().await?;
        for object in &objects {
            self.hold_object(txn.as_mut(), ScopeName::Personal, object, false)
                .await?;
        }
        txn.commit().await?;
        let changes = objects.iter().map(create_change).collect::<Result<Vec<_>, _>>()?;
        let outcomes = self
            .push_change_set(ScopeName::Personal, changes, DpopKey(Arc::new(device.dsk.clone())))
            .await?;
        match refusal(&outcomes) {
            None => {
                let mut txn = self.begin().await?;
                self.adopt_account_change_set(txn.as_mut(), &objects).await?;
                txn.commit().await?;
                self.drafts().remove(draft);
                self.hooks().pass_soon();
                Ok(GenesisOutcome::Created)
            }
            Some(RejectedCode::CreateOnly) => self.another_genesis_won(draft, &objects).await,
            Some(code) => {
                self.discard_genesis(&objects).await?;
                self.drafts().with(draft, |held: &mut GenesisDraft| held.built = None)?;
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
        Ok(self
            .held_objects(txn, ScopeName::Personal, KeyKind::Account)
            .await?
            .iter()
            .any(|held| held.applied))
    }

    // Another device's genesis applied first: this one's keys are discarded and it asks for approval (0056, Genesis).
    async fn another_genesis_won(&self, draft: DraftId, objects: &[KeyObject]) -> Result<GenesisOutcome, SyncError> {
        self.discard_genesis(objects).await?;
        self.drafts().remove(draft);
        self.hooks().pass_soon();
        Ok(GenesisOutcome::AnotherDeviceWon)
    }

    async fn discard_genesis(&self, objects: &[KeyObject]) -> Result<(), SyncError> {
        let mut txn = self.begin().await?;
        self.drop_candidates(txn.as_mut(), ScopeName::Personal, objects).await?;
        txn.commit().await?;
        if !objects.is_empty() {
            self.erase_account_keys(Version::FIRST).await?;
        }
        Ok(())
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
