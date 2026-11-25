use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use secrecy::{ExposeSecret, SecretString};
use serde_json::{Value, json};
use tablepro_keys::KeysError;
use tablepro_keys::encoding::{AccountId, HistoryId, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_keys::fingerprint::{fingerprint, fingerprint_words, parse_qr, qr_text};
use tablepro_keys::keys::Ed25519Seed;
use tablepro_keys::sas::SAS_WORDS;
use tablepro_keys::words::words;
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::{
    Acceptance, AccountFlows, DraftId, Fingerprint, GenesisOutcome, KeyApplied, KeyArrival, KeyNotice, KeyNoticeKind,
    KeyState, MemberKeyStatus, NoticeId, OpenedEnvelope, RecoveryKeyDraft, SignOutOutcome, TypedBack,
};
use uuid::Uuid;

use super::{
    DraftPurpose, FakeKeyFlows, Model, check_typed_back, new_draft, require_approved, same_recovery_key, version,
};

pub(crate) fn notice(model: &mut Model, kind: KeyNoticeKind) {
    model.notices.push(KeyNotice {
        id: NoticeId(Uuid::new_v4()),
        kind,
    });
}

pub(crate) fn sas_words() -> Vec<String> {
    let digest: [u8; 32] = *Uuid::new_v4().as_bytes().repeat(2).first_chunk().unwrap_or(&[0; 32]);
    words(&digest, SAS_WORDS).into_iter().map(str::to_owned).collect()
}

// Sealed in the clear: `ct` is the plaintext's base64url, which only this fake writes.
pub(crate) fn fake_seal(kv: Version, plaintext: &Value) -> Value {
    json!({"suite": "tp1", "kv": kv.get(), "nonce": "fake", "ct": URL_SAFE_NO_PAD.encode(plaintext.to_string())})
}

pub(crate) fn fake_open(fields: &Value) -> Result<(Version, Value), SyncError> {
    let malformed = || {
        SyncError::Keys(KeysError::Encoding {
            what: "not a fake envelope",
        })
    };
    let kv = fields.get("kv").and_then(Value::as_i64).ok_or_else(malformed)?;
    let ct = fields.get("ct").and_then(Value::as_str).ok_or_else(malformed)?;
    let bytes = URL_SAFE_NO_PAD.decode(ct).map_err(|_| malformed())?;
    let plaintext = serde_json::from_slice(&bytes).map_err(|_| malformed())?;
    Ok((Version::from_i64(kv)?, plaintext))
}

// Never below the version in force at its place in the order, nor below the copy held (0056, Rollback).
pub(crate) fn take_kv(
    model: &mut Model,
    scope: ScopeName,
    id: &str,
    kv: Version,
    in_force: Option<Version>,
) -> Result<(), SyncError> {
    let held = model.held_kv.get(&(scope, id.to_owned())).copied();
    for floor in [in_force.map(Version::get), held].into_iter().flatten() {
        if kv.get() < floor {
            return Err(SyncError::Keys(KeysError::Stale {
                held: floor,
                offered: kv.get(),
            }));
        }
    }
    model.held_kv.insert((scope, id.to_owned()), kv.get());
    Ok(())
}

impl FakeKeyFlows {
    fn identity(&self, model: &mut Model, account: AccountId) -> Result<tablepro_keys::keys::Ed25519Public, SyncError> {
        if let Some(ik) = model.identities.get(&account) {
            return Ok(*ik);
        }
        let ik = Ed25519Seed::generate()?.public()?;
        model.identities.insert(account, ik);
        Ok(ik)
    }

    fn fingerprint_of(&self, account: AccountId) -> Result<Fingerprint, SyncError> {
        let ik = self.identity(&mut self.lock(), account)?;
        let digest = fingerprint(&self.origin, account, &ik)?;
        Ok(Fingerprint {
            words: fingerprint_words(&digest).into_iter().map(str::to_owned).collect(),
            qr: qr_text(&digest),
        })
    }

    pub(crate) fn approve(&self, model: &mut Model) -> Result<(), SyncError> {
        model.av = model.av.max(1);
        model.key_state = KeyState::Approved {
            av: version(model.av)?,
            key_device: self.key_device,
        };
        Ok(())
    }
}

#[async_trait]
impl AccountFlows for FakeKeyFlows {
    async fn key_state(&self) -> Result<KeyState, SyncError> {
        Ok(self.lock().key_state.clone())
    }

    async fn begin_genesis(&self) -> Result<RecoveryKeyDraft, SyncError> {
        let mut model = self.lock();
        if model.key_state != KeyState::NoKeys {
            return Err(SyncError::NotAllowed {
                what: "start a genesis",
            });
        }
        let (draft, made) = new_draft(&mut model, DraftPurpose::Genesis)?;
        Ok(RecoveryKeyDraft {
            draft,
            text: made.text,
            check: made.check,
        })
    }

    async fn finish_genesis(&self, draft: DraftId, typed: TypedBack) -> Result<GenesisOutcome, SyncError> {
        let mut model = self.lock();
        let held = model
            .drafts
            .get(&draft)
            .cloned()
            .ok_or(SyncError::Unknown { what: "draft" })?;
        check_typed_back(&held, &typed)?;
        model.drafts.remove(&draft);
        if model.another_device_won {
            model.key_state = super::KeyState::NeedsApproval { request: None };
            model.av = 1;
            return Ok(GenesisOutcome::AnotherDeviceWon);
        }
        model.recovery = Some(held.text);
        model.history_version = 1;
        self.approve(&mut model)?;
        Ok(GenesisOutcome::Created)
    }

    async fn sign_out(&self) -> Result<SignOutOutcome, SyncError> {
        let mut model = self.lock();
        model.key_state = KeyState::NeedsApproval { request: None };
        model.sessions.clear();
        Ok(if model.offline {
            SignOutOutcome::ErasedOffline
        } else {
            SignOutOutcome::Revoked
        })
    }

    async fn begin_replace(&self, recovery_key: SecretString) -> Result<RecoveryKeyDraft, SyncError> {
        let mut model = self.lock();
        require_approved(&model, "replace the recovery key")?;
        same_recovery_key(model.recovery.as_ref(), &recovery_key)?;
        let (draft, made) = new_draft(&mut model, DraftPurpose::Replace)?;
        Ok(RecoveryKeyDraft {
            draft,
            text: made.text,
            check: made.check,
        })
    }

    async fn finish_replace(&self, draft: DraftId, typed: TypedBack) -> Result<(), SyncError> {
        let mut model = self.lock();
        let held = model
            .drafts
            .get(&draft)
            .cloned()
            .ok_or(SyncError::Unknown { what: "draft" })?;
        check_typed_back(&held, &typed)?;
        model.drafts.remove(&draft);
        model.recovery = Some(held.text);
        model.av += 1;
        self.approve(&mut model)
    }

    async fn own_fingerprint(&self) -> Result<Fingerprint, SyncError> {
        self.fingerprint_of(self.account)
    }

    async fn fingerprint(&self, account: AccountId) -> Result<Fingerprint, SyncError> {
        self.fingerprint_of(account)
    }

    async fn compare_qr(&self, account: AccountId, text: String) -> Result<bool, SyncError> {
        let scanned = parse_qr(&text)?;
        let ik = self.identity(&mut self.lock(), account)?;
        Ok(scanned == fingerprint(&self.origin, account, &ik)?)
    }

    async fn accept_key_change(&self, account: AccountId, how: Acceptance) -> Result<(), SyncError> {
        let _ = how;
        let mut model = self.lock();
        for team in model.teams.values_mut() {
            if let Some((_, status)) = team.members.get_mut(&account)
                && *status == MemberKeyStatus::Alert
            {
                // The alert clears; a team key reaches the member only once an owner or admin confirms it again.
                *status = MemberKeyStatus::AwaitingConfirmation;
            }
        }
        model
            .notices
            .retain(|notice| notice.kind != KeyNoticeKind::KeysChanged { account });
        Ok(())
    }

    async fn notices(&self) -> Result<Vec<KeyNotice>, SyncError> {
        Ok(self.lock().notices.clone())
    }

    async fn dismiss_notice(&self, notice: NoticeId) -> Result<(), SyncError> {
        self.lock().notices.retain(|held| held.id != notice);
        Ok(())
    }

    async fn apply_account_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        let _ = arrival;
        Ok(KeyApplied::default())
    }

    async fn seal_personal_envelope(
        &self,
        envelope: EnvelopeId,
        secret: SecretString,
        dest: Value,
    ) -> Result<Value, SyncError> {
        let model = self.lock();
        require_approved(&model, "seal a personal secret")?;
        let _ = envelope;
        Ok(fake_seal(
            version(model.av)?,
            &json!({"secret": secret.expose_secret(), "dest": dest}),
        ))
    }

    async fn open_personal_envelope(
        &self,
        envelope: EnvelopeId,
        fields: Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        let mut model = self.lock();
        require_approved(&model, "open a personal secret")?;
        let (kv, plaintext) = fake_open(&fields)?;
        take_kv(&mut model, ScopeName::Personal, &envelope.to_wire(), kv, in_force)?;
        Ok(opened(kv, &plaintext))
    }

    async fn seal_history_entry(&self, entry: HistoryId, plaintext: Value) -> Result<Value, SyncError> {
        let model = self.lock();
        require_approved(&model, "seal a history entry")?;
        let _ = entry;
        Ok(fake_seal(
            version(model.history_version.max(1))?,
            &json!({"entry": plaintext}),
        ))
    }

    async fn open_history_entry(&self, entry: HistoryId, fields: Value) -> Result<Value, SyncError> {
        let model = self.lock();
        require_approved(&model, "open a history entry")?;
        let _ = entry;
        let (_, plaintext) = fake_open(&fields)?;
        Ok(plaintext.get("entry").cloned().unwrap_or(Value::Null))
    }
}

pub(crate) fn opened(kv: Version, plaintext: &Value) -> OpenedEnvelope {
    OpenedEnvelope {
        secret: SecretString::from(
            plaintext
                .get("secret")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
        ),
        dest: plaintext.get("dest").cloned().unwrap_or(Value::Null),
        kv,
    }
}
