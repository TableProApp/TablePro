#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::process::Command;
use std::sync::Arc;

use tablepro_policy::Principal;
use tablepro_storage::{AuditJournal, sample_event};

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn one_thousand_concurrent_appends_produce_one_chain() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = Arc::new(AuditJournal::open_validated(path).unwrap());
    let mut tasks = Vec::with_capacity(1000);

    for index in 0..1000 {
        let journal = Arc::clone(&journal);
        tasks.push(tokio::spawn(async move {
            let mut event = sample_event(Principal::human_gui());
            event.operation_id = uuid::Uuid::from_u128(index + 1);
            journal.append(event).await.unwrap();
        }));
    }

    for task in tasks {
        task.await.unwrap();
    }

    assert_eq!(journal.verify_chain().await.unwrap(), 1000);
    assert_eq!(journal.recent(1000).await.unwrap().len(), 1000);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_processes_cannot_fork_the_sequence() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let journal = AuditJournal::open_validated(path.clone()).unwrap();
    let executable = std::env::current_exe().unwrap();
    let mut first = Command::new(&executable)
        .args(["--exact", "process_writer", "--nocapture"])
        .env("TABLEPRO_AUDIT_TEST_PATH", &path)
        .spawn()
        .unwrap();
    let mut second = Command::new(executable)
        .args(["--exact", "process_writer", "--nocapture"])
        .env("TABLEPRO_AUDIT_TEST_PATH", &path)
        .spawn()
        .unwrap();

    assert!(first.wait().unwrap().success());
    assert!(second.wait().unwrap().success());
    assert_eq!(journal.verify_chain().await.unwrap(), 200);
}

#[test]
fn process_writer() {
    let Some(path) = std::env::var_os("TABLEPRO_AUDIT_TEST_PATH") else {
        return;
    };
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let journal = AuditJournal::open_validated(path.into()).unwrap();
        for _ in 0..100 {
            journal.append(sample_event(Principal::human_gui())).await.unwrap();
        }
    });
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn independently_opened_handles_share_a_valid_chain() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("audit.jsonl");
    let first = Arc::new(AuditJournal::open_validated(path.clone()).unwrap());
    let second = Arc::new(AuditJournal::open_validated(path).unwrap());
    let mut tasks = Vec::with_capacity(200);

    for index in 0..200 {
        let journal = if index % 2 == 0 {
            Arc::clone(&first)
        } else {
            Arc::clone(&second)
        };
        tasks.push(tokio::spawn(async move {
            journal.append(sample_event(Principal::human_gui())).await.unwrap();
        }));
    }

    for task in tasks {
        task.await.unwrap();
    }

    assert_eq!(first.verify_chain().await.unwrap(), 200);
}
