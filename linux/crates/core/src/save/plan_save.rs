use crate::column::ColumnInfo;
use crate::dialect::{InsertConflict, SqlDialect};
use crate::dml::{BuildSqlError, build_delete, build_insert, build_key_probe, build_update, sets_partition_only};
use crate::edit::CellInput;
use crate::foreign_key_mode::ForeignKeyMode;
use crate::meta::{RowIdentity, TableRef};
use crate::statement::{GuardedStatement, RowGuard, Statement};
use crate::value::Value;
use crate::write_batch::{WriteBatch, WriteKind};

use super::{ChangeSet, RowChange, SavePlan};

/// The batch that writes what the user changed, one statement per
/// change, in the change set's order.
///
/// Every update and delete carries a guard that proves it touched
/// exactly the row it names, chosen by how far the key and the engine's
/// counts can be trusted:
/// - a unique key on an engine with exact counts: the affected count;
/// - a unique key elsewhere: a probe, because SQL Server adds the rows
///   its triggers touch to the count;
/// - an engine row id: the affected count, since the address is unique;
/// - a sorting key: a probe, because it can match several rows;
/// - an update of partition-scoped columns alone (CQL static columns):
///   a probe, because it changes the partition, not the row.
///
/// An insert carries the affected count where the engine skips one
/// whose key is taken instead of refusing it, and a probe that finds no
/// row with its key where the engine replaces that row.
pub fn plan_save(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    changes: &ChangeSet,
) -> Result<SavePlan, BuildSqlError> {
    let mut steps = Vec::with_capacity(changes.step_count());
    let mut origins = Vec::with_capacity(changes.step_count());

    for (index, change) in changes.changes.iter().enumerate() {
        let step = match change {
            RowChange::Insert { cells } => {
                refuse_computed_replaced_key(dialect, columns, cells)?;
                let statement = build_insert(dialect, table, columns, cells)?;
                insert_step(
                    dialect,
                    table,
                    columns.iter().zip(cells.iter().map(CellInput::value)),
                    statement,
                )?
            }
            RowChange::Update(update) => {
                let statement = build_update(dialect, table, columns, identity, &update.key, &update.assignments)?;
                match sets_partition_only(columns, &update.assignments) {
                    // Its count says how many partitions it reached, not
                    // whether the row is there.
                    true => GuardedStatement {
                        statement,
                        guard: RowGuard::ProbeExactly {
                            probe: build_key_probe(dialect, table, columns, identity, &update.key)?,
                            rows: 1,
                        },
                    },
                    false => guarded(dialect, table, columns, identity, &update.key, statement)?,
                }
            }
            RowChange::Delete { key } => {
                let statement = build_delete(dialect, table, columns, identity, key)?;
                guarded(dialect, table, columns, identity, key, statement)?
            }
        };
        steps.push(step);
        origins.push(index);
    }

    Ok(SavePlan {
        batch: WriteBatch::new(WriteKind::RowChanges, table.clone(), steps, ForeignKeyMode::Enforced),
        origins,
    })
}

/// An insert that replaces a row with its key is proved by a probe for
/// that key first, which a key the server computes cannot name.
fn refuse_computed_replaced_key(
    dialect: &dyn SqlDialect,
    columns: &[ColumnInfo],
    cells: &[CellInput],
) -> Result<(), BuildSqlError> {
    if dialect.capabilities().insert_conflict != InsertConflict::Replaced {
        return Ok(());
    }
    match columns
        .iter()
        .zip(cells)
        .find(|(column, cell)| column.primary_key && matches!(cell, CellInput::Expression(_)))
    {
        Some((column, _)) => Err(BuildSqlError::ServerComputedValue {
            name: column.name.clone(),
        }),
        None => Ok(()),
    }
}

