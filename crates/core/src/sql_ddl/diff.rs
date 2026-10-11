use crate::query::{ColumnInfo, ForeignKeyInfo, IndexInfo};

use super::column::{build_add_column, build_alter_column, build_drop_column, build_rename_column};
use super::index_fk::{build_add_foreign_key, build_create_index, build_drop_foreign_key, build_drop_index};
use super::table::{build_create_table, build_rename_table};
use super::types::{BuildDdlError, DraftColumn, StructureOp};

/// Diff a loaded snapshot against the user's current edits and emit
/// the `StructureOp` list that materializes them. Pure function — no
/// state, no side effects. Replaces the per-keystroke `tracker.push`
/// model with a snapshot-based diff: the model is the source of
/// truth, ops are derived at materialize time.
///
/// Identity rules:
/// - Columns matched by `DraftColumn.original.name`. Newly-added
///   columns (`original = None`) emit `AddColumn`. Originals with no
///   matching draft emit `DropColumn`. Drafts whose attributes
///   differ from `original` emit `AlterColumn`.
/// - Indexes / FKs matched by name. Pure rename without other
///   changes ⇒ `Drop` + `Add` (no native ALTER INDEX in the
///   supported drivers).
#[allow(clippy::too_many_arguments)]
pub fn diff_to_ops(
    schema: Option<&str>,
    original_table: &str,
    current_table: &str,
    original_columns: &[ColumnInfo],
    current_columns: &[DraftColumn],
    original_indexes: &[IndexInfo],
    current_indexes: &[IndexInfo],
    original_fks: &[ForeignKeyInfo],
    current_fks: &[ForeignKeyInfo],
) -> Vec<StructureOp> {
    let mut ops = Vec::new();
    let schema_owned = schema.map(ToString::to_string);

    // RenameTable
    if original_table != current_table && !current_table.trim().is_empty() {
        ops.push(StructureOp::RenameTable {
            schema: schema_owned.clone(),
            old_name: original_table.to_string(),
            new_name: current_table.to_string(),
        });
    }

    // Use the post-rename table name for child-op identity since
    // PostgreSQL applies subsequent ALTERs against the new name.
    // MySQL accepts either; SQLite only allows table rename in
    // isolation but the materialize ordering puts rename first.
    let table = current_table.to_string();

    // Drop FKs not in current
    for fk in original_fks {
        if !current_fks.iter().any(|f| f.name == fk.name) {
            ops.push(StructureOp::DropForeignKey {
                schema: schema_owned.clone(),
                table: table.clone(),
                fk_name: fk.name.clone(),
            });
        }
    }

    // Drop indexes not in current. Skip primary indexes — they're
    // owned by the column's PK constraint; touching them via DROP
    // INDEX would conflict with the column's own state diff.
    for idx in original_indexes {
        if idx.primary {
            continue;
        }
        if !current_indexes.iter().any(|i| i.name == idx.name) {
            ops.push(StructureOp::DropIndex {
                schema: schema_owned.clone(),
                table: table.clone(),
                index_name: idx.name.clone(),
            });
        }
    }

    // Drop columns: original entries with no matching draft (matched
    // by original.name).
    for orig in original_columns {
        let still_present = current_columns
            .iter()
            .any(|c| c.original.as_ref().map(|o| o.name == orig.name).unwrap_or(false));
        if !still_present {
            ops.push(StructureOp::DropColumn {
                schema: schema_owned.clone(),
                table: table.clone(),
                column_name: orig.name.clone(),
            });
        }
    }

    // Rename columns before altering them: the alter builders address
    // the column by its drafted name, so the rename has to land first.
    for col in current_columns {
        if let Some(orig) = col.original.as_ref().filter(|_| col.renamed()) {
            ops.push(StructureOp::RenameColumn {
                schema: schema_owned.clone(),
                table: table.clone(),
                old_name: orig.name.clone(),
                new_name: col.name.clone(),
            });
        }
    }

    // Alter columns: drafts whose original is Some and something other
    // than the name differs. A column that only changed name has
    // nothing left for an alter to do.
    for col in current_columns {
        if col.original.is_some() && col.differs_beyond_name() {
            ops.push(StructureOp::AlterColumn {
                schema: schema_owned.clone(),
                table: table.clone(),
                column: col.clone(),
            });
        }
    }

    // Add columns: drafts with no original.
    for col in current_columns {
        if col.original.is_none() {
            ops.push(StructureOp::AddColumn {
                schema: schema_owned.clone(),
                table: table.clone(),
                column: col.clone(),
            });
        }
    }

    // Add indexes not in original.
    for idx in current_indexes {
        if idx.primary {
            continue;
        }
        if !original_indexes.iter().any(|i| i.name == idx.name) {
            ops.push(StructureOp::AddIndex {
                schema: schema_owned.clone(),
                table: table.clone(),
                index: idx.clone(),
            });
        }
    }

    // Add FKs not in original.
    for fk in current_fks {
        if !original_fks.iter().any(|f| f.name == fk.name) {
            ops.push(StructureOp::AddForeignKey {
                schema: schema_owned.clone(),
                table: table.clone(),
                fk: fk.clone(),
            });
        }
    }

    ops
}

