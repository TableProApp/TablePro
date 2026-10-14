//! Structure changes planned through the connection's own DDL dialect
//! and run as the structure tab runs them, then read back through
//! `fetch_table_definition`.

use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::{
    BuildDdlError, ColumnDefinition, DdlDialect, DdlOperation, DdlPlan, DraftColumn, DraftType, DropTableOptions,
    Permission, RefusalReason, TableDefinition, TableDraft, diff_table,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, IndexKey, ObjectKind, ObjectScope};
use tablepro_core::value::Value;
use tablepro_core::{
    Connection, DriverError, ForeignKeyInfo, ForeignKeyMode, RowLimit, TableRef, WriteAtomicity, WriteBatch, WriteKind,
    WriteReport,
};

use crate::conformance::support::{
    CALL_DEADLINE, apply, connect, count, expect, insert_sql, statement, unexpected, unique, within, writable,
};
use crate::conformance::{ConformanceDdlEngine, ConformanceFailure};

const APPLY_CASE: &str = "ddl_plans_apply_and_read_back";
const FAILED_CASE: &str = "failed_ddl_batch_outcome_matches_ddl_atomicity";
const SCRIPT_CASE: &str = "create_table_script_recreates_the_table";
const ROWS_CASE: &str = "structure_changes_keep_rows_and_indexes";

