use tablepro_core::column::{ColumnOrigin, ResultColumn};
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::{SqlGrammar, source_table};
use tablepro_core::value::Value;
use tracing::debug;

use crate::catalog::Cells;
use crate::dialect::quote;
use crate::errors::ends_connection;
use crate::in_band_request::{Interrupt, Watch};
use crate::physical::MssqlClient;
use crate::workspace_call::{catalogue_rows, text_param};

// Mode 1 traces a view or a synonym through to its base table, so a column counts only when the statement's own name resolves to that table.
// Inside a transaction, or where IMPLICIT_TRANSACTIONS would open one, nothing is described: the describe must neither fail inside the user's work nor start it.
const DESCRIBE_SQL: &str = "IF @@TRANCOUNT = 0 AND (@@OPTIONS & 2) = 0 \
    SELECT d.column_ordinal, d.name, d.is_hidden, d.source_schema, d.source_table, d.source_column, \
        CAST(CASE WHEN d.source_server IS NULL AND DB_ID(d.source_database) = DB_ID() \
            AND OBJECT_ID(QUOTENAME(d.source_schema) + N'.' + QUOTENAME(d.source_table), N'U') = OBJECT_ID(@P2) \
            THEN 1 ELSE 0 END AS bit) \
    FROM sys.dm_exec_describe_first_result_set(@P1, NULL, 1) AS d";

const DESCRIBED_WIDTH: usize = 7;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Origins(Vec<(String, Option<ColumnOrigin>)>);

impl Origins {
    // A describe whose columns are not the result's saw another statement: the schema changed in between, or a session setting reshaped one of them.
    pub(crate) fn attach(self, columns: Vec<ResultColumn>) -> Vec<ResultColumn> {
        let same = self.0.len() == columns.len()
            && self
                .0
                .iter()
                .zip(&columns)
                .all(|((name, _), column)| *name == column.name);
        if !same {
            return columns;
        }
        columns
            .into_iter()
            .zip(self.0)
            .map(|(column, (_, origin))| column.with_origin(origin))
            .collect()
    }
}

pub(crate) async fn describe(
    client: &mut MssqlClient,
    watch: &Watch,
    batch: &str,
) -> Result<Option<Origins>, Interrupt> {
    let Ok(statement) = source_table(batch, SqlGrammar::MsSql) else {
        return Ok(None);
    };
    // A temporary table lives in tempdb under a name only this session resolves.
    if statement.table.name.starts_with('#') {
        return Ok(None);
    }
    let params = [text_param(batch), text_param(&written_name(&statement.table))];
    match catalogue_rows(client, watch, DESCRIBE_SQL, &params).await {
        Ok(rows) => Ok(origins(&rows)),
        // The user's batch has not been sent yet, so a refused describe only leaves its result untraced.
        Err(Interrupt::Failed(error)) if !ends_connection(&error) => {
            debug!(%error, "an editor result could not be described");
            Ok(None)
        }
        Err(interrupt) => Err(interrupt),
    }
}

fn written_name(table: &TableRef) -> String {
    match &table.schema {
        Some(schema) => format!("{}.{}", quote(schema), quote(&table.name)),
        None => quote(&table.name),
    }
}

fn origins(rows: &[Vec<Value>]) -> Option<Origins> {
    let mut shown = Vec::with_capacity(rows.len());
    for row in rows {
        if row.len() != DESCRIBED_WIDTH {
            return None;
        }
        let cells = Cells::new(row, "sys.dm_exec_describe_first_result_set");
        // A batch the server cannot describe comes back as one row with an error number and no ordinal.
        let ordinal = cells.int(0)?;
        if cells.flag(2) {
            continue;
        }
        shown.push((ordinal, cells.text(1).unwrap_or_default(), origin(&cells)));
    }
    shown.sort_by_key(|(ordinal, _, _)| *ordinal);
    let numbered = shown
        .iter()
        .zip(1_i64..)
        .all(|((ordinal, _, _), position)| *ordinal == position);
    (numbered && !shown.is_empty())
        .then(|| Origins(shown.into_iter().map(|(_, name, origin)| (name, origin)).collect()))
}

