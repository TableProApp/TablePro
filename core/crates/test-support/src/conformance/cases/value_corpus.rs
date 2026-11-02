use std::collections::BTreeMap;
use std::sync::Arc;

use tablepro_core::browse::{
    BrowseSqlError, DeclaredPrecisionSink, ExportRequest, PageRequest, build_export, read_page,
};
use tablepro_core::column::{ColumnInfo, ColumnType, ResultColumn};
use tablepro_core::export::value_text;
use tablepro_core::filter::FilterSet;
use tablepro_core::meta::PagePosition;
use tablepro_core::value::Value;
use tablepro_core::{Connection, DriverError, EditorSession, EditorSessionOptions, ReadStatement, TableRef, WriteKind};
use tokio_util::sync::CancellationToken;

use crate::conformance::support::{
    CALL_DEADLINE, Collected, apply, connect, expect, run_completed, run_options, unique, within, writable,
};
use crate::conformance::{ConformanceEngine, ConformanceFailure, CorpusColumn, ValueCorpusEngine};

const CASE: &str = "value_corpus_reads_as_the_grid_shows";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Path {
    Browse,
    Export,
    Editor,
}

/// The rows a page holds, by `id`, and the type the grid draws `v` with.
struct Read {
    column_type: ColumnType,
    values: BTreeMap<i64, Value>,
}

/// Case 17: every value of the engine's corpus reads back, in a table
/// tab's page, a table export and an editor run, as the text its entry
/// names. A wrong text is a decoder bug, and every one is listed at once.
pub async fn value_corpus_reads_as_the_grid_shows<E: ValueCorpusEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let corpus = engine.value_corpus();
    expect(CASE, !corpus.is_empty(), || "the engine lists no corpus".to_owned())?;
    let connection = connect(CASE, &engine, writable()).await?;
    let session = connection
        .open_editor_session(EditorSessionOptions::default(), CancellationToken::new())
        .await?;
    let mut wrong = Vec::new();
    for (index, column) in corpus.iter().enumerate() {
        // A column the server refuses is listed with the wrong values,
        // so one run reports the whole corpus.
        let table = match load(&engine, connection.as_ref(), &format!("corpus_{index}"), column).await {
            Ok(table) => table,
            Err(failure) => {
                wrong.push(failure.to_string());
                continue;
            }
        };
        let browsed = browse(connection.as_ref(), &table).await?;
        compare(Path::Browse, column, &browsed, &mut wrong);
        let exported = export(connection.as_ref(), &table).await?;
        compare(Path::Export, column, &exported, &mut wrong);
        let edited = edit(session.as_ref(), connection.as_ref(), &table).await?;
        compare(Path::Editor, column, &edited, &mut wrong);
    }
    session.close().await;
    connection.close().await?;
    expect(CASE, wrong.is_empty(), || {
        format!(
            "{} values did not read back as written:\n{}",
            wrong.len(),
            wrong.join("\n")
        )
    })
}

/// A scratch table holding `column` as `v`, with a row for each of its
/// values.
pub(crate) async fn load<E: ConformanceEngine>(
    engine: &E,
    connection: &dyn Connection,
    prefix: &str,
    column: &CorpusColumn,
) -> Result<TableRef, ConformanceFailure> {
    let table = corpus_table(engine, connection, prefix, column, &column.setup_sql).await?;
    let dialect = connection.dialect();
    let table_sql = dialect.qualify(&table);
    let names = [
        dialect.quote_identifier("id"),
        dialect.quote_identifier("label"),
        dialect.quote_identifier("v"),
    ]
    .join(", ");
    let inserts = column
        .values
        .iter()
        .enumerate()
        .map(|(row, value)| {
            format!(
                "INSERT INTO {table_sql} ({names}) VALUES ({row}, 'corpus', {})",
                value.sql
            )
        })
        .collect();
    apply(connection, &table, WriteKind::RowChanges, inserts)
        .await
        .map_err(|error| ConformanceFailure::setup(format!("`{}` values: {error}", column.declaration)))?;
    Ok(table)
}

/// An empty scratch table with `column` added as `v`, after `setup`. A
/// second table of the same column passes no setup: a type it creates
/// already exists.
pub(crate) async fn corpus_table<E: ConformanceEngine>(
    engine: &E,
    connection: &dyn Connection,
    prefix: &str,
    column: &CorpusColumn,
    setup: &[String],
) -> Result<TableRef, ConformanceFailure> {
    let table = engine.scratch_table(&unique(prefix));
    let mut schema = vec![engine.create_scratch_table_sql(&table)];
    schema.extend_from_slice(setup);
    schema.push(format!(
        "ALTER TABLE {} ADD {}",
        connection.dialect().qualify(&table),
        column.declaration
    ));
    apply(connection, &table, WriteKind::SchemaChanges, schema)
        .await
        .map_err(|error| ConformanceFailure::setup(format!("`{}`: {error}", column.declaration)))?;
    Ok(table)
}

