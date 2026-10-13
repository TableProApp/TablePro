use crate::query::{ForeignKeyInfo, IndexInfo};

use super::{StructureOp, diff_to_ops, materialize_ops};

fn index(name: &str, columns: &[&str], unique: bool) -> IndexInfo {
    IndexInfo {
        name: name.into(),
        columns: columns.iter().map(|column| column.to_string()).collect(),
        unique,
        primary: false,
        predicate: None,
        constraint: None,
    }
}

fn foreign_key(name: &str, column: &str, on_delete: Option<&str>) -> ForeignKeyInfo {
    ForeignKeyInfo {
        name: name.into(),
        columns: vec![column.into()],
        ref_schema: None,
        ref_table: "parent".into(),
        ref_columns: vec!["id".into()],
        on_delete: on_delete.map(str::to_string),
        on_update: None,
    }
}

fn diff(
    original_indexes: &[IndexInfo],
    current_indexes: &[IndexInfo],
    original_fks: &[ForeignKeyInfo],
    current_fks: &[ForeignKeyInfo],
) -> Vec<StructureOp> {
    diff_to_ops(
        None,
        "t",
        "t",
        &[],
        &[],
        original_indexes,
        current_indexes,
        original_fks,
        current_fks,
    )
}

#[test]
fn an_unchanged_index_or_key_produces_no_operation() {
    let indexes = [index("idx_a", &["a"], false)];
    let keys = [foreign_key("fk_a", "a", Some("CASCADE"))];

    assert!(diff(&indexes, &indexes, &keys, &keys).is_empty());
}

#[test]
fn an_index_replaced_under_the_same_name_is_dropped_and_created_again() {
    let original = [index("idx_a", &["a"], false)];
    let replaced = [index("idx_a", &["a", "b"], true)];

    let ops = diff(&original, &replaced, &[], &[]);

    assert!(
        matches!(
            ops.as_slice(),
            [StructureOp::DropIndex { .. }, StructureOp::AddIndex { .. }]
        ),
        "{ops:?}"
    );
    let statements = materialize_ops(&ops, "postgres").unwrap();
    assert!(statements[0].starts_with("DROP INDEX"), "{statements:?}");
    assert!(
        statements[1].contains("UNIQUE") && statements[1].contains("\"a\", \"b\""),
        "{statements:?}"
    );
}

#[test]
fn a_foreign_key_replaced_under_the_same_name_is_dropped_and_added_again() {
    let original = [foreign_key("fk_a", "a", None)];
    let replaced = [foreign_key("fk_a", "a", Some("CASCADE"))];

    let ops = diff(&[], &[], &original, &replaced);

    assert!(
        matches!(
            ops.as_slice(),
            [StructureOp::DropForeignKey { .. }, StructureOp::AddForeignKey { .. }]
        ),
        "{ops:?}"
    );
    let statements = materialize_ops(&ops, "postgres").unwrap();
    assert!(statements[1].contains("ON DELETE CASCADE"), "{statements:?}");
}

#[test]
fn removing_one_of_two_indexes_leaves_the_other_alone() {
    let both = [index("idx_a", &["a"], false), index("idx_b", &["b"], false)];

    let ops = diff(&both, &both[..1], &[], &[]);

    assert!(
        matches!(ops.as_slice(), [StructureOp::DropIndex { index_name, .. }] if index_name == "idx_b"),
        "{ops:?}"
    );
}