/// Case 1: each structure change the engine offers applies and reads
/// back as drafted, and each one it refuses is refused by the plan
/// with a reason, never sent.
pub async fn ddl_plans_apply_and_read_back<E: ConformanceDdlEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let case = APPLY_CASE;
    let connection = connect(case, &engine, writable()).await?;
    let dialect = connection.dialect();
    let ddl = ddl_of(case, dialect.as_ref())?;
    let capabilities = *ddl.capabilities();
    let parent = engine.scratch_table(&unique("ddl_parent"));
    let child = engine.scratch_table(&unique("ddl_child"));

    create(
        case,
        &engine,
        connection.as_ref(),
        ddl,
        &parent_draft(case, &engine, dialect.as_ref(), &parent)?,
    )
    .await?;
    create(case, &engine, connection.as_ref(), ddl, &child_draft(&engine, &child)).await?;
    let mut table = definition(connection.as_ref(), &parent).await?;
    matches_draft(
        case,
        "create",
        &table,
        &parent_draft(case, &engine, dialect.as_ref(), &parent)?,
    )?;

    let step = Step {
        case,
        connection: connection.as_ref(),
        ddl,
    };
    let note = DraftColumn::new("note", DraftType::Typed(engine.text_type().to_owned()));
    step.apply(
        &mut table,
        "add column",
        table_permission(capabilities.add_column),
        |draft| draft.columns.push(note),
    )
    .await?;

    let permission = column_permission(ddl, &table, "note", |permissions| permissions.rename);
    step.apply(&mut table, "rename column", permission, |draft| {
        rename(draft, "note", "remark")
    })
    .await?;
    let remark = if table.column("remark").is_some() {
        "remark"
    } else {
        "note"
    };

    let permission = column_permission(ddl, &table, remark, |permissions| permissions.alter_nullability);
    step.apply(&mut table, "change nullability", permission, |draft| {
        edit_column(draft, remark, |column| column.nullable = false)
    })
    .await?;

    let permission = column_permission(ddl, &table, remark, |permissions| permissions.alter_default);
    step.apply(&mut table, "change default", permission, |draft| {
        edit_column(draft, remark, |column| {
            column.default = ColumnDefault::Literal(Value::Text("none".to_owned()));
        })
    })
    .await?;

    let index = IndexInfo {
        name: format!("{}_label", parent.name),
        keys: vec![IndexKey::Column {
            name: "label".to_owned(),
            descending: false,
        }],
        unique: false,
        primary: false,
        predicate: None,
    };
    step.apply(
        &mut table,
        "create index",
        table_permission(capabilities.create_index),
        |draft| draft.indexes.push(index),
    )
    .await?;

    let mut child_table = definition(connection.as_ref(), &child).await?;
    let key = ForeignKeyInfo {
        name: format!("{}_parent_fk", child.name),
        columns: vec!["parent_id".to_owned()],
        ref_schema: parent.schema.clone(),
        ref_table: parent.name.clone(),
        ref_columns: vec!["id".to_owned()],
        on_delete: None,
        on_update: None,
    };
    let key_name = key.name.clone();
    let added = step
        .apply(
            &mut child_table,
            "add foreign key",
            table_permission(capabilities.add_foreign_key),
            |draft| draft.foreign_keys.push(key),
        )
        .await?;
    if added {
        table = definition(connection.as_ref(), &parent).await?;
        let permission = column_permission(ddl, &table, "label", |permissions| permissions.alter_primary_key);
        let names_the_key = matches!(
            &permission,
            Permission::Refused(RefusalReason::ReferencedByForeignKeys(keys)) if keys.contains(&key_name)
        );
        expect(case, names_the_key, || {
            format!("the referenced primary key reads as {permission:?}, not held by {key_name}")
        })?;
    }

    let permission = column_permission(ddl, &table, remark, |permissions| permissions.drop);
    step.apply(&mut table, "drop column", permission, |draft| {
        draft.columns.retain(|column| column.name != remark)
    })
    .await?;

    let renamed = TableRef::new(parent.schema.clone(), unique("ddl_renamed"));
    let new_name = renamed.name.clone();
    let moved = step
        .apply(
            &mut table,
            "rename table",
            table_permission(capabilities.rename_table),
            |draft| draft.table.name = new_name,
        )
        .await?;
    // A name the server resolved against the session's default schema
    // would have moved the table out of its own.
    let parent = if moved {
        let scope = renamed
            .schema
            .clone()
            .map_or(ObjectScope::DefaultSchema, ObjectScope::Schema);
        let objects = connection.list_objects(&scope, within(CALL_DEADLINE)).await?;
        let listed = objects
            .iter()
            .any(|object| object.kind == ObjectKind::Table && object.name == renamed.name);
        expect(case, listed, || {
            format!("{} is not listed in {scope:?} after the rename", renamed.name)
        })?;
        renamed
    } else {
        parent
    };

    let drop = DropTableOptions {
        if_exists: false,
        cascade: capabilities.drop_table_cascade,
    };
    for dropped in [&child, &parent] {
        let plan = ddl
            .plan_drop_table(dropped, drop)
            .map_err(|error| planned(case, "drop table", error))?;
        run(connection.as_ref(), dropped, plan).await?;
    }
    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL_DEADLINE))
        .await?;
    let left: Vec<&str> = objects
        .iter()
        .filter(|object| object.kind == ObjectKind::Table)
        .filter(|object| object.name == parent.name || object.name == child.name)
        .map(|object| object.name.as_str())
        .collect();
    expect(case, left.is_empty(), || {
        format!("{left:?} are still listed after the drop")
    })?;
    connection.close().await?;
    Ok(())
}

