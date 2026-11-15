#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    Core, FileOpenRequest, HostConfig, HostSecretError, HostSecrets, RunEvent, RunListener, RunOutcome, RunSettings,
    SecretItemTag, SecretKindTag, TruncationTag,
};

struct NoSecrets;

impl HostSecrets for NoSecrets {
    fn load(&self, _: String, _: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store(&self, _: String, _: SecretKindTag, _: SecretString, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn relabel(&self, _: String, _: SecretKindTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete(&self, _: String, _: SecretKindTag) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_connection(&self, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn load_item(&self, _: SecretItemTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store_item(&self, _: SecretItemTag, _: SecretString) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_item(&self, _: SecretItemTag) -> Result<(), HostSecretError> {
        Ok(())
    }
}

struct Quiet;

impl RunListener for Quiet {
    fn events_pending(&self) {}
}

fn core() -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: None,
        },
        Box::new(NoSecrets),
    )
    .unwrap()
}

const BLOBS: &str = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100) \
                     SELECT x, zeroblob(65536) FROM c";

#[tokio::test]
async fn a_run_keeps_whole_rows_up_to_its_byte_limit() {
    let dir = tempfile::tempdir().unwrap();
    let request = FileOpenRequest {
        path: dir.path().join("bytes.sqlite").display().to_string(),
        driver_id: None,
        read_only: false,
        create: true,
    };
    let core = core();
    let session = core.open_file(request, None).await.unwrap();
    let editor = session.open_editor(None, None).await.unwrap();
    let settings = RunSettings {
        byte_limit: Some(1 << 20),
        ..RunSettings::default()
    };

    let query = editor.run(BLOBS.to_owned(), settings, Box::new(Quiet));
    let outcome = query.outcome().await.unwrap();
    let events = query.drain_events();

    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    let reached: Vec<&RunEvent> = events
        .iter()
        .filter(|event| matches!(event, RunEvent::ByteLimitReached { .. }))
        .collect();
    // Each row is two values and 65,536 bytes, so the 16th crosses 1 MiB and is kept whole.
    assert_eq!(
        reached,
        [&RunEvent::ByteLimitReached {
            set_index: 0,
            retained: 16,
            limit_bytes: 1 << 20,
        }]
    );
    let finished = events
        .iter()
        .position(|event| matches!(event, RunEvent::ResultSetFinished { .. }))
        .unwrap();
    assert_eq!(
        events[finished],
        RunEvent::ResultSetFinished {
            set_index: 0,
            row_count: 16,
            total_rows: Some(100),
            truncation: TruncationTag::ByteLimit,
        }
    );
    let cut = events.iter().position(|event| event == reached[0]).unwrap();
    assert!(cut < finished, "{events:?}");
    let set = query.result_set(0).unwrap();
    assert_eq!(set.row_count(), 16);
    let last = set.cell_text(15, 1).unwrap().unwrap();
    assert_eq!(last.len(), 2 + 2 * 65_536, "the row that crossed the limit was cut");

    let next = editor.run("SELECT 1".to_owned(), RunSettings::default(), Box::new(Quiet));
    let after = next.outcome().await.unwrap();
    assert!(matches!(after, RunOutcome::Completed { .. }), "{after:?}");
}
