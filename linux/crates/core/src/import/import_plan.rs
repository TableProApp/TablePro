use crate::column::ColumnInfo;
use crate::dialect::SqlDialect;
use crate::dml::{BuildSqlError, build_insert};
use crate::edit::CellInput;
use crate::meta::TableRef;
use crate::statement::GuardedStatement;
use crate::{ForeignKeyMode, WriteBatch, WriteKind};

use super::ImportColumn;

/// The rows as one batch, so the engine runs them in one transaction
/// where it has one and a file either lands whole or not at all.
pub fn plan_import(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ImportColumn],
    rows: &[Vec<CellInput>],
) -> Result<WriteBatch, BuildSqlError> {
    let infos: Vec<ColumnInfo> = columns.iter().map(|column| column.info.clone()).collect();
    let steps = rows
        .iter()
        .map(|cells| build_insert(dialect, table, &infos, cells).map(GuardedStatement::unguarded))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(WriteBatch::new(
        WriteKind::RowChanges,
        table.clone(),
        steps,
        ForeignKeyMode::Enforced,
    ))
}
