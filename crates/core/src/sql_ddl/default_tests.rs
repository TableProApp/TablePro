use crate::query::ColumnInfo;

use super::{DraftColumn, build_alter_column, diff_to_ops, materialize_ops};

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

fn named(name: &str, default: Option<&str>) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        ..loaded(default).original.unwrap()
    }
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

fn index(name: &str, constraint: Option<&str>) -> crate::query::IndexInfo {
    crate::query::IndexInfo {
        name: name.into(),
        columns: vec!["email".into()],
        unique: true,
        primary: false,
        predicate: None,
        constraint: constraint.map(str::to_string),
        has_expression_key: false,
    }
}

fn drop_statements(driver_id: &str, original: &[crate::query::IndexInfo]) -> Vec<String> {
    let ops = super::diff::diff_to_ops(None, "t", "t", &[], &[], original, &[], &[], &[]);
    super::materialize_ops(&ops, driver_id).unwrap()
}

#[test]
fn a_postgres_index_owned_by_a_constraint_is_dropped_through_the_constraint() {
    let owned = [index("t_email_key", Some("t_email_key")), index("t_plain", None)];
    assert_eq!(
        drop_statements("postgres", &owned),
        vec![
            r#"ALTER TABLE "t" DROP CONSTRAINT "t_email_key""#,
            r#"DROP INDEX IF EXISTS "t_plain""#,
        ]
    );
}

#[test]
fn another_engine_drops_the_index_by_name_even_when_a_constraint_is_recorded() {
    let owned = [index("t_email_key", Some("t_email_key"))];
    assert_eq!(
        drop_statements("mysql", &owned),
        vec!["ALTER TABLE `t` DROP INDEX `t_email_key`"]
    );
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

#[test]
fn a_new_column_marked_primary_key_is_added_with_its_primary_key() {
    let mut key = loaded(None);
    key.original = None;
    key.primary_key = true;
    key.nullable = false;
    let postgres = super::build_add_column("postgres", None, "t", &key).unwrap();
    assert!(postgres[0].contains("PRIMARY KEY"), "{postgres:?}");
    key.auto_increment = true;
    let serial = super::build_add_column("postgres", None, "t", &key).unwrap();
    assert!(serial[0].contains("SERIAL PRIMARY KEY"), "{serial:?}");
    let mysql = super::build_add_column("mysql", None, "t", &key).unwrap();
    assert!(mysql[0].contains("AUTO_INCREMENT PRIMARY KEY"), "{mysql:?}");
}

#[test]
fn sqlite_refuses_a_new_primary_key_column_instead_of_dropping_the_key() {
    let mut key = loaded(None);
    key.original = None;
    key.primary_key = true;
    assert!(matches!(
        super::build_add_column("sqlite", None, "t", &key),
        Err(super::BuildDdlError::SqliteNotSupported(_))
    ));
}

#[test]
fn a_sql_server_type_change_drops_the_default_first_and_adds_it_again_afterwards() {
    let mut column = loaded(Some("0"));
    column.data_type = "int".into();
    let statements = build_alter_column("mssql", Some("dbo"), "t", &column).unwrap();
    assert_eq!(statements.len(), 3, "{statements:#?}");
    assert!(statements[0].contains("sys.default_constraints"), "{}", statements[0]);
    assert_eq!(statements[1], "ALTER TABLE [dbo].[t] ALTER COLUMN [status] int NULL");
    assert_eq!(statements[2], "ALTER TABLE [dbo].[t] ADD DEFAULT (0) FOR [status]");
}

#[test]
fn a_sql_server_type_change_without_a_default_adds_no_default_statements() {
    let mut column = loaded(None);
    column.data_type = "int".into();
    assert_eq!(
        build_alter_column("mssql", Some("dbo"), "t", &column).unwrap(),
        vec!["ALTER TABLE [dbo].[t] ALTER COLUMN [status] int NULL"]
    );
}

#[test]
fn a_sql_server_default_edit_drops_the_old_constraint_before_any_alter() {
    let mut column = with_default(Some("0"), Some("1"));
    column.data_type = "int".into();
    let statements = build_alter_column("mssql", Some("dbo"), "t", &column).unwrap();
    assert!(statements[0].contains("sys.default_constraints"), "{statements:#?}");
    assert_eq!(statements[1], "ALTER TABLE [dbo].[t] ALTER COLUMN [status] int NULL");
    assert_eq!(statements[2], "ALTER TABLE [dbo].[t] ADD DEFAULT (1) FOR [status]");
}

#[test]
fn dropping_a_sql_server_column_with_a_default_drops_its_constraint_first() {
    let original = vec![named("n", Some("0")), named("plain", None), named("kept", None)];
    let current = vec![DraftColumn::from_info(named("kept", None))];
    let ops = diff_to_ops(Some("dbo"), "t", "t", &original, &current, &[], &[], &[], &[]);
    let statements = materialize_ops(&ops, "mssql").unwrap();
    let drop_default = statements
        .iter()
        .position(|statement| statement.contains("sys.default_constraints") && statement.contains("'n'"))
        .expect("the default constraint of n is dropped");
    let drop_column = statements
        .iter()
        .position(|statement| statement == "ALTER TABLE [dbo].[t] DROP COLUMN [n]")
        .expect("n is dropped");
    assert!(drop_default < drop_column, "{statements:#?}");
    assert!(
        !statements
            .iter()
            .any(|statement| statement.contains("sys.default_constraints") && statement.contains("'plain'")),
        "{statements:#?}"
    );
}