/// Case 2: a batch of two plans whose second statement the server
/// rejects leaves what the engine's DDL atomicity promises: nothing on
/// an engine whose schema changes are transactional, the first plan on
/// one that applies them statement by statement.
pub async fn failed_ddl_batch_outcome_matches_ddl_atomicity<E: ConformanceDdlEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let case = FAILED_CASE;
    let atomicity = E::driver().capabilities().ddl_writes;
    let connection = connect(case, &engine, writable()).await?;
    let dialect = connection.dialect();
    let ddl = ddl_of(case, dialect.as_ref())?;
    let parent = engine.scratch_table(&unique("ddl_failed"));
    create(
        case,
        &engine,
        connection.as_ref(),
        ddl,
        &parent_draft(case, &engine, dialect.as_ref(), &parent)?,
    )
    .await?;
    let original = definition(connection.as_ref(), &parent).await?;
    let text = || DraftType::Typed(engine.text_type().to_owned());

    let mut draft = TableDraft::from_definition(&original);
    draft.columns.push(DraftColumn::new("c1", text()));
    let first = ddl
        .plan_alter_table(&original, &diff_table(&original, &draft))
        .map_err(|error| planned(case, "add c1", error))?;
    // Planned against a definition that lacks `label`, so the server
    // refuses to add a column the table already has.
    let mut stale = original.clone();
    stale.columns.retain(|column| column.name() != "label");
    let mut again = TableDraft::from_definition(&stale);
    again.columns.push(DraftColumn::new("label", text()));
    let second = ddl
        .plan_alter_table(&stale, &diff_table(&stale, &again))
        .map_err(|error| planned(case, "add label again", error))?;
    expect(case, first.len() == 1 && second.len() == 1, || {
        format!(
            "each plan should be one statement: {:?} and {:?}",
            first.sql(),
            second.sql()
        )
    })?;

    let steps = first.into_steps().into_iter().chain(second.into_steps()).collect();
    let batch = WriteBatch::new(
        WriteKind::SchemaChanges,
        parent.clone(),
        steps,
        ForeignKeyMode::Enforced,
    );
    let outcome = connection.write_batch(&batch, within(CALL_DEADLINE)).await;
    let first_kept = match (atomicity, &outcome) {
        (WriteAtomicity::Transactional, Err(DriverError::RolledBack { statement_index: 1, .. })) => false,
        (WriteAtomicity::StatementByStatement, Err(DriverError::PartiallyApplied { applied: 1, .. })) => true,
        _ => {
            return Err(unexpected(
                case,
                format!("a {atomicity:?} engine answered a schema batch failing at statement 1 with {outcome:?}"),
            ));
        }
    };
    let after = definition(connection.as_ref(), &parent).await?;
    let has_c1 = after.column("c1").is_some();
    expect(case, has_c1 == first_kept, || {
        format!(
            "c1 is {} after the failed batch",
            if has_c1 { "present" } else { "absent" }
        )
    })?;
    drop_table(case, connection.as_ref(), ddl, &parent).await?;
    connection.close().await?;
    Ok(())
}

/// Case 3: the script for a table, run after the table is dropped,
/// recreates its columns and its index keys as they were.
pub async fn create_table_script_recreates_the_table<E: ConformanceDdlEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let case = SCRIPT_CASE;
    let connection = connect(case, &engine, writable()).await?;
    let dialect = connection.dialect();
    let ddl = ddl_of(case, dialect.as_ref())?;
    let parent = engine.scratch_table(&unique("ddl_script"));
    create(
        case,
        &engine,
        connection.as_ref(),
        ddl,
        &parent_draft(case, &engine, dialect.as_ref(), &parent)?,
    )
    .await?;
    let mut table = definition(connection.as_ref(), &parent).await?;
    if ddl.capabilities().create_index {
        let index = IndexInfo {
            name: format!("{}_label", parent.name),
            keys: vec![IndexKey::Column {
                name: "label".to_owned(),
                descending: true,
            }],
            unique: false,
            primary: false,
            predicate: None,
        };
        let step = Step {
            case,
            connection: connection.as_ref(),
            ddl,
        };
        step.apply(&mut table, "create index", Permission::Allowed, |draft| {
            draft.indexes.push(index)
        })
        .await?;
    }

    let script = ddl
        .create_table_script(&table)
        .map_err(|error| planned(case, "create table script", error))?;
    drop_table(case, connection.as_ref(), ddl, &parent).await?;
    run(connection.as_ref(), &parent, script).await?;
    let recreated = definition(connection.as_ref(), &parent).await?;

    let shape =
        |definition: &TableDefinition| -> Vec<ColumnShape> { definition.columns.iter().map(ColumnShape::of).collect() };
    let (before, after) = (shape(&table), shape(&recreated));
    expect(case, before == after, || {
        format!("the columns were {before:#?} and came back {after:#?}")
    })?;
    let (before, after) = (secondary_indexes(&table), secondary_indexes(&recreated));
    expect(case, before == after, || {
        format!("the indexes were {before:?} and came back {after:?}")
    })?;
    drop_table(case, connection.as_ref(), ddl, &parent).await?;
    connection.close().await?;
    Ok(())
}