/// The first page of the table, read by `read_page` as the browse tab
/// reads one.
async fn browse(connection: &dyn Connection, table: &TableRef) -> Result<Read, ConformanceFailure> {
    let columns = connection.fetch_columns(table, within(CALL_DEADLINE)).await?;
    let identity = connection.row_identity(table, within(CALL_DEADLINE)).await?;
    let filter = FilterSet::default();
    let request = PageRequest {
        table,
        columns: &columns,
        filter: &filter,
        sort: &[],
        identity: &identity,
        position: &PagePosition::First,
        limit: 1_000,
    };
    let page = read_page::<PageFailure>(connection, &request, &within(CALL_DEADLINE))
        .await
        .map_err(|failure| match failure {
            PageFailure::Sql(error) => ConformanceFailure::setup(error),
            PageFailure::Driver(error) => ConformanceFailure::Driver(error),
        })?;
    let visible = page.layout.visible.clone();
    let rows = page
        .result
        .rows
        .into_iter()
        .map(|mut row| {
            row.truncate(visible.end);
            row
        })
        .collect();
    by_id(page.result.columns.get(visible).unwrap_or_default(), rows)
}

/// Every row of the table, read as Export All reads a table tab.
async fn export(connection: &dyn Connection, table: &TableRef) -> Result<Read, ConformanceFailure> {
    let columns: Arc<[ColumnInfo]> = connection.fetch_columns(table, within(CALL_DEADLINE)).await?.into();
    let identity = connection.row_identity(table, within(CALL_DEADLINE)).await?;
    let statement = build_export(
        &*connection.dialect(),
        &ExportRequest {
            table,
            columns: &columns,
            filter: &FilterSet::default(),
            sort: &[],
            identity: &identity,
        },
    )
    .map_err(ConformanceFailure::setup)?;
    let collected = Collected::default();
    let sink = DeclaredPrecisionSink::new(collected.sink(), Arc::clone(&columns));
    connection
        .stream_read(
            &ReadStatement::Generated(statement),
            Box::new(sink),
            within(CALL_DEADLINE),
        )
        .await?;
    let columns = collected
        .columns()
        .ok_or_else(|| ConformanceFailure::setup("the export started no result set"))?;
    by_id(&columns, collected.rows())
}

enum PageFailure {
    Sql(BrowseSqlError),
    Driver(DriverError),
}

impl From<BrowseSqlError> for PageFailure {
    fn from(error: BrowseSqlError) -> Self {
        Self::Sql(error)
    }
}

impl From<DriverError> for PageFailure {
    fn from(error: DriverError) -> Self {
        Self::Driver(error)
    }
}

async fn edit(
    session: &dyn EditorSession,
    connection: &dyn Connection,
    table: &TableRef,
) -> Result<Read, ConformanceFailure> {
    let dialect = connection.dialect();
    let id = dialect.quote_identifier("id");
    let sql = format!(
        "SELECT {id}, {} FROM {}",
        dialect.quote_identifier("v"),
        dialect.qualify(table)
    );
    let collected = run_completed(CASE, session, &sql, run_options()).await?;
    let columns = collected
        .columns()
        .ok_or_else(|| ConformanceFailure::setup(format!("`{sql}` started no result set")))?;
    by_id(&columns, collected.rows())
}

fn by_id(columns: &[ResultColumn], rows: Vec<Vec<Value>>) -> Result<Read, ConformanceFailure> {
    let position = |name: &str| {
        columns
            .iter()
            .position(|column| column.name == name)
            .ok_or_else(|| ConformanceFailure::setup(format!("no `{name}` column in {columns:?}")))
    };
    let (id, v) = (position("id")?, position("v")?);
    let mut values = BTreeMap::new();
    for mut row in rows {
        // An editor run on PostgreSQL reads every value as the server's text.
        let key = match row.get(id) {
            Some(Value::Int(key)) => Some(*key),
            Some(Value::UInt(key)) => i64::try_from(*key).ok(),
            Some(Value::Text(key)) => key.parse().ok(),
            _ => None,
        };
        let Some(key) = key else {
            return Err(ConformanceFailure::setup(format!("an id read as {:?}", row.get(id))));
        };
        if v < row.len() {
            values.insert(key, row.swap_remove(v));
        }
    }
    Ok(Read {
        column_type: columns[v].column_type.clone(),
        values,
    })
}

fn compare(path: Path, column: &CorpusColumn, read: &Read, wrong: &mut Vec<String>) {
    let path_name = match path {
        Path::Browse => "browse",
        Path::Export => "export",
        Path::Editor => "editor",
    };
    for (row, value) in column.values.iter().enumerate() {
        let declaration = &column.declaration;
        let sql = &value.sql;
        let expected = match (path, &value.edited) {
            (Path::Editor, Some(edited)) => Some(edited.as_str()),
            _ => value.shown.as_deref(),
        };
        let Some(read_value) = i64::try_from(row).ok().and_then(|row| read.values.get(&row)) else {
            wrong.push(format!("{path_name}: `{declaration}` lost the row holding {sql}"));
            continue;
        };
        let shown = shown(read_value, &read.column_type);
        if shown.as_deref() != expected {
            wrong.push(format!(
                "{path_name}: `{declaration}` holding {sql} shows {} as {}, expected {}",
                quoted(shown.as_deref()),
                read_value.variant_name(),
                quoted(expected),
            ));
        }
    }
}

