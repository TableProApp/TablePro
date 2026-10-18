use std::sync::Arc;

use tablepro_core::meta::TableRef;
use tablepro_session::{OperationError, OperationKind, Session};
use tokio_util::sync::CancellationToken;

use super::LoadedStructure;
use crate::ui::tab_load::LoadFailure;

/// The table's columns, indexes and foreign keys from one read, so the
/// tab never shows lists from different moments side by side, and any
/// part that fails fails the whole read rather than showing an empty
/// list as if the table had none. The read always asks the server: the
/// catalog keeps columns only, and a definition is edited against what
/// the table is now.
pub(crate) async fn fetch_structure(
    session: Arc<Session>,
    table: TableRef,
    cancel: CancellationToken,
) -> Result<LoadedStructure, LoadFailure> {
    let loaded = session
        .run_cancellable(OperationKind::Metadata, &cancel, move |lease, options| {
            let table = table.clone();
            async move {
                let definition = lease.fetch_table_definition(&table, options).await?;
                Ok(LoadedStructure {
                    definition,
                    dialect: lease.dialect(),
                })
            }
        })
        .await
        .map_err(|error| {
            if error != OperationError::Cancelled {
                tracing::warn!(category = ?error.category(), "structure read failed");
            }
            LoadFailure::Definition(Arc::new(error))
        })?;
    match loaded.definition.columns.is_empty() {
        true => Err(LoadFailure::NoColumns),
        false => Ok(loaded),
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tablepro_core::DriverError;
    use tablepro_core::ddl::TableDefinition;
    use tablepro_test_support::{ConnectionScript, FakeReply};

    use super::*;
    use crate::test_support::{FakeSession, finish_on_main};

    const WAIT: Duration = Duration::from_secs(10);

    fn read(script: ConnectionScript) -> Result<LoadedStructure, LoadFailure> {
        let runtime = crate::test_support::test_runtime();
        let fake = FakeSession::start(script, [], runtime.tasks());
        let running = runtime.tasks().spawn_task(fetch_structure(
            fake.session.clone(),
            TableRef::unqualified("users"),
            CancellationToken::new(),
        ));
        let outcome = finish_on_main(WAIT, running).expect("the read ends");
        runtime.shutdown();
        outcome.expect("the read ran to its end")
    }

    #[gtk4::test]
    fn fetch_structure_fails_whole_on_foreign_key_error() {
        let mut script = ConnectionScript::default();
        script
            .fetch_table_definition
            .always(FakeReply::err(DriverError::server("foreign keys unreadable")));

        let failure = read(script).expect_err("a failed read");

        assert!(matches!(failure, LoadFailure::Definition(_)), "{failure:?}");
        assert!(
            failure.message().contains("foreign keys unreadable"),
            "{}",
            failure.message()
        );
    }

    #[gtk4::test]
    fn a_definition_without_columns_is_a_failure() {
        let mut script = ConnectionScript::default();
        script.fetch_table_definition.always(FakeReply::ok(TableDefinition {
            table: TableRef::unqualified("users"),
            columns: Vec::new(),
            primary_key: None,
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        }));

        let failure = read(script).expect_err("a failed read");

        assert!(matches!(failure, LoadFailure::NoColumns), "{failure:?}");
    }
}