/// Case 4: a table's rows and indexes come through the column changes
/// the engine offers. SQLite makes these by rebuilding the table, which
/// copies every row and makes every index again.
pub async fn structure_changes_keep_rows_and_indexes<E: ConformanceDdlEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let case = ROWS_CASE;
    let connection = connect(case, &engine, writable()).await?;
    let dialect = connection.dialect();
    let ddl = ddl_of(case, dialect.as_ref())?;
    let parent = engine.scratch_table(&unique("ddl_rows"));
    create(
        case,
        &engine,
        connection.as_ref(),
        ddl,
        &parent_draft(case, &engine, dialect.as_ref(), &parent)?,
    )
    .await?;
    let mut table = definition(connection.as_ref(), &parent).await?;
    let step = Step {
        case,
        connection: connection.as_ref(),
        ddl,
    };
    let index = IndexInfo {
        name: format!("{}_label", parent.name),
        keys: vec![IndexKey::Column {
            name: "label".to_owned(),
            descending: false,
        }],
        unique: false,
        primary: false,
        predicate: None,
    };
    step.apply(
        &mut table,
        "create index",
        table_permission(ddl.capabilities().create_index),
        |draft| draft.indexes.push(index),
    )
    .await?;
    let labels = ["first", "second", "third"];
    let inserts = (1..)
        .zip(labels)
        .map(|(id, label)| insert_sql(dialect.as_ref(), &parent, id, label))
        .collect();
    apply(connection.as_ref(), &parent, WriteKind::RowChanges, inserts).await?;
    let indexes = secondary_indexes(&table);

    let permission = column_permission(ddl, &table, "label", |permissions| permissions.alter_default);
    step.apply(&mut table, "change default", permission, |draft| {
        edit_column(draft, "label", |column| {
            column.default = ColumnDefault::Literal(Value::Text("none".to_owned()));
        })
    })
    .await?;
    // `created_at` took its default on every row, so none is NULL.
    let permission = column_permission(ddl, &table, "created_at", |permissions| permissions.alter_nullability);
    step.apply(&mut table, "change nullability", permission, |draft| {
        edit_column(draft, "created_at", |column| column.nullable = false)
    })
    .await?;

    let rows = count(connection.as_ref(), &parent).await?;
    expect(case, rows == 3, || format!("{rows} rows are left of 3"))?;
    let sql = format!(
        "SELECT {} FROM {} ORDER BY {}",
        dialect.quote_identifier("label"),
        dialect.qualify(&parent),
        dialect.quote_identifier("id")
    );
    let read = connection
        .query_bound(&statement(&sql), RowLimit::EDITOR_DEFAULT, within(CALL_DEADLINE))
        .await?;
    let expected: Vec<Vec<Value>> = labels
        .iter()
        .map(|label| vec![Value::Text((*label).to_owned())])
        .collect();
    expect(case, read.rows == expected, || {
        format!("the labels read back as {:?}", read.rows)
    })?;
    let after = secondary_indexes(&table);
    expect(case, after == indexes, || {
        format!("the indexes were {indexes:?} and are {after:?}")
    })?;
    drop_table(case, connection.as_ref(), ddl, &parent).await?;
    connection.close().await?;
    Ok(())
}

fn ddl_of<'a>(case: &'static str, dialect: &'a dyn SqlDialect) -> Result<&'a dyn DdlDialect, ConformanceFailure> {
    dialect
        .ddl()
        .ok_or_else(|| unexpected(case, "the connection's dialect has no DDL dialect"))
}