fn origin(cells: &Cells<'_>) -> Option<ColumnOrigin> {
    if !cells.flag(6) {
        return None;
    }
    let (schema, table, column) = (cells.text(3)?, cells.text(4)?, cells.text(5)?);
    if table.starts_with('#') {
        return None;
    }
    Some(ColumnOrigin::new(TableRef::new(Some(schema), table), column))
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnKind, ColumnType, ReadForm, TextLength};

    use super::*;

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    fn row(ordinal: i64, name: &str, hidden: bool, source: Option<(&str, &str, &str)>, base: bool) -> Vec<Value> {
        let (schema, table, column) = match source {
            Some((schema, table, column)) => (text(schema), text(table), text(column)),
            None => (Value::Null, Value::Null, Value::Null),
        };
        vec![
            Value::Int(ordinal),
            text(name),
            Value::Bool(hidden),
            schema,
            table,
            column,
            Value::Bool(base),
        ]
    }

    fn column(name: &str) -> ResultColumn {
        ResultColumn::new(
            name,
            ColumnType {
                name: "nvarchar".to_owned(),
                kind: ColumnKind::Text {
                    length: TextLength::Unbounded,
                },
                catalog: None,
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
        )
    }

    fn traced(table: &str, column: &str) -> Option<ColumnOrigin> {
        Some(ColumnOrigin::new(TableRef::new(Some("dbo".to_owned()), table), column))
    }

    fn attached(rows: &[Vec<Value>], names: &[&str]) -> Vec<Option<ColumnOrigin>> {
        let columns: Vec<ResultColumn> = names.iter().copied().map(column).collect();
        let columns = match origins(rows) {
            Some(origins) => origins.attach(columns),
            None => columns,
        };
        columns.into_iter().map(|column| column.origin).collect()
    }

    #[test]
    fn a_renamed_column_traces_to_its_base_column_and_an_expression_to_nothing() {
        let rows = [
            row(1, "x", false, Some(("dbo", "t", "a")), true),
            row(2, "id", false, Some(("dbo", "t", "id")), true),
            row(3, "e", false, None, false),
        ];

        assert_eq!(
            attached(&rows, &["x", "id", "e"]),
            vec![traced("t", "a"), traced("t", "id"), None]
        );
    }

    #[test]
    fn a_hidden_key_row_is_not_a_column_of_the_result() {
        let rows = [
            row(2, "id", true, Some(("dbo", "t", "id")), true),
            row(1, "a", false, Some(("dbo", "t", "a")), true),
        ];

        assert_eq!(attached(&rows, &["a"]), vec![traced("t", "a")]);
    }

    #[test]
    fn a_source_that_is_not_the_named_base_table_or_is_temporary_is_untraced() {
        let rows = [
            row(1, "id", false, Some(("dbo", "t", "id")), false),
            row(2, "tid", false, Some(("dbo", "#tmp_____2", "tid")), true),
        ];

        assert_eq!(attached(&rows, &["id", "tid"]), vec![None, None]);
    }

    #[test]
    fn a_describe_that_does_not_match_the_result_traces_nothing() {
        let rows = [
            row(1, "id", false, Some(("dbo", "t", "id")), true),
            row(2, "a", false, Some(("dbo", "t", "a")), true),
        ];
        let error = vec![
            Value::Null,
            Value::Null,
            Value::Bool(false),
            Value::Null,
            Value::Null,
            Value::Null,
            Value::Bool(false),
        ];

        assert_eq!(attached(&rows, &["id", "b"]), vec![None, None], "another name");
        assert_eq!(attached(&rows, &["id"]), vec![None], "another width");
        assert_eq!(attached(&rows[1..], &["a"]), vec![None], "a gap in the ordinals");
        assert_eq!(attached(&[error], &["id"]), vec![None], "an error row");
        assert_eq!(
            attached(&[vec![text("plan")]], &["id"]),
            vec![None],
            "another result set"
        );
        assert_eq!(attached(&[], &["id"]), vec![None], "nothing described");
    }

    #[test]
    fn the_statement_name_is_bracketed_as_written() {
        assert_eq!(written_name(&TableRef::unqualified("t")), "[t]");
        assert_eq!(
            written_name(&TableRef::new(Some("Mixed Case".to_owned()), "odd]name")),
            "[Mixed Case].[odd]]name]"
        );
    }
}
