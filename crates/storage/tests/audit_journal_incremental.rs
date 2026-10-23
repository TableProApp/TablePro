#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::io::Write;
use std::path::Path;

use tablepro_policy::Principal;
use tablepro_storage::{AuditJournal, sample_event};

fn rewrite_hash_digit_of_first_record(path: &Path) {
    let text = std::fs::read_to_string(path).unwrap();
    let marker = "\"hash\":\"";
    let start = text.find(marker).unwrap() + marker.len();
    let original = &text[start..=start];
    let replacement = if original == "0" { "1" } else { "0" };
    let tampered = format!("{}{}{}", &text[..start], replacement, &text[start + 1..]);
    assert_eq!(tampered.len(), text.len());
    std::fs::write(path, tampered).unwrap();
}

fn append_raw(path: &Path, bytes: &[u8]) {
    let mut file = std::fs::OpenOptions::new().append(true).open(path).unwrap();
    file.write_all(bytes).unwrap();
}

#[tokio::test]
async fn an_append_checks_only_records_written_since_its_last_check() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    for _ in 0..3 {
        journal.append(sample_event(Principal::human_gui())).await.unwrap();
    }

    rewrite_hash_digit_of_first_record(&path);

    journal.append(sample_event(Principal::human_gui())).await.unwrap();
    assert!(journal.verify_chain().await.is_err());
    assert!(journal.recent(10).await.is_err());
    drop(journal);
    assert!(AuditJournal::open_validated(path).is_err());
}

#[tokio::test]
async fn a_forged_record_from_another_writer_is_refused_before_appending() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    journal.append(sample_event(Principal::human_gui())).await.unwrap();
    let event = serde_json::to_string(&sample_event(Principal::human_gui())).unwrap();
    let forged = format!(
        "{{\"seq\":2,\"prev_hash\":\"{}\",\"hash\":\"{}\",\"event\":{event}}}\n",
        "0".repeat(64),
        "f".repeat(64)
    );

    append_raw(&path, forged.as_bytes());

    assert!(journal.append(sample_event(Principal::human_gui())).await.is_err());
    assert!(journal.verify_chain().await.is_err());
}

#[tokio::test]
async fn a_partial_record_left_by_a_crashed_writer_is_repaired_on_the_next_append() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    journal.append(sample_event(Principal::human_gui())).await.unwrap();

    append_raw(&path, b"{\"seq\":2,\"prev_hash\":\"trunc");

    journal.append(sample_event(Principal::human_gui())).await.unwrap();
    assert_eq!(journal.verify_chain().await.unwrap(), 2);
}

#[tokio::test]
async fn a_replaced_or_shortened_journal_is_fully_verified_before_appending() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    for _ in 0..3 {
        journal.append(sample_event(Principal::human_gui())).await.unwrap();
    }

    let replacement_dir = tempfile::TempDir::new().unwrap();
    let replacement = replacement_dir.path().join("audit.jsonl");
    {
        let other = AuditJournal::open_validated(replacement.clone()).unwrap();
        other.append(sample_event(Principal::human_gui())).await.unwrap();
    }
    std::fs::copy(&replacement, dir.path().join("replacement.jsonl")).unwrap();
    std::fs::rename(dir.path().join("replacement.jsonl"), &path).unwrap();

    journal.append(sample_event(Principal::human_gui())).await.unwrap();
    assert_eq!(journal.verify_chain().await.unwrap(), 2);

    let first_line = std::fs::read_to_string(&path).unwrap().lines().next().unwrap().len() + 1;
    std::fs::OpenOptions::new()
        .write(true)
        .open(&path)
        .unwrap()
        .set_len(first_line as u64)
        .unwrap();

    journal.append(sample_event(Principal::human_gui())).await.unwrap();
    assert_eq!(journal.verify_chain().await.unwrap(), 2);
}

#[tokio::test]
async fn a_second_owner_terminates_an_unterminated_last_record_before_appending() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let owner = AuditJournal::open_validated(path.clone()).unwrap();
    owner.append(sample_event(Principal::human_gui())).await.unwrap();
    let mut bytes = std::fs::read(&path).unwrap();
    assert_eq!(bytes.pop(), Some(b'\n'));
    std::fs::write(&path, &bytes).unwrap();

    let second = AuditJournal::open_validated(path.clone()).unwrap();
    second.append(sample_event(Principal::human_gui())).await.unwrap();

    assert_eq!(second.verify_chain().await.unwrap(), 2);
    drop(owner);
}