fn planned(case: &'static str, step: &str, error: BuildDdlError) -> ConformanceFailure {
    unexpected(case, format!("{step} did not plan: {error}"))
}

/// `id` keyed, `label` with a literal default that needs quoting, and
/// `created_at` with the engine's own current-timestamp expression.
fn parent_draft<E: ConformanceDdlEngine>(
    case: &'static str,
    engine: &E,
    dialect: &dyn SqlDialect,
    table: &TableRef,
) -> Result<TableDraft, ConformanceFailure> {
    let mut id = DraftColumn::new("id", DraftType::Typed(engine.integer_type().to_owned()));
    id.primary_key = true;
    id.nullable = false;
    let mut label = DraftColumn::new("label", DraftType::Typed(engine.text_type().to_owned()));
    label.nullable = false;
    label.default = ColumnDefault::Literal(Value::Text("it's".to_owned()));
    let mut created = DraftColumn::new("created_at", DraftType::Typed(engine.timestamp_type().to_owned()));
    let now = dialect
        .parse_expression(engine.current_timestamp_expression())
        .map_err(|error| unexpected(case, format!("the current-timestamp expression did not parse: {error}")))?;
    created.default = ColumnDefault::Expression(now);
    let mut draft = TableDraft::new(table.clone());
    draft.columns = vec![id, label, created];
    Ok(draft)
}

fn child_draft<E: ConformanceDdlEngine>(engine: &E, table: &TableRef) -> TableDraft {
    let mut id = DraftColumn::new("id", DraftType::Typed(engine.integer_type().to_owned()));
    id.primary_key = true;
    id.nullable = false;
    let parent_id = DraftColumn::new("parent_id", DraftType::Typed(engine.integer_type().to_owned()));
    let mut draft = TableDraft::new(table.clone());
    draft.columns = vec![id, parent_id];
    draft
}

/// Through the plan, or through the engine's own SQL where the dialect
/// creates no tables, which the plan has to say rather than send.
async fn create<E: ConformanceDdlEngine>(
    case: &'static str,
    engine: &E,
    connection: &dyn Connection,
    ddl: &dyn DdlDialect,
    draft: &TableDraft,
) -> Result<(), ConformanceFailure> {
    let plan = match (ddl.capabilities().create_table, ddl.plan_create_table(draft)) {
        (true, Ok(plan)) => plan,
        (false, Err(BuildDdlError::Unsupported(DdlOperation::CreateTable))) => {
            let sql = engine
                .create_table_sql(ddl.sql_dialect(), &draft.table, &draft.columns)
                .ok_or_else(|| unexpected(case, "the engine creates no tables and gave no CREATE TABLE of its own"))?;
            DdlPlan::from_sql([sql])
        }
        (allowed, outcome) => {
            return Err(unexpected(
                case,
                format!("create_table is {allowed} and the plan answered {outcome:?}"),
            ));
        }
    };
    run(connection, &draft.table, plan).await?;
    Ok(())
}

async fn run(connection: &dyn Connection, table: &TableRef, plan: DdlPlan) -> Result<WriteReport, DriverError> {
    connection
        .write_batch(&plan.into_write_batch(table.clone()), within(CALL_DEADLINE))
        .await
}

async fn definition(connection: &dyn Connection, table: &TableRef) -> Result<TableDefinition, ConformanceFailure> {
    Ok(connection.fetch_table_definition(table, within(CALL_DEADLINE)).await?)
}

async fn drop_table(
    case: &'static str,
    connection: &dyn Connection,
    ddl: &dyn DdlDialect,
    table: &TableRef,
) -> Result<(), ConformanceFailure> {
    let plan = ddl
        .plan_drop_table(table, DropTableOptions::default())
        .map_err(|error| planned(case, "drop table", error))?;
    run(connection, table, plan).await?;
    Ok(())
}

fn table_permission(allowed: bool) -> Permission {
    Permission::unless(allowed, RefusalReason::EngineUnsupported)
}

