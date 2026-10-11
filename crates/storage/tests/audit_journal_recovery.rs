#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::os::unix::fs::PermissionsExt;

use sha2::{Digest, Sha256};
use tablepro_policy::{
    AuditAdministrativeAction, AuditEvent, AuditOperationClass, AuditRecordPhase, AuditSink, AuditTerminalStatus,
    AuditTransactionOutcome, Principal,
};
use tablepro_storage::{AuditJournal, sample_event};
use uuid::Uuid;

const GENESIS_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";

#[tokio::test]
async fn validated_open_creates_parent_and_private_file() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("nested").join("audit.jsonl");

    let journal = AuditJournal::open_validated(path.clone()).unwrap();

    assert_eq!(journal.path(), path);
    assert_eq!(
        std::fs::metadata(journal.path()).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(journal.verify_chain().await.unwrap(), 0);
}

#[tokio::test]
async fn validated_open_repairs_existing_file_mode() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    std::fs::write(&path, []).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();

    AuditJournal::open_validated(path.clone()).unwrap();

    assert_eq!(std::fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
}

#[tokio::test]
async fn validated_open_rejects_terminated_corruption() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    journal.append(sample_event(Principal::human_gui())).await.unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    let corrupted = text.replace("read_allow", "read_deny");
    assert_ne!(corrupted, text);
    std::fs::write(&path, corrupted).unwrap();

    assert!(AuditJournal::open_validated(path).is_err());
}

#[tokio::test]
async fn validated_open_truncates_only_trailing_partial_record() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    journal.append(sample_event(Principal::human_gui())).await.unwrap();
    let valid_len = std::fs::metadata(&path).unwrap().len();
    drop(journal);
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
    file.write_all(br#"{"seq":2,"prev_hash":"partial""#).unwrap();
    file.sync_data().unwrap();

    let recovered = AuditJournal::open_validated(path.clone()).unwrap();

    assert_eq!(std::fs::metadata(path).unwrap().len(), valid_len);
    assert_eq!(recovered.verify_chain().await.unwrap(), 1);
    recovered
        .append_durable(sample_event(Principal::human_gui()))
        .await
        .unwrap();
    assert_eq!(recovered.verify_chain().await.unwrap(), 2);
}

#[tokio::test]
async fn validated_open_upgrades_verified_legacy_journal() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let backup_path = dir.path().join("audit.jsonl.phase1");
    let legacy = legacy_journal();
    std::fs::write(&path, &legacy).unwrap();

    let journal = AuditJournal::open_validated(path.clone()).unwrap();

    let rotation = journal.recovery().legacy_journal().unwrap();
    assert_eq!(rotation.path(), backup_path);
    assert_eq!(rotation.records(), 2);
    assert_eq!(std::fs::read(&backup_path).unwrap(), legacy);
    assert_eq!(
        std::fs::metadata(&backup_path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(journal.verify_chain().await.unwrap(), 0);
    journal.append(sample_event(Principal::human_gui())).await.unwrap();
    assert_eq!(journal.verify_chain().await.unwrap(), 1);
}

#[tokio::test]
async fn validated_open_rejects_tampered_legacy_journal_without_rotation() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let legacy = legacy_journal();
    let tampered = String::from_utf8(legacy).unwrap().replace("SELECT 2", "DELETE 2");
    std::fs::write(&path, &tampered).unwrap();

    assert!(AuditJournal::open_validated(path.clone()).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), tampered);
    assert!(!dir.path().join("audit.jsonl.phase1").exists());
}

#[tokio::test]
async fn unresolved_recovery_remains_durable_without_duplicate_outcomes() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    let operation_id = Uuid::from_u128(1);
    journal
        .append_durable(intent_event(operation_id, AuditOperationClass::Mutation))
        .await
        .unwrap();
    drop(journal);

    let recovered = AuditJournal::open_validated(path.clone()).unwrap();
    assert_eq!(recovered.recovery().recovered_operation_ids(), &[operation_id]);
    assert_eq!(recovered.verify_chain().await.unwrap(), 2);
    drop(recovered);

    let second = AuditJournal::open_validated(path.clone()).unwrap();
    assert_eq!(second.recovery().recovered_operation_ids(), &[operation_id]);
    assert_eq!(second.verify_chain().await.unwrap(), 2);
    assert!(
        second
            .append_durable(intent_event(Uuid::from_u128(9), AuditOperationClass::Mutation))
            .await
            .is_err()
    );
    drop(second);

    let third = AuditJournal::open_validated(path).unwrap();
    assert_eq!(third.recovery().recovered_operation_ids(), &[operation_id]);
    assert_eq!(third.verify_chain().await.unwrap(), 2);
    let unknown_outcomes = third
        .recent(10)
        .await
        .unwrap()
        .into_iter()
        .filter(|event| {
            event.operation_id == operation_id
                && event.phase == AuditRecordPhase::Outcome
                && event.terminal_status == AuditTerminalStatus::Unknown
        })
        .count();
    assert_eq!(unknown_outcomes, 1);
}