/// Walk a `StructureOp` list and emit the SQL statements in the
/// canonical phased order (rename table → drop FK → drop index →
/// drop column → alter column → add column → add index → add FK).
/// Splitting between diff (intent) and materialize (SQL emission)
/// keeps the diff side pure and the SQL side driver-aware.
///
/// `New`-mode `CreateTable` short-circuits the phased pipeline.
pub fn materialize_ops(ops: &[StructureOp], driver_id: &str) -> Result<Vec<String>, BuildDdlError> {
    if let Some(StructureOp::CreateTable {
        schema,
        table,
        columns,
        indexes,
        fks,
    }) = ops.first()
        && ops.len() == 1
    {
        return build_create_table(driver_id, schema.as_deref(), table, columns, indexes, fks);
    }

    let mut out: Vec<String> = Vec::new();

    for op in ops {
        if let StructureOp::RenameTable {
            schema,
            old_name,
            new_name,
        } = op
        {
            out.push(build_rename_table(driver_id, schema.as_deref(), old_name, new_name)?);
        }
    }
    for op in ops {
        if let StructureOp::DropForeignKey { schema, table, fk_name } = op {
            out.push(build_drop_foreign_key(driver_id, schema.as_deref(), table, fk_name)?);
        }
    }
    for op in ops {
        if let StructureOp::DropIndex {
            schema,
            table,
            index_name,
        } = op
        {
            out.push(build_drop_index(driver_id, schema.as_deref(), table, index_name)?);
        }
    }
    for op in ops {
        if let StructureOp::DropColumn {
            schema,
            table,
            column_name,
        } = op
        {
            out.push(build_drop_column(driver_id, schema.as_deref(), table, column_name)?);
        }
    }
    for op in ops {
        if let StructureOp::RenameColumn {
            schema,
            table,
            old_name,
            new_name,
        } = op
        {
            out.push(build_rename_column(
                driver_id,
                schema.as_deref(),
                table,
                old_name,
                new_name,
            )?);
        }
    }
    for op in ops {
        if let StructureOp::AlterColumn { schema, table, column } = op {
            match build_alter_column(driver_id, schema.as_deref(), table, column) {
                Ok(stmts) => out.extend(stmts),
                Err(BuildDdlError::NoChange) => {}
                Err(e) => return Err(e),
            }
        }
    }
    for op in ops {
        if let StructureOp::AddColumn { schema, table, column } = op {
            out.extend(build_add_column(driver_id, schema.as_deref(), table, column)?);
        }
    }
    for op in ops {
        if let StructureOp::AddIndex { schema, table, index } = op {
            out.push(build_create_index(driver_id, schema.as_deref(), table, index)?);
        }
    }
    for op in ops {
        if let StructureOp::AddForeignKey { schema, table, fk } = op {
            out.push(build_add_foreign_key(driver_id, schema.as_deref(), table, fk)?);
        }
    }

    Ok(out)
}