fn column_permission(
    ddl: &dyn DdlDialect,
    table: &TableDefinition,
    column: &str,
    pick: impl FnOnce(tablepro_core::ddl::ColumnCapabilities) -> Permission,
) -> Permission {
    match table.column(column) {
        Some(definition) => pick(ddl.column_capabilities(table, definition)),
        None => Permission::Refused(RefusalReason::UnreadableDefinition),
    }
}

fn rename(draft: &mut TableDraft, from: &str, to: &str) {
    edit_column(draft, from, |column| column.name = to.to_owned());
}

fn edit_column(draft: &mut TableDraft, name: &str, edit: impl FnOnce(&mut DraftColumn)) {
    if let Some(column) = draft.columns.iter_mut().find(|column| column.name == name) {
        edit(column);
    }
}

/// One edit of an existing table, planned against its definition as
/// last read.
struct Step<'a> {
    case: &'static str,
    connection: &'a dyn Connection,
    ddl: &'a dyn DdlDialect,
}

impl Step<'_> {
    /// Whether the change was made. An allowed change must plan, apply
    /// and read back as drafted; a refused one must be refused by the
    /// plan too.
    async fn apply(
        &self,
        table: &mut TableDefinition,
        step: &str,
        permission: Permission,
        edit: impl FnOnce(&mut TableDraft),
    ) -> Result<bool, ConformanceFailure> {
        let mut draft = TableDraft::from_definition(table);
        edit(&mut draft);
        let planned = self.ddl.plan_alter_table(table, &diff_table(table, &draft));
        match (&permission, planned) {
            (Permission::Allowed, Ok(plan)) => {
                run(self.connection, &table.table, plan).await?;
                *table = definition(self.connection, &draft.table).await?;
                matches_draft(self.case, step, table, &draft)?;
                Ok(true)
            }
            (Permission::Refused(_), Err(BuildDdlError::Unsupported(_) | BuildDdlError::Refused { .. })) => Ok(false),
            (_, outcome) => Err(unexpected(
                self.case,
                format!("{step}: the capabilities say {permission:?} and the plan answered {outcome:?}"),
            )),
        }
    }
}

/// Names and order, nullability and defaults of the columns, the keys of
/// every index the draft holds and every foreign key it declares. The
/// server may add an index of its own, as MySQL does for a foreign key.
fn matches_draft(
    case: &'static str,
    step: &str,
    table: &TableDefinition,
    draft: &TableDraft,
) -> Result<(), ConformanceFailure> {
    let names: Vec<&str> = table.columns.iter().map(ColumnDefinition::name).collect();
    let drafted: Vec<&str> = draft.columns.iter().map(|column| column.name.as_str()).collect();
    expect(case, names == drafted, || {
        format!("after {step} the columns are {names:?}, not {drafted:?}")
    })?;
    for (column, drafted) in table.columns.iter().zip(&draft.columns) {
        expect(case, column.info.nullable == drafted.nullable, || {
            format!("after {step} {} has nullable {}", drafted.name, column.info.nullable)
        })?;
        expect(case, same_default(&column.info.default, &drafted.default), || {
            format!(
                "after {step} {} reads its default as {:?}, not {:?}",
                drafted.name, column.info.default, drafted.default
            )
        })?;
    }
    for index in draft.indexes.iter().filter(|index| !index.primary) {
        let read = table.indexes.iter().find(|read| read.name == index.name);
        expect(case, read.is_some_and(|read| read.keys == index.keys), || {
            format!("after {step} index {} reads as {read:?}", index.name)
        })?;
    }
    for key in &draft.foreign_keys {
        let read = table.foreign_keys.iter().any(|read| {
            read.columns == key.columns && read.ref_table == key.ref_table && read.ref_columns == key.ref_columns
        });
        expect(case, read, || {
            format!(
                "after {step} foreign key {} is not in {:?}",
                key.name, table.foreign_keys
            )
        })?;
    }
    Ok(())
}

