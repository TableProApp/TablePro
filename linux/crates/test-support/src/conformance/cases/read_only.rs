use tablepro_core::{EditorSessionOptions, ErrorCategory, ReadOnlyEnforcement, RunEnd, WorkspaceSettings, WriteKind};
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{
    apply, connect, count, create_scratch_table, expect, insert_sql, run_editor, run_options, unique, writable,
};
use crate::conformance::{ConformanceEngine, ConformanceFailure};

const CASE: &str = "read_only_connection_refuses_writes";

/// Case 7: a read-only connection refuses a save, and its editor refuses
/// both a row change and a schema change.
pub async fn read_only_connection_refuses_writes<E: ConformanceEngine>() -> Result<(), ConformanceFailure> {
    let engine = E::start().await?;
    let owner = connect(CASE, &engine, writable()).await?;
    let table = create_scratch_table(&engine, owner.as_ref(), "read_only").await?;
    let reader = connect(CASE, &engine, WorkspaceSettings::workspace(true)).await?;
    let insert = insert_sql(reader.dialect().as_ref(), &table, 1, "refused");

    let saved = apply(reader.as_ref(), &table, WriteKind::RowChanges, vec![insert.clone()]).await;
    let refused = matches!(&saved, Err(error) if error.category() == ErrorCategory::ReadOnly);
    expect(CASE, refused, || {
        format!("a save on a read-only connection gave {saved:?}")
    })?;

    // Where the login itself cannot write, the server's refusal depends
    // on how the test login was granted, so only the app's own guard is
    // part of the contract.
    if E::driver().capabilities().read_only != ReadOnlyEnforcement::LoginPrivileges {
        let session = reader
            .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
            .await?;
        let create = engine.create_scratch_table_sql(&engine.scratch_table(&unique("read_only_create")));
        for sql in [insert, create] {
            let (summary, _) = run_editor(session.as_ref(), &sql, run_options()).await?;
            let refused = matches!(&summary.end, RunEnd::Failed(error) if error.category() == ErrorCategory::ReadOnly);
            expect(CASE, refused, || {
                format!("`{sql}` on a read-only session ended {:?}", summary.end)
            })?;
        }
        session.close().await;
    }
    let rows = count(owner.as_ref(), &table).await?;
    expect(CASE, rows == 0, || {
        format!("{rows} rows reached a table only a read-only connection wrote to")
    })?;

    reader.close().await?;
    owner.close().await?;
    Ok(())
}
