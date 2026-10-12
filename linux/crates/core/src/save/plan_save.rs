use crate::column::ColumnInfo;
use crate::dialect::SqlDialect;
use crate::dml::{BuildSqlError, build_delete, build_insert, build_key_probe, build_update};
use crate::foreign_key_mode::ForeignKeyMode;
use crate::meta::{RowIdentity, TableRef};
use crate::statement::{GuardedStatement, RowGuard, Statement};
use crate::value::Value;
use crate::write_batch::{WriteBatch, WriteKind};

use super::{ChangeOrigin, ChangeSet, SavePlan};

/// The batch that writes what the user changed, inserts first, then
/// updates, then deletes.
///
/// Every update and delete carries a guard that proves it touched
/// exactly the row it names, chosen by how far the key and the engine's
/// counts can be trusted:
/// - a unique key on an engine with exact counts: the affected count;
/// - a unique key elsewhere: a probe, because SQL Server adds the rows
///   its triggers touch to the count;
/// - an engine row id: the affected count, since the address is unique;
/// - a sorting key: a probe, because it can match several rows.
pub fn plan_save(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    identity: &RowIdentity,
    changes: &ChangeSet,
) -> Result<SavePlan, BuildSqlError> {
    let mut steps = Vec::with_capacity(changes.step_count());
    let mut origins = Vec::with_capacity(changes.step_count());

    for (index, insert) in changes.inserts.iter().enumerate() {
        let statement = build_insert(dialect, table, columns, &insert.cells)?;
        steps.push(GuardedStatement::unguarded(statement));
        origins.push(ChangeOrigin::Insert(index));
    }
    for (index, update) in changes.updates.iter().enumerate() {
        let statement = build_update(dialect, table, columns, identity, &update.key, &update.assignments)?;
        steps.push(guarded(dialect, table, columns, identity, &update.key, statement)?);
        origins.push(ChangeOrigin::Update(index));
    }
    for (index, key) in changes.deletes.iter().enumerate() {
        let statement = build_delete(dialect, table, columns, identity, key)?;
        steps.push(guarded(dialect, table, columns, identity, key, statement)?);
        origins.push(ChangeOrigin::Delete(index));
    }

    Ok(SavePlan {
        batch: WriteBatch::new(WriteKind::RowChanges, table.clone(), steps, ForeignKeyMode::Enforced),
        origins,
    })
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
    use crate::edit::CellInput;
    use crate::meta::EngineRowId;
    use crate::save::{RowInsert, RowUpdate};

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

    fn one_of_each(key: Value) -> ChangeSet {
        ChangeSet {
            inserts: vec![RowInsert {
                cells: vec![CellInput::Default, CellInput::Value(Value::Text("new".to_owned()))],
            }],
            updates: vec![RowUpdate {
                key: vec![key.clone()],
                assignments: vec![(1, Value::Text("renamed".to_owned()))],
            }],
            deletes: vec![vec![key]],
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

    #[test]
    fn plan_save_origins_align_with_steps() {
        let changes = ChangeSet {
            inserts: vec![
                RowInsert {
                    cells: vec![CellInput::Default, CellInput::Value(Value::Text("a".to_owned()))],
                },
                RowInsert {
                    cells: vec![CellInput::Default, CellInput::Value(Value::Text("b".to_owned()))],
                },
            ],
            updates: vec![RowUpdate {
                key: vec![Value::Int(1)],
                assignments: vec![(1, Value::Text("c".to_owned()))],
            }],
            deletes: vec![vec![Value::Int(2)], vec![Value::Int(3)]],
        };

        let plan = plan(&TestDialect::exact(), &by_id(), &changes);

        assert_eq!(
            plan.origins,
            vec![
                ChangeOrigin::Insert(0),
                ChangeOrigin::Insert(1),
                ChangeOrigin::Update(0),
                ChangeOrigin::Delete(0),
                ChangeOrigin::Delete(1),
            ]
        );
        assert_eq!(plan.origins.len(), plan.batch.steps.len());
        assert!(plan.batch.steps[0].statement.sql().starts_with("INSERT"));
        assert!(plan.batch.steps[2].statement.sql().starts_with("UPDATE"));
        assert!(plan.batch.steps[4].statement.sql().starts_with("DELETE"));
        assert_eq!(plan.origin(4), Some(ChangeOrigin::Delete(1)));
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
            inserts: one_of_each(Value::Int(7)).inserts,
            ..ChangeSet::default()
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
