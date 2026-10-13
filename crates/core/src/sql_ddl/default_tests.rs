use crate::query::ColumnInfo;

use super::{DraftColumn, build_alter_column};

fn loaded(default: Option<&str>) -> DraftColumn {
    DraftColumn::from_info(ColumnInfo {
        name: "status".into(),
        data_type: "varchar(20)".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: default.map(str::to_string),
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    })
}

fn with_default(default: Option<&str>, edited: Option<&str>) -> DraftColumn {
    let mut column = loaded(default);
    column.default_value = edited.map(str::to_string);
    column
}

fn not_null(default: Option<&str>) -> DraftColumn {
    let mut column = loaded(default);
    column.nullable = false;
    column
}

#[test]
fn a_mysql_nullability_change_restates_no_default_null_and_empty_defaults_as_loaded() {
    let restated = |default| build_alter_column("mysql", None, "t", &not_null(default)).unwrap();
    assert_eq!(
        restated(None),
        vec!["ALTER TABLE `t` MODIFY COLUMN `status` varchar(20) NOT NULL"]
    );
    assert_eq!(
        restated(Some("NULL")),
        vec!["ALTER TABLE `t` MODIFY COLUMN `status` varchar(20) NOT NULL DEFAULT NULL"]
    );
    assert_eq!(
        restated(Some("''")),
        vec!["ALTER TABLE `t` MODIFY COLUMN `status` varchar(20) NOT NULL DEFAULT ''"]
    );
    assert_eq!(
        restated(Some("'it''s'")),
        vec!["ALTER TABLE `t` MODIFY COLUMN `status` varchar(20) NOT NULL DEFAULT 'it''s'"]
    );
}

#[test]
fn a_postgres_nullability_change_leaves_every_kind_of_default_untouched() {
    for default in [None, Some("NULL"), Some("''"), Some("'pending'")] {
        let statements = build_alter_column("postgres", None, "t", &not_null(default)).unwrap();
        assert_eq!(
            statements,
            vec![r#"ALTER TABLE "t" ALTER COLUMN "status" SET NOT NULL"#],
            "{default:?}"
        );
    }
}

#[test]
fn a_postgres_default_edit_moves_between_no_default_null_and_empty_exactly() {
    let alter = |from, to| build_alter_column("postgres", None, "t", &with_default(from, to)).unwrap();
    assert_eq!(
        alter(None, Some("''")),
        vec![r#"ALTER TABLE "t" ALTER COLUMN "status" SET DEFAULT ''"#]
    );
    assert_eq!(
        alter(None, Some("NULL")),
        vec![r#"ALTER TABLE "t" ALTER COLUMN "status" SET DEFAULT NULL"#]
    );
    assert_eq!(
        alter(Some("''"), None),
        vec![r#"ALTER TABLE "t" ALTER COLUMN "status" DROP DEFAULT"#]
    );
    assert_eq!(
        alter(Some("''"), Some("NULL")),
        vec![r#"ALTER TABLE "t" ALTER COLUMN "status" SET DEFAULT NULL"#]
    );
}

#[test]
fn an_unchanged_empty_string_default_is_not_an_edit() {
    assert!(!loaded(Some("''")).differs_beyond_name());
    assert!(with_default(Some("''"), None).differs_beyond_name());
    assert!(with_default(None, Some("''")).differs_beyond_name());
}

#[test]
fn a_postgres_type_change_drops_the_default_first_and_sets_it_again_afterwards() {
    let mut column = loaded(Some("0"));
    column.data_type = "integer".into();
    assert_eq!(
        build_alter_column("postgres", None, "t", &column).unwrap(),
        vec![
            r#"ALTER TABLE "t" ALTER COLUMN "status" DROP DEFAULT"#,
            r#"ALTER TABLE "t" ALTER COLUMN "status" TYPE integer USING "status"::integer"#,
            r#"ALTER TABLE "t" ALTER COLUMN "status" SET DEFAULT (0)::integer"#,
        ]
    );
}

#[test]
fn a_postgres_type_change_that_also_clears_the_default_drops_it_once() {
    let mut column = loaded(Some("0"));
    column.data_type = "integer".into();
    column.default_value = None;
    assert_eq!(
        build_alter_column("postgres", None, "t", &column).unwrap(),
        vec![
            r#"ALTER TABLE "t" ALTER COLUMN "status" DROP DEFAULT"#,
            r#"ALTER TABLE "t" ALTER COLUMN "status" TYPE integer USING "status"::integer"#,
        ]
    );
}

#[test]
fn a_postgres_type_change_without_a_default_adds_no_default_statements() {
    let mut column = loaded(None);
    column.data_type = "integer".into();
    assert_eq!(
        build_alter_column("postgres", None, "t", &column).unwrap(),
        vec![r#"ALTER TABLE "t" ALTER COLUMN "status" TYPE integer USING "status"::integer"#]
    );
}

#[test]
fn a_postgres_type_change_that_also_edits_the_default_uses_the_edited_default() {
    let mut column = loaded(Some("'x'"));
    column.data_type = "integer".into();
    column.default_value = Some("5".into());
    assert_eq!(
        build_alter_column("postgres", None, "t", &column).unwrap(),
        vec![
            r#"ALTER TABLE "t" ALTER COLUMN "status" DROP DEFAULT"#,
            r#"ALTER TABLE "t" ALTER COLUMN "status" TYPE integer USING "status"::integer"#,
            r#"ALTER TABLE "t" ALTER COLUMN "status" SET DEFAULT 5"#,
        ]
    );
}

#[test]
fn a_postgres_primary_key_or_identity_toggle_on_an_existing_column_is_refused_not_ignored() {
    let mut key = loaded(None);
    key.primary_key = true;
    let mut identity = loaded(None);
    identity.auto_increment = true;
    for column in [key, identity] {
        assert!(matches!(
            build_alter_column("postgres", None, "t", &column),
            Err(super::BuildDdlError::PostgresNotSupported(_))
        ));
    }
}
