use std::ops::Range;

use crate::column::ColumnInfo;
use crate::dialect::SqlDialect;
use crate::dml::{BuildSqlError, build_insert, build_multi_row_insert};
use crate::edit::CellInput;
use crate::meta::TableRef;
use crate::statement::GuardedStatement;
use crate::value::Value;
use crate::{ForeignKeyMode, WriteBatch, WriteKind};

use super::ImportColumn;

/// The write that lands a file's rows in a table.
#[derive(Debug, Clone, PartialEq)]
pub struct ImportPlan {
    /// One batch, so the engine runs it in one transaction where it has
    /// one and a file either lands whole or not at all.
    pub batch: WriteBatch,
    /// The rows each step writes, as indexes into the rows planned, so a
    /// failed step can be told as the lines of the file it held.
    pub step_rows: Vec<Range<usize>>,
}

/// The rows as multi-row INSERTs, each within what the engine takes in
/// one statement. Consecutive rows that write the same columns share a
/// statement; a row whose fields left a different set of columns to the
/// server starts a new one.
///
/// Steps are unguarded, as a grid insert is: an INSERT has no row it
/// could have missed, and SQL Server counts trigger rows in its own.
pub fn plan_import(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ImportColumn],
    rows: Vec<Vec<CellInput>>,
) -> Result<ImportPlan, BuildSqlError> {
    let limits = dialect.insert_batch_limits();
    let infos: Vec<ColumnInfo> = columns.iter().map(|column| column.info.clone()).collect();
    let mut steps = Vec::new();
    let mut step_rows = Vec::new();
    let mut rows = rows.into_iter().enumerate().peekable();
    while let Some((first, cells)) = rows.next() {
        let shape = written_columns(&infos, &cells);
        let width = shape.iter().filter(|written| **written).count();
        if width == 0 {
            // Nothing but defaults has no VALUES list to share.
            steps.push(GuardedStatement::unguarded(build_insert(
                dialect, table, &infos, &cells,
            )?));
            step_rows.push(first..first + 1);
            continue;
        }
        let mut bytes = row_bytes(&cells);
        let mut group = vec![written_values(cells, &shape)];
        while let Some((_, next)) = rows.peek() {
            let size = row_bytes(next);
            let fits = group.len() < limits.rows
                && (group.len() + 1) * width <= limits.params
                && bytes + size <= limits.value_bytes
                && written_columns(&infos, next) == shape;
            if !fits {
                break;
            }
            bytes += size;
            if let Some((_, next)) = rows.next() {
                group.push(written_values(next, &shape));
            }
        }
        let count = group.len();
        let written: Vec<&ColumnInfo> = infos
            .iter()
            .zip(&shape)
            .filter_map(|(column, written)| written.then_some(column))
            .collect();
        steps.push(GuardedStatement::unguarded(build_multi_row_insert(
            dialect, table, &written, group,
        )?));
        step_rows.push(first..first + count);
    }
    Ok(ImportPlan {
        batch: WriteBatch::new(WriteKind::RowChanges, table.clone(), steps, ForeignKeyMode::Enforced),
        step_rows,
    })
}

/// Which columns a row writes: every one it has a value for that the
/// server does not compute.
fn written_columns(columns: &[ColumnInfo], cells: &[CellInput]) -> Vec<bool> {
    columns
        .iter()
        .zip(cells)
        .map(|(column, cell)| !column.is_generated && cell.value().is_some())
        .collect()
}

fn written_values(cells: Vec<CellInput>, shape: &[bool]) -> Vec<Value> {
    cells
        .into_iter()
        .zip(shape)
        .filter_map(|(cell, written)| match (cell, written) {
            (CellInput::Value(value), true) => Some(value),
            _ => None,
        })
        .collect()
}

/// About how much of a statement a row's values take, as text.
fn row_bytes(cells: &[CellInput]) -> usize {
    cells.iter().filter_map(CellInput::value).map(value_bytes).sum()
}