/// An insert, proved by its count where a taken key is skipped rather
/// than refused, and by a probe that finds no row with its key where a
/// taken key is replaced. An insert that leaves a key column out is
/// refused by the server itself, so it needs no probe.
pub(crate) fn insert_step<'a>(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    row: impl Iterator<Item = (&'a ColumnInfo, Option<&'a Value>)>,
    statement: Statement,
) -> Result<GuardedStatement, BuildSqlError> {
    let guard = match dialect.capabilities().insert_conflict {
        InsertConflict::Refused => RowGuard::None,
        InsertConflict::Skipped => RowGuard::AffectedExactly(1),
        InsertConflict::Replaced => {
            let keyed: Vec<(&ColumnInfo, Option<&Value>)> = row.filter(|(column, _)| column.primary_key).collect();
            if keyed.is_empty() {
                return Err(BuildSqlError::NoRowIdentity);
            }
            match keyed
                .iter()
                .map(|(_, value)| value.cloned())
                .collect::<Option<Vec<Value>>>()
            {
                None => RowGuard::None,
                Some(key) => {
                    let key_columns: Vec<ColumnInfo> = keyed.iter().map(|(column, _)| (*column).clone()).collect();
                    let identity = RowIdentity::UniqueKey {
                        columns: key_columns.iter().map(|column| column.name.clone()).collect(),
                    };
                    RowGuard::ProbeExactly {
                        probe: build_key_probe(dialect, table, &key_columns, &identity, &key)?,
                        rows: 0,
                    }
                }
            }
        }
    };
    Ok(GuardedStatement { statement, guard })
}

fn guarded(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    key: &[Value],
    statement: Statement,
) -> Result<GuardedStatement, BuildSqlError> {
    let counts_are_proof = match identity {
        RowIdentity::UniqueKey { .. } => dialect.capabilities().exact_row_counts,
        RowIdentity::EngineRowId(_) => true,
        RowIdentity::SortingKey { .. } => false,
        RowIdentity::Unordered => return Err(BuildSqlError::ReadOnlyRows),
    };
    if counts_are_proof {
        return Ok(GuardedStatement::affecting_exactly(statement, 1));
    }
    Ok(GuardedStatement {
        statement,
        guard: RowGuard::ProbeExactly {
            probe: build_key_probe(dialect, table, columns, identity, key)?,
            rows: 1,
        },
    })
}

#[cfg(test)]
mod tests {
    use crate::column::{ColumnDefault, ColumnKind, ColumnType, IntegerKind, IntegerWidth, ReadForm, TextLength};
    use crate::dialect::TestDialect;
    use crate::meta::EngineRowId;
    use crate::save::RowUpdate;

    use super::*;

