use crate::query::ColumnInfo;

use super::diff::diff_to_ops;
use super::types::{CommentPlacement, column_comment_placement, validate_safe_comment};
use super::{
    BuildDdlError, DraftColumn, StructureOp, build_add_column, build_alter_column, build_create_table,
    build_reorder_column, materialize_ops,
};

fn info(comment: Option<&str>) -> ColumnInfo {
    ColumnInfo {
        name: "x".into(),
        data_type: "text".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: comment.map(str::to_string),
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

#[test]
fn every_driver_agrees_with_the_placement_table() {
    assert_eq!(column_comment_placement("mysql"), CommentPlacement::Inline);
    assert_eq!(column_comment_placement("clickhouse"), CommentPlacement::Inline);
    assert_eq!(column_comment_placement("postgres"), CommentPlacement::Separate);
    assert_eq!(column_comment_placement("mssql"), CommentPlacement::Separate);
    for unsupported in ["sqlite", "duckdb", "mongodb", "redis", "unknown"] {
        assert_eq!(column_comment_placement(unsupported), CommentPlacement::Unsupported);
    }
}

#[test]
fn a_draft_starts_from_the_loaded_comment() {
    let draft = DraftColumn::from_info(info(Some("loaded")));
    assert_eq!(draft.comment.as_deref(), Some("loaded"));
    assert!(!draft.differs_beyond_name());
}

#[test]
fn changing_only_the_comment_is_a_change_beyond_the_name() {
    let mut draft = DraftColumn::from_info(info(None));
    draft.comment = Some("added".into());
    assert!(draft.differs_beyond_name());

    let mut cleared = DraftColumn::from_info(info(Some("loaded")));
    cleared.comment = None;
    assert!(cleared.differs_beyond_name());
}

fn draft(name: &str, comment: Option<&str>) -> DraftColumn {
    DraftColumn {
        original: None,
        name: name.into(),
        data_type: "text".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: None,
        comment: comment.map(str::to_string),
        collation: None,
    }
}

fn edited(loaded: Option<&str>, edit: Option<&str>) -> DraftColumn {
    let mut column = DraftColumn::from_info(ColumnInfo {
        name: "label".into(),
        comment: loaded.map(str::to_string),
        ..info(None)
    });
    column.comment = edit.map(str::to_string);
    column
}

#[test]
fn a_comment_only_edit_raises_an_alter_on_every_writable_dialect() {
    for driver_id in ["mysql", "postgres", "mssql", "clickhouse"] {
        let column = edited(None, Some("why it exists"));
        assert!(column.differs_beyond_name(), "{driver_id}");
        let original = vec![column.original.clone().unwrap_or_else(|| info(None))];
        let ops = diff_to_ops(None, "t", "t", &original, &[column], &[], &[], &[], &[]);
        assert!(
            ops.iter().any(|op| matches!(op, StructureOp::AlterColumn { .. })),
            "{driver_id} must raise an alter for a comment-only edit: {ops:?}"
        );
    }
}

#[test]
fn mysql_restates_the_comment_when_only_the_type_changed() {
    let mut column = edited(Some("why it exists"), Some("why it exists"));
    column.data_type = "varchar(64)".into();
    let stmts = build_alter_column("mysql", None, "t", &column).unwrap();
    assert_eq!(stmts.len(), 1);
    assert!(
        stmts[0].contains("COMMENT 'why it exists'"),
        "MODIFY COLUMN replaces the definition, so the comment has to be restated: {stmts:?}"
    );
}

#[test]
fn mysql_clears_a_comment_with_an_empty_string() {
    let column = edited(Some("why it exists"), None);
    let stmts = build_alter_column("mysql", None, "t", &column).unwrap();
    assert!(stmts[0].contains("COMMENT ''"), "{stmts:?}");
}

#[test]
fn mysql_emits_no_comment_clause_for_a_column_that_never_had_one() {
    let column = edited(None, None);
    let stmts = build_alter_column("mysql", None, "t", &column).unwrap();
    assert!(!stmts[0].contains("COMMENT"), "{stmts:?}");

    let created = build_create_table("mysql", None, "t", &[draft("label", None)], &[], &[]).unwrap();
    assert!(!created[0].contains("COMMENT"), "{created:?}");
}

#[test]
fn a_mysql_reorder_keeps_the_comment() {
    let column = edited(Some("why it exists"), Some("why it exists"));
    let sql = build_reorder_column("mysql", None, "t", &column, Some("id")).unwrap();
    assert!(sql.contains("COMMENT 'why it exists'"), "{sql}");
    assert!(sql.ends_with("AFTER `id`"), "{sql}");
}

#[test]
fn postgres_emits_a_separate_comment_statement_after_the_alter() {
    let mut column = edited(None, Some("why it exists"));
    column.data_type = "varchar(64)".into();
    let stmts = build_alter_column("postgres", None, "t", &column).unwrap();
    assert_eq!(stmts.len(), 2, "{stmts:?}");
    assert!(stmts[0].contains("TYPE varchar(64)"));
    assert_eq!(stmts[1], "COMMENT ON COLUMN \"t\".\"label\" IS 'why it exists'");
}

#[test]
fn postgres_clears_a_comment_with_is_null() {
    let column = edited(Some("why it exists"), None);
    let stmts = build_alter_column("postgres", None, "t", &column).unwrap();
    assert_eq!(stmts, vec!["COMMENT ON COLUMN \"t\".\"label\" IS NULL".to_string()]);
}

#[test]
fn a_postgres_comment_only_change_is_not_a_no_op() {
    let column = edited(None, Some("why it exists"));
    let stmts = build_alter_column("postgres", None, "t", &column).unwrap();
    assert_eq!(
        stmts,
        vec!["COMMENT ON COLUMN \"t\".\"label\" IS 'why it exists'".to_string()]
    );
}

#[test]
fn mssql_branches_between_adding_and_updating_the_extended_property() {
    let column = edited(None, Some("why it exists"));
    let stmts = build_alter_column("mssql", None, "t", &column).unwrap();
    assert_eq!(stmts.len(), 1, "{stmts:?}");
    let sql = &stmts[0];
    assert!(
        sql.contains("DECLARE @schema sysname = COALESCE(NULL, SCHEMA_NAME())"),
        "{sql}"
    );
    assert!(sql.contains("EXEC sp_updateextendedproperty"), "{sql}");
    assert!(sql.contains("ELSE EXEC sp_addextendedproperty"), "{sql}");
    assert!(sql.contains("@value = N'why it exists'"), "{sql}");
    assert!(sql.contains("@level0name = @schema"), "{sql}");

    let cleared = build_alter_column("mssql", None, "t", &edited(Some("why it exists"), None)).unwrap();
    assert!(cleared[0].contains("EXEC sp_dropextendedproperty"), "{cleared:?}");
    assert!(!cleared[0].contains("sp_addextendedproperty"), "{cleared:?}");
}

#[test]
fn sqlite_refuses_a_column_comment() {
    let column = draft("label", Some("why it exists"));
    let err = build_add_column("sqlite", None, "t", &column).unwrap_err();
    assert!(matches!(err, BuildDdlError::CommentsNotSupported(_)), "{err:?}");
    let err = build_create_table("sqlite", None, "t", &[column], &[], &[]).unwrap_err();
    assert!(matches!(err, BuildDdlError::CommentsNotSupported(_)), "{err:?}");
}

#[test]
fn a_quote_in_a_comment_is_doubled_on_every_dialect() {
    for (driver_id, needle) in [
        ("mysql", "COMMENT 'o''brien'"),
        ("clickhouse", "COMMENT 'o''brien'"),
        ("postgres", "IS 'o''brien'"),
        ("mssql", "@value = N'o''brien'"),
    ] {
        let stmts = build_create_table(driver_id, None, "t", &[draft("label", Some("o'brien"))], &[], &[]).unwrap();
        assert!(
            stmts.iter().any(|s| s.contains(needle)),
            "{driver_id} must double the quote: {stmts:?}"
        );
    }
}

#[test]
fn mysql_refuses_backslash_comments_and_other_dialects_preserve_them() {
    let column = draft("label", Some("path\\"));
    let mysql = build_create_table("mysql", None, "t", std::slice::from_ref(&column), &[], &[]).unwrap_err();
    assert!(
        matches!(&mysql, BuildDdlError::UnsafeComment(message) if message.contains("SQL mode")),
        "{mysql:?}"
    );
    let mysql_alter = build_alter_column("mysql", None, "t", &edited(None, Some("path\\"))).unwrap_err();
    assert!(
        matches!(mysql_alter, BuildDdlError::UnsafeComment(_)),
        "{mysql_alter:?}"
    );
    let clickhouse = build_create_table("clickhouse", None, "t", std::slice::from_ref(&column), &[], &[]).unwrap();
    assert!(
        clickhouse.iter().any(|s| s.contains("COMMENT 'path\\\\'")),
        "{clickhouse:?}"
    );
    let postgres = build_create_table("postgres", None, "t", std::slice::from_ref(&column), &[], &[]).unwrap();
    assert!(postgres.iter().any(|s| s.contains("IS 'path\\'")), "{postgres:?}");
    let mssql = build_create_table("mssql", None, "t", &[column], &[], &[]).unwrap();
    assert!(mssql.iter().any(|s| s.contains("N'path\\'")), "{mssql:?}");
}

#[test]
fn a_semicolon_in_a_comment_cannot_fragment_the_statement_batch() {
    // The save path hands the driver a Vec of discrete statements and
    // nothing re-splits one on `;`, so prose may carry both.
    let comment = "-- see ticket #42; deprecated";
    for driver_id in ["mysql", "clickhouse", "postgres", "mssql"] {
        let stmts = build_create_table(driver_id, None, "t", &[draft("label", Some(comment))], &[], &[]).unwrap();
        assert!(
            stmts.iter().any(|s| s.contains(comment)),
            "{driver_id} must keep the comment verbatim: {stmts:?}"
        );
        let carrier = stmts.iter().filter(|s| s.contains(comment)).count();
        assert_eq!(carrier, 1, "{driver_id}: one statement carries the comment: {stmts:?}");
    }
}

#[test]
fn a_comment_that_cannot_be_quoted_is_rejected_before_emission() {
    for bad in ["two\nlines", "nul\0byte", "sep\u{2028}here"] {
        let err = build_create_table("mysql", None, "t", &[draft("label", Some(bad))], &[], &[]).unwrap_err();
        assert!(matches!(err, BuildDdlError::UnsafeComment(_)), "{err:?}");
    }
    let too_long = "a".repeat(1025);
    let err = build_create_table("postgres", None, "t", &[draft("label", Some(&too_long))], &[], &[]).unwrap_err();
    assert!(matches!(err, BuildDdlError::UnsafeComment(_)), "{err:?}");
}

#[test]
fn a_comment_may_contain_a_semicolon_and_a_sql_comment_marker() {
    assert!(validate_safe_comment("-- see ticket #42; deprecated").is_ok());
    assert!(validate_safe_comment("/* legacy */ kept for the importer").is_ok());
}

#[test]
fn a_comment_carrying_a_line_terminator_is_rejected() {
    for bad in [
        "two\nlines",
        "two\rlines",
        "nul\0byte",
        "sep\u{2028}here",
        "para\u{2029}here",
    ] {
        assert!(matches!(
            validate_safe_comment(bad),
            Err(BuildDdlError::UnsafeComment(_))
        ));
    }
}

#[test]
fn a_comment_longer_than_the_engine_cap_is_rejected() {
    assert!(validate_safe_comment(&"a".repeat(1024)).is_ok());
    assert!(matches!(
        validate_safe_comment(&"a".repeat(1025)),
        Err(BuildDdlError::UnsafeComment(_))
    ));
}

#[test]
fn a_new_column_carries_its_comment_on_every_writable_dialect() {
    for (driver_id, needle) in [
        ("mysql", "COMMENT 'why it exists'"),
        ("clickhouse", "COMMENT 'why it exists'"),
        ("postgres", "IS 'why it exists'"),
        ("mssql", "@value = N'why it exists'"),
    ] {
        let column = draft("label", Some("why it exists"));
        let added = build_add_column(driver_id, None, "t", &column).unwrap();
        assert!(
            added.iter().any(|s| s.contains(needle)),
            "{driver_id} add column: {added:?}"
        );
        let created = build_create_table(driver_id, None, "t", &[column], &[], &[]).unwrap();
        assert!(
            created.iter().any(|s| s.contains(needle)),
            "{driver_id} create table: {created:?}"
        );
    }
}

#[test]
fn a_comment_edited_in_the_same_save_as_a_rename_uses_the_new_name() {
    let mut column = DraftColumn::from_info(ColumnInfo {
        name: "label".into(),
        comment: None,
        ..info(None)
    });
    column.name = "title".into();
    column.comment = Some("why it exists".into());
    let original = vec![column.original.clone().unwrap_or_else(|| info(None))];
    let ops = diff_to_ops(None, "t", "t", &original, &[column], &[], &[], &[], &[]);
    let stmts = materialize_ops(&ops, "postgres").unwrap();
    assert_eq!(
        stmts,
        vec![
            "ALTER TABLE \"t\" RENAME COLUMN \"label\" TO \"title\"".to_string(),
            "COMMENT ON COLUMN \"t\".\"title\" IS 'why it exists'".to_string(),
        ]
    );
}
