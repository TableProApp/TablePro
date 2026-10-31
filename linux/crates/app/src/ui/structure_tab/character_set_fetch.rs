use std::sync::Arc;

use tablepro_core::ddl::CharacterSet;
use tablepro_session::{OperationError, OperationKind, Session};
use tokio_util::sync::CancellationToken;

/// The server's character sets and their collations: a read of its own
/// after the definition's, since they belong to the server rather than
/// the table, and a table whose list cannot be read is still edited.
pub(crate) async fn fetch_character_sets(
    session: Arc<Session>,
    cancel: CancellationToken,
) -> Result<Vec<CharacterSet>, Arc<OperationError>> {
    session
        .run_cancellable(OperationKind::Metadata, &cancel, |lease, options| async move {
            Ok(lease.fetch_character_sets(options).await?)
        })
        .await
        .map_err(|error| {
            if error != OperationError::Cancelled {
                tracing::warn!(category = ?error.category(), "character set read failed");
            }
            Arc::new(error)
        })
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::DriverError;
    use tablepro_test_support::{ConnectionScript, FakeReply};

    use super::*;
    use crate::test_support::{FakeSession, finish_on_main};

    const WAIT: Duration = Duration::from_secs(10);

    fn read(script: ConnectionScript) -> Result<Vec<CharacterSet>, Arc<OperationError>> {
        let runtime = crate::test_support::test_runtime();
        let fake = FakeSession::start(script, [], runtime.tasks());
        let running = runtime
            .tasks()
            .spawn_task(fetch_character_sets(fake.session.clone(), CancellationToken::new()));
        let outcome = finish_on_main(WAIT, running).expect("the read ends");
        runtime.shutdown();
        outcome.expect("the read ran to its end")
    }

    #[gtk4::test]
    fn the_character_sets_come_back_as_the_server_lists_them() {
        let latin1 = CharacterSet {
            name: "latin1".to_owned(),
            default_collation: "latin1_swedish_ci".to_owned(),
            collations: vec!["latin1_bin".to_owned(), "latin1_swedish_ci".to_owned()],
        };
        let mut script = ConnectionScript::default();
        script.fetch_character_sets.always(FakeReply::ok(vec![latin1.clone()]));

        assert_eq!(read(script), Ok(vec![latin1]));
    }

    #[gtk4::test]
    fn a_failed_read_keeps_the_driver_error() {
        let mut script = ConnectionScript::default();
        script
            .fetch_character_sets
            .always(FakeReply::err(DriverError::server("no information_schema")));

        assert_eq!(
            read(script),
            Err(Arc::new(OperationError::Driver(DriverError::server(
                "no information_schema"
            ))))
        );
    }
}
