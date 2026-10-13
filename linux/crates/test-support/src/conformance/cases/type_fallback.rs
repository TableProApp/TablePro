use tablepro_core::{RowLimit, WriteKind};

use crate::conformance::support::{
    CALL_DEADLINE, apply, connect, create_scratch_table, expect, statement, within, writable,
};
use crate::conformance::{ConformanceFailure, TypedConformanceEngine};

const CASE: &str = "unsupported_types_never_decode_as_null";

/// Case 13: a value of a type the driver has no decoder for still reads
/// back as something, never as a NULL that would hide it.
pub async fn unsupported_types_never_decode_as_null<E: TypedConformanceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let cases = engine.unsupported_type_cases();
    expect(CASE, !cases.is_empty(), || {
        "the engine declares unsupported types but lists none".to_owned()
    })?;
    let connection = connect(CASE, &engine, writable()).await?;
    let dialect = connection.dialect();

    for (index, case) in cases.iter().enumerate() {
        let table = create_scratch_table(&engine, connection.as_ref(), &format!("types_{index}")).await?;
        let table_sql = dialect.qualify(&table);
        let value = dialect.quote_identifier("v");
        let mut schema = case.setup_sql.clone();
        schema.push(format!("ALTER TABLE {table_sql} ADD {}", case.declaration));
        apply(connection.as_ref(), &table, WriteKind::SchemaChanges, schema).await?;
        let insert = format!(
            "INSERT INTO {table_sql} ({}, {}, {value}) VALUES (1, 'typed', {})",
            dialect.quote_identifier("id"),
            dialect.quote_identifier("label"),
            case.insert_value_sql,
        );
        apply(connection.as_ref(), &table, WriteKind::RowChanges, vec![insert]).await?;

        let select = statement(&format!("SELECT {value} FROM {table_sql}"));
        let result = connection
            .query_bound(&select, RowLimit::EDITOR_DEFAULT, within(CALL_DEADLINE))
            .await?;
        let read = result.cell(0, 0);
        expect(CASE, read.is_some_and(|read| !read.is_null()), || {
            format!(
                "`{}` holding {} read back as {read:?}",
                case.declaration, case.insert_value_sql
            )
        })?;
    }
    connection.close().await?;
    Ok(())
}
