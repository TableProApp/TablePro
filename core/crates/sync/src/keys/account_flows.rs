// `AccountFlows` (0056, Keys, The recovery key, Pins, Genesis, Sign Out, Replace, Envelopes and history, Rollback).

use async_trait::async_trait;
use secrecy::SecretString;
use serde_json::Value;
use tablepro_keys::encoding::{AccountId, HistoryId, KeyDeviceId, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_keys::keys::Ed25519Public;

use super::KeyService;
use crate::api::error::SyncError;
use crate::api::key_flows::{
    Acceptance, AccountFlows, DraftId, Fingerprint, GenesisOutcome, KeyApplied, KeyArrival, KeyChange, KeyNotice,
    KeyState, NoticeId, OpenedEnvelope, RecoveryKeyDraft, RotationDraft, SignOutOutcome, TypedBack,
};

#[async_trait]
impl AccountFlows for KeyService {
    async fn key_state(&self) -> Result<KeyState, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let mut txn = self.begin().await?;
        self.state_of_keys(txn.as_mut()).await
    }

    async fn begin_genesis(&self) -> Result<RecoveryKeyDraft, SyncError> {
        self.start_genesis().await
    }

    async fn finish_genesis(&self, draft: DraftId, typed: TypedBack) -> Result<GenesisOutcome, SyncError> {
        self.complete_genesis(draft, &typed).await
    }

    async fn sign_out(&self) -> Result<SignOutOutcome, SyncError> {
        self.erase_on_sign_out().await
    }

    async fn begin_replace(&self, recovery_key: SecretString) -> Result<RotationDraft, SyncError> {
        self.start_replace(&recovery_key).await
    }

    async fn finish_replace(&self, draft: DraftId, typed: TypedBack, keep: Vec<KeyDeviceId>) -> Result<(), SyncError> {
        self.complete_replace(draft, &typed, &keep).await
    }

    async fn own_fingerprint(&self) -> Result<Fingerprint, SyncError> {
        self.fingerprint_of_account(self.account()).await
    }

    async fn fingerprint(&self, account: AccountId) -> Result<Fingerprint, SyncError> {
        self.fingerprint_of_account(account).await
    }

    async fn compare_qr(&self, account: AccountId, text: String) -> Result<bool, SyncError> {
        self.compare_scanned(account, &text).await
    }

    async fn key_change(&self, account: AccountId) -> Result<Option<KeyChange>, SyncError> {
        let _serial = self.serialized().await;
        self.finish_cut_off_sign_out().await?;
        let mut txn = self.begin().await?;
        self.open_key_change(txn.as_mut(), account).await
    }

    async fn accept_key_change(
        &self,
        account: AccountId,
        offered: Ed25519Public,
        how: Acceptance,
    ) -> Result<(), SyncError> {
        self.reconfirm(account, offered, how).await
    }

    async fn notices(&self) -> Result<Vec<KeyNotice>, SyncError> {
        Ok(self.held_notices())
    }

    async fn dismiss_notice(&self, notice: NoticeId) -> Result<(), SyncError> {
        if self.dismiss(notice) {
            Ok(())
        } else {
            Err(SyncError::Unknown { what: "notice" })
        }
    }

    async fn apply_account_objects(&self, arrival: KeyArrival) -> Result<KeyApplied, SyncError> {
        self.apply_personal_arrival(&arrival).await
    }

    async fn seal_personal_envelope(
        &self,
        envelope: EnvelopeId,
        secret: SecretString,
        dest: Value,
    ) -> Result<Value, SyncError> {
        self.seal_personal(&envelope, &secret, &dest).await
    }

    async fn open_personal_envelope(
        &self,
        envelope: EnvelopeId,
        fields: Value,
        in_force: Option<Version>,
    ) -> Result<OpenedEnvelope, SyncError> {
        self.open_personal(&envelope, &fields, in_force).await
    }

    async fn seal_history_entry(&self, entry: HistoryId, plaintext: Value) -> Result<Value, SyncError> {
        self.seal_history(entry, &plaintext).await
    }

    async fn open_history_entry(&self, entry: HistoryId, fields: Value) -> Result<Value, SyncError> {
        self.open_history(entry, &fields).await
    }
}