fn value_bytes(value: &Value) -> usize {
    match value {
        Value::Text(text) => text.len(),
        // Engines that take bytes as text take them as hex.
        Value::Bytes(bytes) => bytes.len() * 2,
        Value::Json(json) => json.as_str().len(),
        Value::Other(other) => other.text.len(),
        Value::Array(values) => values.iter().map(value_bytes).sum::<usize>() + 2,
        _ => 16,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::{ColumnDefault, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm, TextLength};
    use crate::dialect::{InsertBatchLimits, TestDialect};

    fn column(name: &str, kind: ColumnKind) -> ImportColumn {
        ImportColumn {
            info: ColumnInfo {
                name: name.to_owned(),
                column_type: ColumnType {
                    name: "t".to_owned(),
                    kind,
                    catalog: None,
                    dynamic_storage: false,
                    read_form: ReadForm::Native,
                },
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                is_generated: false,
                default: ColumnDefault::None,
                comment: None,
            },
            server_filled: false,
        }
    }

    fn columns() -> Vec<ImportColumn> {
        vec![
            column(
                "id",
                ColumnKind::Integer(IntegerKind {
                    width: IntegerWidth::W64,
                    signed: true,
                }),
            ),
            column(
                "name",
                ColumnKind::Text {
                    length: TextLength::Unbounded,
                },
            ),
        ]
    }

    fn row(id: i64, name: &str) -> Vec<CellInput> {
        vec![
            CellInput::Value(Value::Int(id)),
            CellInput::Value(Value::Text(name.to_owned())),
        ]
    }

    fn table() -> TableRef {
        TableRef::new(Some("public".to_owned()), "people")
    }

    #[test]
    fn rows_that_write_the_same_columns_share_one_statement() {
        let plan = plan_import(
            &TestDialect::default(),
            &table(),
            &columns(),
            vec![row(1, "ada"), row(2, "grace")],
        )
        .expect("the plan");

        assert_eq!(plan.batch.steps.len(), 1);
        assert_eq!(
            plan.batch.steps[0].statement.sql(),
            r#"INSERT INTO "public"."people" ("id", "name") VALUES ($1, $2), ($3, $4)"#
        );
        assert_eq!(
            plan.batch.steps[0]
                .statement
                .params()
                .iter()
                .map(|param| param.value().clone())
                .collect::<Vec<_>>(),
            vec![
                Value::Int(1),
                Value::Text("ada".to_owned()),
                Value::Int(2),
                Value::Text("grace".to_owned()),
            ]
        );
        assert_eq!(plan.step_rows, vec![0..2]);
    }

    #[test]
    fn a_statement_stops_at_the_engines_row_and_parameter_limits() {
        let rows = (0..2_500).map(|id| row(id, "x")).collect();
        let by_rows = plan_import(&TestDialect::default(), &table(), &columns(), rows).expect("the plan");
        let narrow = TestDialect::default().with_insert_limits(InsertBatchLimits {
            params: 5,
            ..InsertBatchLimits::DEFAULT
        });
        let by_params =
            plan_import(&narrow, &table(), &columns(), (0..5).map(|id| row(id, "x")).collect()).expect("the plan");

        assert_eq!(by_rows.step_rows, vec![0..1_000, 1_000..2_000, 2_000..2_500]);
        assert_eq!(by_params.step_rows, vec![0..2, 2..4, 4..5]);
        assert!(
            by_params
                .batch
                .steps
                .iter()
                .all(|step| step.statement.params().len() <= 5),
            "a statement bound more than the engine takes"
        );
    }

    #[test]
    fn a_statement_stops_before_its_values_outgrow_the_byte_budget() {
        let dialect = TestDialect::default().with_insert_limits(InsertBatchLimits {
            value_bytes: 100,
            ..InsertBatchLimits::DEFAULT
        });
        let long = "x".repeat(60);

        let plan = plan_import(
            &dialect,
            &table(),
            &columns(),
            vec![row(1, &long), row(2, &long), row(3, "short")],
        )
        .expect("the plan");

        assert_eq!(plan.step_rows, vec![0..1, 1..3]);
    }

    #[test]
    fn a_row_that_leaves_a_column_to_the_server_starts_a_statement() {
        let defaulted = vec![CellInput::Value(Value::Int(3)), CellInput::Default];

        let plan = plan_import(
            &TestDialect::default(),
            &table(),
            &columns(),
            vec![row(1, "ada"), defaulted, row(4, "alan")],
        )
        .expect("the plan");

        assert_eq!(plan.step_rows, vec![0..1, 1..2, 2..3]);
        assert_eq!(
            plan.batch.steps[1].statement.sql(),
            r#"INSERT INTO "public"."people" ("id") VALUES ($1)"#
        );
    }

    #[test]
    fn a_row_of_nothing_but_defaults_is_a_default_row_insert() {
        let plan = plan_import(
            &TestDialect::default(),
            &table(),
            &columns(),
            vec![vec![CellInput::Default, CellInput::Default]],
        )
        .expect("the plan");

        assert_eq!(
            plan.batch.steps[0].statement.sql(),
            r#"INSERT INTO "public"."people" DEFAULT VALUES"#
        );
    }

    #[test]
    fn a_generated_column_is_never_written() {
        let mut columns = columns();
        columns[1].info.is_generated = true;

        let plan = plan_import(&TestDialect::default(), &table(), &columns, vec![row(1, "ada")]).expect("the plan");

        assert_eq!(
            plan.batch.steps[0].statement.sql(),
            r#"INSERT INTO "public"."people" ("id") VALUES ($1)"#
        );
    }
}