/// The text the grid shows for `value` in a column of `column_type`,
/// `None` for NULL.
pub(crate) fn shown(value: &Value, column_type: &ColumnType) -> Option<String> {
    match value {
        Value::Null => None,
        // What the grid shows for a value the driver could not read.
        Value::Undecodable(undecoded) => Some(format!("<unreadable {}>", undecoded.type_name)),
        other => Some(value_text(other, column_type).unwrap_or_else(|| format!("<{other:?}>"))),
    }
}

pub(crate) fn quoted(text: Option<&str>) -> String {
    match text {
        Some(text) => format!("{text:?}"),
        None => "NULL".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::ColumnKind;
    use tablepro_core::value::{SqlDecimal, UndecodableReason, UndecodedValue};

    use super::*;

    fn decimal(precision: u32, scale: u32) -> ColumnType {
        let mut column_type = ColumnType::unknown();
        column_type.kind = ColumnKind::Decimal {
            precision: Some(precision),
            scale: Some(scale),
        };
        column_type
    }

    fn read(column_type: ColumnType, values: Vec<Value>) -> Read {
        Read {
            column_type,
            values: (0..).zip(values).collect(),
        }
    }

    fn column() -> CorpusColumn {
        CorpusColumn::new("v numeric(10, 2)")
            .shows("1.5", "1.50")
            .shows_apart("2", "2.00", "2")
            .null()
    }

    #[test]
    fn a_value_shows_at_the_scale_of_the_column_it_came_back_in() {
        let mut wrong = Vec::new();
        let values = vec![
            Value::Decimal("1.5".parse::<SqlDecimal>().unwrap()),
            Value::Decimal("2".parse::<SqlDecimal>().unwrap()),
            Value::Null,
        ];

        compare(Path::Browse, &column(), &read(decimal(10, 2), values), &mut wrong);

        assert_eq!(wrong, Vec::<String>::new());
    }

    #[test]
    fn every_wrong_or_missing_value_is_listed() {
        let mut wrong = Vec::new();
        let values = vec![Value::Text("1.5".to_owned()), Value::Int(2)];

        compare(
            Path::Editor,
            &column(),
            &read(ColumnType::unknown(), values),
            &mut wrong,
        );

        assert_eq!(
            wrong,
            [
                r#"editor: `v numeric(10, 2)` holding 1.5 shows "1.5" as Text, expected "1.50""#,
                "editor: `v numeric(10, 2)` lost the row holding NULL",
            ]
        );
    }

    #[test]
    fn a_null_where_a_value_belongs_is_wrong() {
        let mut wrong = Vec::new();
        let values = vec![Value::Null, Value::Int(2), Value::Null];

        compare(
            Path::Editor,
            &column(),
            &read(ColumnType::unknown(), values),
            &mut wrong,
        );

        assert_eq!(
            wrong,
            [r#"editor: `v numeric(10, 2)` holding 1.5 shows NULL as Null, expected "1.50""#]
        );
    }

    #[test]
    fn a_value_the_driver_could_not_read_shows_as_the_grid_shows_it() {
        let mut wrong = Vec::new();
        let undecoded = Value::Undecodable(Box::new(UndecodedValue {
            type_name: "money".to_owned(),
            reason: UndecodableReason::OutOfRange,
        }));
        let column = CorpusColumn::new("v money").shows_apart("1", "1", "<unreadable money>");

        compare(
            Path::Editor,
            &column,
            &read(ColumnType::unknown(), vec![undecoded]),
            &mut wrong,
        );

        assert_eq!(wrong, Vec::<String>::new());
    }

    #[test]
    fn rows_are_keyed_by_their_id_whatever_order_they_came_in() {
        let columns = [
            ResultColumn::new("v", ColumnType::unknown()),
            ResultColumn::new("id", ColumnType::unknown()),
        ];
        let rows = vec![
            vec![Value::Text("c".to_owned()), Value::Text("2".to_owned())],
            vec![Value::Text("b".to_owned()), Value::UInt(1)],
            vec![Value::Text("a".to_owned()), Value::Int(0)],
        ];

        let read = by_id(&columns, rows).unwrap();

        assert_eq!(
            read.values.into_iter().collect::<Vec<_>>(),
            [
                (0, Value::Text("a".to_owned())),
                (1, Value::Text("b".to_owned())),
                (2, Value::Text("c".to_owned()))
            ]
        );
    }
}