#[tokio::test]
async fn interrupted_administrative_bundle_audit_recovers_as_unknown_write() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    let operation_id = Uuid::from_u128(0xB422);
    journal
        .record(AuditEvent::administrative_action(
            operation_id,
            AuditAdministrativeAction::ConnectionBundleImport,
            AuditRecordPhase::Intent,
            AuditTerminalStatus::Pending,
            2,
            None,
        ))
        .await
        .unwrap();
    drop(journal);

    let recovered = AuditJournal::open_validated(path).unwrap();

    assert!(recovered.recovery().has_unresolved_writes());
    assert_eq!(recovered.recovery().recovered_operation_ids(), &[operation_id]);
    let records = recovered.recent(10).await.unwrap();
    let unknown = records
        .iter()
        .find(|event| event.operation_id == operation_id && event.phase == AuditRecordPhase::Outcome)
        .expect("recovery records an unknown outcome");
    assert_eq!(unknown.terminal_status, AuditTerminalStatus::Unknown);
    assert_eq!(unknown.administrative_action.unwrap().affected_count, 2);
}

#[tokio::test]
async fn unmatched_read_is_recovered_once_without_poisoning_writes() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    let read_id = Uuid::from_u128(10);
    journal
        .append_durable(intent_event(read_id, AuditOperationClass::Read))
        .await
        .unwrap();
    drop(journal);

    let recovered = AuditJournal::open_validated(path.clone()).unwrap();
    assert!(!recovered.recovery().has_unresolved_writes());
    assert!(recovered.recovery().recovered_operation_ids().is_empty());
    assert_eq!(recovered.verify_chain().await.unwrap(), 2);
    let read_outcomes = recovered
        .recent(10)
        .await
        .unwrap()
        .into_iter()
        .filter(|event| {
            event.operation_id == read_id
                && event.phase == AuditRecordPhase::Outcome
                && event.terminal_status == AuditTerminalStatus::Unknown
        })
        .count();
    assert_eq!(read_outcomes, 1);
    drop(recovered);

    let reopened = AuditJournal::open_validated(path).unwrap();
    assert!(!reopened.recovery().has_unresolved_writes());
    assert_eq!(reopened.verify_chain().await.unwrap(), 2);
    reopened
        .append_durable(intent_event(Uuid::from_u128(11), AuditOperationClass::Mutation))
        .await
        .unwrap();
    assert_eq!(reopened.verify_chain().await.unwrap(), 3);
}

#[tokio::test]
async fn validated_open_does_not_recover_a_live_write_intent() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let first = AuditJournal::open_validated(path.clone()).unwrap();
    let operation_id = Uuid::from_u128(12);
    first
        .append_durable(intent_event(operation_id, AuditOperationClass::Mutation))
        .await
        .unwrap();

    let second = AuditJournal::open_validated(path).unwrap();
    assert!(second.recovery().recovered_operation_ids().is_empty());
    assert!(second.recovery().unresolved_operation_ids().is_empty());
    assert!(!second.recovery().has_unresolved_writes());

    let mut outcome = sample_event(Principal::human_gui());
    outcome.operation_id = operation_id;
    outcome.operation_class = AuditOperationClass::Mutation;
    first.append_durable(outcome).await.unwrap();

    let outcomes = second
        .recent(10)
        .await
        .unwrap()
        .into_iter()
        .filter(|event| event.operation_id == operation_id && event.phase == AuditRecordPhase::Outcome)
        .collect::<Vec<_>>();
    assert_eq!(outcomes.len(), 1);
    assert_eq!(outcomes[0].terminal_status, AuditTerminalStatus::Succeeded);
}