/// A server keeps an expression in its own spelling: SQL Server wraps
/// it in parentheses and MariaDB adds them to a bare function, so the
/// comparison leaves out case, spaces and parentheses.
fn same_default(read: &ColumnDefault, drafted: &ColumnDefault) -> bool {
    let normal = |text: &str| -> String {
        text.chars()
            .filter(|character| !character.is_whitespace() && !matches!(character, '(' | ')'))
            .flat_map(char::to_lowercase)
            .collect()
    };
    match (read, drafted) {
        (ColumnDefault::None, ColumnDefault::None) => true,
        (ColumnDefault::Literal(read), ColumnDefault::Literal(drafted)) => read == drafted,
        (ColumnDefault::Expression(read), ColumnDefault::Expression(drafted)) => {
            normal(read.as_sql()) == normal(drafted.as_sql())
        }
        _ => false,
    }
}

/// What a recreated column has to keep. The SQL Server default
/// constraint's name is left out: the server names it afresh.
#[derive(Debug, PartialEq)]
struct ColumnShape {
    name: String,
    declaration: Option<String>,
    nullable: bool,
    primary_key: bool,
    auto_increment: bool,
    generated: bool,
    default: ColumnDefault,
    comment: Option<String>,
}

impl ColumnShape {
    fn of(column: &ColumnDefinition) -> Self {
        let info = &column.info;
        Self {
            name: info.name.clone(),
            declaration: info
                .column_type
                .catalog
                .as_ref()
                .map(|catalog| catalog.declaration.as_sql().to_owned()),
            nullable: info.nullable,
            primary_key: info.primary_key,
            auto_increment: info.is_auto_increment,
            generated: info.is_generated,
            default: info.default.clone(),
            comment: info.comment.clone(),
        }
    }
}

fn secondary_indexes(table: &TableDefinition) -> Vec<(String, Vec<IndexKey>)> {
    let mut indexes: Vec<(String, Vec<IndexKey>)> = table
        .indexes
        .iter()
        .filter(|index| !index.primary)
        .map(|index| (index.name.clone(), index.keys.clone()))
        .collect();
    indexes.sort_by(|a, b| a.0.cmp(&b.0));
    indexes
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::SqlExpression;

    use super::*;
    use crate::ConnectionScript;
    use crate::conformance::ConformanceDdlEngine;
    use crate::conformance::fake_engine::{FakeEngine, FakeScenario};

    struct NoDdl;

    impl FakeScenario for NoDdl {
        fn script() -> ConnectionScript {
            FakeEngine::<Self>::base_script()
        }
    }

    impl ConformanceDdlEngine for FakeEngine<NoDdl> {
        fn integer_type(&self) -> &'static str {
            "integer"
        }

        fn text_type(&self) -> &'static str {
            "text"
        }

        fn timestamp_type(&self) -> &'static str {
            "timestamp"
        }

        fn current_timestamp_expression(&self) -> &'static str {
            "CURRENT_TIMESTAMP"
        }
    }

    #[tokio::test]
    async fn a_connection_without_a_ddl_dialect_fails_the_case() {
        let outcome = ddl_plans_apply_and_read_back(FakeEngine::<NoDdl>::new()).await;

        assert!(
            matches!(&outcome, Err(ConformanceFailure::Expectation { case: APPLY_CASE, detail }) if detail.contains("no DDL dialect")),
            "{outcome:?}"
        );
    }

    #[test]
    fn a_server_spelled_expression_is_the_same_default() {
        let expression = |text: &str| ColumnDefault::Expression(SqlExpression::from_catalog_text(text));

        assert!(same_default(&expression("(getdate())"), &expression("getdate()")));
        assert!(same_default(
            &expression("current_timestamp()"),
            &expression("CURRENT_TIMESTAMP")
        ));
        assert!(!same_default(&expression("now()"), &expression("today()")));
        assert!(!same_default(
            &ColumnDefault::Literal(Value::Text("it's".to_owned())),
            &expression("'it''s'")
        ));
    }
}