    fn column(name: &str, kind: ColumnKind) -> ColumnInfo {
        ColumnInfo {
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
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn columns() -> Vec<ColumnInfo> {
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

    fn table() -> TableRef {
        TableRef::unqualified("users")
    }

    fn by_id() -> RowIdentity {
        RowIdentity::UniqueKey {
            columns: vec!["id".to_owned()],
        }
    }

    fn insert(name: &str) -> RowChange {
        RowChange::Insert {
            cells: vec![CellInput::Default, CellInput::Value(Value::Text(name.to_owned()))],
        }
    }

    fn update(key: Value, name: &str) -> RowChange {
        RowChange::Update(RowUpdate {
            key: vec![key],
            assignments: vec![(1, CellInput::Value(Value::Text(name.to_owned())))],
        })
    }

    fn delete(key: Value) -> RowChange {
        RowChange::Delete { key: vec![key] }
    }

    fn one_of_each(key: Value) -> ChangeSet {
        ChangeSet {
            changes: vec![insert("new"), update(key.clone(), "renamed"), delete(key)],
        }
    }

    fn plan(dialect: &TestDialect, identity: &RowIdentity, changes: &ChangeSet) -> SavePlan {
        match plan_save(dialect, &table(), &columns(), identity, changes) {
            Ok(plan) => plan,
            Err(error) => panic!("the save did not plan: {error}"),
        }
    }

    fn guard_kind(guard: &RowGuard) -> &'static str {
        match guard {
            RowGuard::None => "none",
            RowGuard::AffectedExactly(1) => "affected",
            RowGuard::AffectedExactly(_) => "affected-other",
            RowGuard::ProbeExactly { rows: 1, .. } => "probe",
            RowGuard::ProbeExactly { .. } => "probe-other",
        }
    }

    #[test]
    fn plan_save_guard_table() {
        let sorting = RowIdentity::SortingKey {
            expressions: vec!["id".to_owned()],
        };
        let rowid = RowIdentity::EngineRowId(EngineRowId::SqliteRowid);
        // (identity, exact counts, guard on the update and delete)
        let cases = [
            (by_id(), true, "affected"),
            (by_id(), false, "probe"),
            (rowid.clone(), true, "affected"),
            (rowid, false, "affected"),
            (sorting.clone(), true, "probe"),
            (sorting, false, "probe"),
        ];

        for (identity, exact, expected) in cases {
            let dialect = match exact {
                true => TestDialect::exact(),
                false => TestDialect::estimated(),
            };
            let plan = plan(&dialect, &identity, &one_of_each(Value::Int(7)));
            let guards: Vec<_> = plan.batch.steps.iter().map(|step| guard_kind(&step.guard)).collect();

            assert_eq!(
                guards,
                vec!["none", expected, expected],
                "{identity:?} exact_row_counts = {exact}"
            );
        }
    }

    #[test]
    fn an_engine_without_exact_counts_never_gets_a_count_guard_on_a_key_it_cannot_trust() {
        let sorting = RowIdentity::SortingKey {
            expressions: vec!["id".to_owned()],
        };

        for identity in [by_id(), sorting] {
            let plan = plan(&TestDialect::estimated(), &identity, &one_of_each(Value::Int(7)));

            assert!(
                plan.batch
                    .steps
                    .iter()
                    .all(|step| !matches!(step.guard, RowGuard::AffectedExactly(_))),
                "{identity:?}"
            );
        }
    }

    #[test]
    fn a_probe_names_the_same_row_as_its_statement() {
        let plan = plan(&TestDialect::estimated(), &by_id(), &one_of_each(Value::Int(7)));

        let Some((probe, rows)) = plan.batch.steps[1].guard.probe() else {
            panic!("the update has no probe");
        };
        assert_eq!(rows, 1);
        assert_eq!(
            probe.sql(),
            r#"SELECT COUNT(*) FROM (SELECT 1 AS one FROM "users" WHERE "id" = $1 LIMIT 2) AS probe"#
        );
        assert_eq!(probe.params()[0].value(), &Value::Int(7));
    }

    fn keyed_columns() -> Vec<ColumnInfo> {
        let mut columns = columns();
        columns[0].primary_key = true;
        columns
    }

    fn keyed_insert(id: i64) -> RowChange {
        RowChange::Insert {
            cells: vec![
                CellInput::Value(Value::Int(id)),
                CellInput::Value(Value::Text("a".to_owned())),
            ],
        }
    }

    #[test]
    fn an_insert_is_guarded_by_what_the_engine_does_with_a_taken_key() {
        let changes = ChangeSet {
            changes: vec![keyed_insert(9)],
        };
        let guard = |conflict| {
            let dialect = TestDialect::exact().with_insert_conflict(conflict);
            let plan = plan_save(&dialect, &table(), &keyed_columns(), &by_id(), &changes).expect("the plan");
            guard_kind(&plan.batch.steps[0].guard)
        };

        assert_eq!(guard(InsertConflict::Refused), "none");
        assert_eq!(guard(InsertConflict::Skipped), "affected");
        assert_eq!(guard(InsertConflict::Replaced), "probe-other");
    }

    #[test]
    fn a_replacing_insert_of_a_key_the_server_computes_is_refused() {
        let now = crate::edit::CellExpression::new("NOW()", &[], &[]);
        let changes = ChangeSet {
            changes: vec![RowChange::Insert {
                cells: vec![
                    CellInput::Expression(now),
                    CellInput::Value(Value::Text("a".to_owned())),
                ],
            }],
        };
        let replacing = TestDialect::exact().with_insert_conflict(InsertConflict::Replaced);

        assert_eq!(
            plan_save(&replacing, &table(), &keyed_columns(), &by_id(), &changes).map(|_| ()),
            Err(BuildSqlError::ServerComputedValue { name: "id".to_owned() })
        );
        assert!(plan_save(&TestDialect::exact(), &table(), &keyed_columns(), &by_id(), &changes).is_ok());
    }

    #[test]
    fn a_replacing_insert_first_proves_no_row_has_its_key() {
        let dialect = TestDialect::exact().with_insert_conflict(InsertConflict::Replaced);
        let changes = ChangeSet {
            changes: vec![keyed_insert(9), insert("defaulted")],
        };

        let plan = plan_save(&dialect, &table(), &keyed_columns(), &by_id(), &changes).expect("the plan");

        let Some((probe, rows)) = plan.batch.steps[0].guard.probe() else {
            panic!("the insert has no probe");
        };
        assert_eq!(rows, 0);
        assert_eq!(
            probe.sql(),
            r#"SELECT COUNT(*) FROM (SELECT 1 AS one FROM "users" WHERE "id" = $1 LIMIT 2) AS probe"#
        );
        assert_eq!(probe.params()[0].value(), &Value::Int(9));
        assert!(
            matches!(plan.batch.steps[1].guard, RowGuard::None),
            "an insert that leaves its key out is the server's to refuse"
        );
    }

    #[test]
    fn an_update_of_a_partitions_own_columns_is_proved_by_a_probe_for_the_row() {
        let mut columns = keyed_columns();
        columns[0].partition_scoped = true;
        columns[1].partition_scoped = true;
        let changes = ChangeSet {
            changes: vec![update(Value::Int(7), "shared")],
        };

        let plan = plan_save(&TestDialect::exact(), &table(), &columns, &by_id(), &changes).expect("the plan");

        let Some((probe, rows)) = plan.batch.steps[0].guard.probe() else {
            panic!("the update has no probe");
        };
        assert_eq!(rows, 1);
        assert_eq!(probe.params()[0].value(), &Value::Int(7));
    }

    #[test]
    fn a_replacing_insert_into_a_table_without_a_key_is_refused() {
        let dialect = TestDialect::exact().with_insert_conflict(InsertConflict::Replaced);
        let changes = ChangeSet {
            changes: vec![keyed_insert(9)],
        };

        let refused = plan_save(&dialect, &table(), &columns(), &by_id(), &changes);

        assert_eq!(refused.err(), Some(BuildSqlError::NoRowIdentity));
    }

    #[test]
    fn plan_save_keeps_the_change_order_and_origins_align_with_steps() {
        let changes = ChangeSet {
            changes: vec![
                delete(Value::Int(2)),
                insert("a"),
                update(Value::Int(1), "c"),
                insert("b"),
                delete(Value::Int(3)),
            ],
        };

        let plan = plan(&TestDialect::exact(), &by_id(), &changes);

        assert_eq!(plan.origins, vec![0, 1, 2, 3, 4]);
        assert_eq!(plan.origins.len(), plan.batch.steps.len());
        let verbs: Vec<_> = plan
            .batch
            .steps
            .iter()
            .map(|step| step.statement.sql().split(' ').next().unwrap_or_default())
            .collect();
        assert_eq!(verbs, vec!["DELETE", "INSERT", "UPDATE", "INSERT", "DELETE"]);
        assert_eq!(plan.origin(4), Some(4));
        assert_eq!(plan.origin(5), None);
    }

    #[test]
    fn plan_save_batch_is_enforced_foreign_keys() {
        let plan = plan(&TestDialect::exact(), &by_id(), &one_of_each(Value::Int(7)));

        assert_eq!(plan.batch.foreign_keys, ForeignKeyMode::Enforced);
        assert_eq!(plan.batch.kind, WriteKind::RowChanges);
        assert_eq!(plan.batch.table, table());
    }

    #[test]
    fn an_unkeyed_table_takes_inserts_but_refuses_row_changes() {
        let inserts_only = ChangeSet {
            changes: vec![insert("new")],
        };

        let plan = plan(&TestDialect::exact(), &RowIdentity::Unordered, &inserts_only);
        let refused = plan_save(
            &TestDialect::exact(),
            &table(),
            &columns(),
            &RowIdentity::Unordered,
            &one_of_each(Value::Int(7)),
        );

        assert_eq!(plan.batch.len(), 1);
        assert_eq!(refused, Err(BuildSqlError::ReadOnlyRows));
    }
}
