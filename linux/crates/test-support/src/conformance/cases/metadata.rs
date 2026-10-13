use tablepro_core::meta::{ObjectKind, ObjectScope, RowIdentity};

use crate::conformance::support::{CALL_DEADLINE, connect, create_scratch_table, expect, within, writable};
use crate::conformance::{ConformanceEngine, ConformanceFailure};

const CASE: &str = "lists_created_table_with_primary_key_and_unique_identity";

/// Case 1: a table the suite creates shows up in the default schema, its
/// key column is marked, and its rows can be named again by that key.
pub async fn lists_created_table_with_primary_key_and_unique_identity<E: ConformanceEngine>()
-> Result<(), ConformanceFailure> {
    let engine = E::start().await?;
    let connection = connect(CASE, &engine, writable()).await?;
    let table = create_scratch_table(&engine, connection.as_ref(), "metadata").await?;

    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL_DEADLINE))
        .await?;
    let listed = objects
        .iter()
        .any(|object| object.name == table.name && object.kind == ObjectKind::Table);
    expect(CASE, listed, || format!("{} is not a table in {objects:?}", table.name))?;

    let columns = connection.fetch_columns(&table, within(CALL_DEADLINE)).await?;
    let keys: Vec<&str> = columns
        .iter()
        .filter(|column| column.primary_key)
        .map(|column| column.name.as_str())
        .collect();
    expect(CASE, keys == ["id"], || format!("the primary key columns are {keys:?}"))?;

    let identity = connection.row_identity(&table, within(CALL_DEADLINE)).await?;
    let names_id = match &identity {
        RowIdentity::UniqueKey { columns } => columns.iter().map(String::as_str).eq(["id"]),
        // ClickHouse has no unique constraint, so its primary key comes
        // back as the sorting key it is, still naming the row by id.
        RowIdentity::SortingKey { expressions } => expressions.iter().map(String::as_str).eq(["id"]),
        RowIdentity::EngineRowId(_) | RowIdentity::Unordered => false,
    };
    expect(CASE, names_id, || {
        format!("the row identity {identity:?} does not name id")
    })?;

    connection.close().await?;
    Ok(())
}

const SHARED_CASE: &str = "calls_share_one_call_options";

/// One operation hands the same options to each of its calls, as a page
/// does for its columns, its row identity and its rows: a call that
/// finishes leaves them usable for the next.
pub async fn calls_share_one_call_options<E: ConformanceEngine>() -> Result<(), ConformanceFailure> {
    let engine = E::start().await?;
    let connection = connect(SHARED_CASE, &engine, writable()).await?;
    let table = create_scratch_table(&engine, connection.as_ref(), "shared").await?;
    let options = within(CALL_DEADLINE);

    let columns = connection.fetch_columns(&table, options.clone()).await;
    let identity = connection.row_identity(&table, options.clone()).await;
    let objects = connection.list_objects(&ObjectScope::DefaultSchema, options).await;

    expect(
        SHARED_CASE,
        columns.is_ok() && identity.is_ok() && objects.is_ok(),
        || format!("calls sharing one set of options: columns {columns:?}, identity {identity:?}, objects {objects:?}"),
    )?;
    connection.close().await?;
    Ok(())
}