#[tokio::test]
async fn recovered_transaction_rollback_has_unknown_transaction_outcome() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    let operation_id = Uuid::from_u128(2);
    journal
        .append_durable(intent_event(operation_id, AuditOperationClass::TransactionRollback))
        .await
        .unwrap();
    drop(journal);

    let recovered = AuditJournal::open_validated(path).unwrap();
    let outcome = recovered
        .recent(2)
        .await
        .unwrap()
        .into_iter()
        .find(|event| event.phase == AuditRecordPhase::Outcome)
        .unwrap();

    assert_eq!(outcome.terminal_status, AuditTerminalStatus::Unknown);
    assert_eq!(outcome.transaction_outcome, AuditTransactionOutcome::Unknown);
}

#[tokio::test]
async fn second_handle_rejects_new_write_intent_while_allowing_reads_and_terminal_outcomes() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let first = AuditJournal::open_validated(path.clone()).unwrap();
    let second = AuditJournal::open_validated(path).unwrap();
    let pending_id = Uuid::from_u128(3);
    first
        .append_durable(intent_event(pending_id, AuditOperationClass::Mutation))
        .await
        .unwrap();

    let new_write = intent_event(Uuid::from_u128(4), AuditOperationClass::Mutation);
    assert!(second.append_durable(new_write).await.is_err());

    let mut read = intent_event(Uuid::from_u128(5), AuditOperationClass::Read);
    read.transaction_outcome = AuditTransactionOutcome::NotApplicable;
    second.append_durable(read).await.unwrap();

    let mut outcome = sample_event(Principal::human_gui());
    outcome.operation_id = pending_id;
    outcome.operation_class = AuditOperationClass::Mutation;
    second.append_durable(outcome).await.unwrap();

    second
        .append_durable(intent_event(Uuid::from_u128(6), AuditOperationClass::Mutation))
        .await
        .unwrap();
}

#[tokio::test]
async fn validated_open_preserves_complete_record_without_newline() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    journal.append(sample_event(Principal::human_gui())).await.unwrap();
    drop(journal);
    let mut bytes = std::fs::read(&path).unwrap();
    assert_eq!(bytes.pop(), Some(b'\n'));
    std::fs::write(&path, bytes).unwrap();

    let recovered = AuditJournal::open_validated(path.clone()).unwrap();

    assert_eq!(recovered.verify_chain().await.unwrap(), 1);
    assert_eq!(std::fs::read(path).unwrap().last(), Some(&b'\n'));
}

fn intent_event(operation_id: Uuid, operation_class: AuditOperationClass) -> tablepro_policy::AuditEvent {
    let mut event = sample_event(Principal::human_gui());
    event.operation_id = operation_id;
    event.phase = AuditRecordPhase::Intent;
    event.operation_class = operation_class;
    event.terminal_status = AuditTerminalStatus::Pending;
    event.transaction_outcome = if matches!(
        operation_class,
        AuditOperationClass::TransactionCommit | AuditOperationClass::TransactionRollback
    ) {
        AuditTransactionOutcome::Pending
    } else {
        AuditTransactionOutcome::NotApplicable
    };
    event.rows_affected = None;
    event.duration_ms = None;
    event
}

fn legacy_journal() -> Vec<u8> {
    let first = legacy_event("SELECT 1", "allow");
    let first_hash = legacy_hash(GENESIS_HASH, 1, &first);
    let second = legacy_event("SELECT 2", "allow");
    let second_hash = legacy_hash(&first_hash, 2, &second);
    format!(
        "{}\n{}\n",
        legacy_record(1, GENESIS_HASH, &first_hash, &first),
        legacy_record(2, &first_hash, &second_hash, &second)
    )
    .into_bytes()
}

fn legacy_event(sql: &str, decision_kind: &str) -> String {
    format!(
        concat!(
            r#"{{"timestamp":"2026-01-02T03:04:05Z","principal":{{"kind":"human","session":"gui"}},"#,
            r#""connection_id":"00000000-0000-0000-0000-000000000000","connection_name":"legacy","#,
            r#""environment":"local","driver_id":"postgres","sql":"{}","decision_rule":"read_allow","#,
            r#""decision_kind":"{}","rows_affected":1,"duration_ms":2,"error":null}}"#
        ),
        sql, decision_kind
    )
}

fn legacy_record(seq: u64, previous_hash: &str, hash: &str, event: &str) -> String {
    format!(r#"{{"seq":{seq},"prev_hash":"{previous_hash}","hash":"{hash}","event":{event}}}"#)
}

fn legacy_hash(previous_hash: &str, seq: u64, event: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(previous_hash.as_bytes());
    hasher.update(seq.to_string().as_bytes());
    hasher.update(event.as_bytes());
    hex::encode(hasher.finalize())
}
