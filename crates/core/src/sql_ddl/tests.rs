use crate::query::{ColumnInfo, ForeignKeyInfo, IndexInfo};

use super::diff::diff_to_ops;
use super::types::{validate_safe_default, validate_safe_type};
use super::{
    BuildDdlError, DraftColumn, StructureOp, build_add_column, build_add_foreign_key, build_alter_column,
    build_create_index, build_create_table, build_drop_column, build_drop_foreign_key, build_drop_index,
    build_drop_table, build_rename_column, build_rename_table, build_reorder_column, materialize_ops,
    supported_fk_actions,
};

fn dc(name: &str, ty: &str) -> DraftColumn {
    DraftColumn {
        original: None,
        name: name.into(),
        data_type: ty.into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: None,
        comment: None,
        collation: None,
    }
}

fn pk(mut col: DraftColumn) -> DraftColumn {
    col.primary_key = true;
    col.nullable = false;
    col
}

fn ai(mut col: DraftColumn) -> DraftColumn {
    col.auto_increment = true;
    col
}

fn nn(mut col: DraftColumn) -> DraftColumn {
    col.nullable = false;
    col
}

fn def(mut col: DraftColumn, default: &str) -> DraftColumn {
    col.default_value = Some(default.into());
    col
}

#[test]
fn create_table_simple_postgres() {
    let cols = vec![pk(ai(dc("id", "integer"))), nn(dc("email", "text"))];
    let stmts = build_create_table("postgres", None, "users", &cols, &[], &[]).unwrap();
    assert_eq!(stmts.len(), 1);
    assert!(stmts[0].contains("\"id\" SERIAL PRIMARY KEY"));
    assert!(stmts[0].contains("\"email\" text NOT NULL"));
    assert!(stmts[0].starts_with("CREATE TABLE \"users\""));
}

#[test]
fn create_table_simple_mysql() {
    let cols = vec![pk(ai(dc("id", "INT"))), nn(dc("email", "VARCHAR(255)"))];
    let stmts = build_create_table("mysql", None, "users", &cols, &[], &[]).unwrap();
    assert_eq!(stmts.len(), 1);
    assert!(stmts[0].contains("`id` INT NOT NULL AUTO_INCREMENT PRIMARY KEY"));
    assert!(stmts[0].contains("`email` VARCHAR(255) NOT NULL"));
}

#[test]
fn create_table_simple_sqlite() {
    let cols = vec![pk(ai(dc("id", "INTEGER"))), nn(dc("email", "TEXT"))];
    let stmts = build_create_table("sqlite", None, "users", &cols, &[], &[]).unwrap();
    assert_eq!(stmts.len(), 1);
    assert!(stmts[0].contains("\"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL"));
    assert!(stmts[0].contains("\"email\" TEXT NOT NULL"));
}

#[test]
fn create_table_simple_mssql() {
    let mut cols = vec![ai(dc("id", "INT")), nn(dc("email", "VARCHAR(255)"))];
    cols[0].primary_key = true;
    let stmts = build_create_table("mssql", None, "users", &cols, &[], &[]).unwrap();
    assert_eq!(stmts.len(), 1);
    assert!(stmts[0].contains("[id] INT IDENTITY(1,1) PRIMARY KEY"));
    assert!(!stmts[0].contains("DEFAULT"));
    assert!(stmts[0].contains("[email] VARCHAR(255) NOT NULL"));
    assert!(stmts[0].starts_with("CREATE TABLE [users]"));
}

#[test]
fn create_table_postgres_bigserial() {
    let cols = vec![pk(ai(dc("id", "bigint")))];
    let stmts = build_create_table("postgres", None, "t", &cols, &[], &[]).unwrap();
    assert!(stmts[0].contains("BIGSERIAL"));
}

#[test]
fn create_table_composite_pk() {
    let cols = vec![nn(pk(dc("a", "int"))), nn(pk(dc("b", "int"))), dc("c", "text")];
    let stmts = build_create_table("postgres", None, "t", &cols, &[], &[]).unwrap();
    // Inline PK only fires for single-column PK — composite emits
    // a separate PRIMARY KEY (a, b) clause at the end.
    assert!(!stmts[0].contains("PRIMARY KEY,"));
    assert!(stmts[0].contains("PRIMARY KEY (\"a\", \"b\")"));
}

#[test]
fn create_table_with_default() {
    let cols = vec![nn(pk(ai(dc("id", "integer")))), def(dc("status", "text"), "'pending'")];
    let stmts = build_create_table("postgres", None, "t", &cols, &[], &[]).unwrap();
    assert!(stmts[0].contains("DEFAULT 'pending'"));
}

#[test]
fn create_table_with_schema() {
    let cols = vec![nn(pk(dc("id", "integer")))];
    let stmts = build_create_table("postgres", Some("auth"), "users", &cols, &[], &[]).unwrap();
    assert!(stmts[0].starts_with("CREATE TABLE \"auth\".\"users\""));
}

#[test]
fn create_table_with_secondary_index() {
    let cols = vec![nn(pk(ai(dc("id", "integer")))), nn(dc("email", "text"))];
    let idx = IndexInfo {
        name: "users_email_idx".into(),
        columns: vec!["email".into()],
        unique: true,
        primary: false,
        predicate: None,
    };
    let stmts = build_create_table("postgres", None, "users", &cols, &[idx], &[]).unwrap();
    assert_eq!(stmts.len(), 2);
    assert!(stmts[1].contains("CREATE UNIQUE INDEX"));
    assert!(stmts[1].contains("\"users_email_idx\""));
}

#[test]
fn create_table_skips_primary_index() {
    let cols = vec![nn(pk(ai(dc("id", "integer"))))];
    let pk_idx = IndexInfo {
        name: "users_pkey".into(),
        columns: vec!["id".into()],
        unique: true,
        primary: true,
        predicate: None,
    };
    let stmts = build_create_table("postgres", None, "users", &cols, &[pk_idx], &[]).unwrap();
    assert_eq!(stmts.len(), 1, "primary index must not produce a separate CREATE INDEX");
}

#[test]
fn create_table_with_foreign_key() {
    let cols = vec![nn(pk(ai(dc("id", "integer")))), nn(dc("user_id", "integer"))];
    let fk = ForeignKeyInfo {
        name: "fk_user".into(),
        columns: vec!["user_id".into()],
        ref_schema: None,
        ref_table: "users".into(),
        ref_columns: vec!["id".into()],
        on_delete: Some("CASCADE".into()),
        on_update: None,
    };
    let stmts = build_create_table("postgres", None, "orders", &cols, &[], &[fk]).unwrap();
    assert_eq!(stmts.len(), 2);
    assert!(stmts[1].contains("ADD CONSTRAINT \"fk_user\""));
    assert!(stmts[1].contains("ON DELETE CASCADE"));
}

#[test]
fn create_table_sqlite_emits_pragma_for_fk() {
    let cols = vec![nn(pk(dc("id", "INTEGER"))), nn(dc("user_id", "INTEGER"))];
    let fk = ForeignKeyInfo {
        name: "fk_user".into(),
        columns: vec!["user_id".into()],
        ref_schema: None,
        ref_table: "users".into(),
        ref_columns: vec!["id".into()],
        on_delete: None,
        on_update: None,
    };
    let stmts = build_create_table("sqlite", None, "orders", &cols, &[], &[fk]).unwrap();
    assert_eq!(stmts.len(), 3);
    assert_eq!(stmts[1], "PRAGMA foreign_keys = ON");
}

#[test]
fn create_table_rejects_empty_name() {
    let cols = vec![dc("a", "int")];
    let err = build_create_table("postgres", None, "", &cols, &[], &[]).unwrap_err();
    assert!(matches!(err, BuildDdlError::EmptyTableName));
}

#[test]
fn create_table_rejects_no_columns() {
    let err = build_create_table("postgres", None, "t", &[], &[], &[]).unwrap_err();
    assert!(matches!(err, BuildDdlError::NoColumns));
}

#[test]
fn drop_table_basic() {
    assert_eq!(
        build_drop_table("postgres", None, "users", false, false).unwrap(),
        "DROP TABLE \"users\""
    );
    assert_eq!(
        build_drop_table("mysql", None, "users", true, false).unwrap(),
        "DROP TABLE IF EXISTS `users`"
    );
    assert_eq!(
        build_drop_table("postgres", Some("auth"), "users", true, true).unwrap(),
        "DROP TABLE IF EXISTS \"auth\".\"users\" CASCADE"
    );
}

#[test]
fn drop_table_cascade_only_postgres() {
    assert!(
        !build_drop_table("mysql", None, "t", false, true)
            .unwrap()
            .contains("CASCADE")
    );
    assert!(
        !build_drop_table("sqlite", None, "t", false, true)
            .unwrap()
            .contains("CASCADE")
    );
}

#[test]
fn drop_table_mssql_no_cascade() {
    assert_eq!(
        build_drop_table("mssql", None, "users", false, false).unwrap(),
        "DROP TABLE [users]"
    );
    assert_eq!(
        build_drop_table("mssql", Some("dbo"), "users", true, true).unwrap(),
        "DROP TABLE IF EXISTS [dbo].[users]"
    );
}

#[test]
fn rename_table_each_driver() {
    assert_eq!(
        build_rename_table("postgres", None, "old", "new").unwrap(),
        "ALTER TABLE \"old\" RENAME TO \"new\""
    );
    assert_eq!(
        build_rename_table("mysql", None, "old", "new").unwrap(),
        "ALTER TABLE `old` RENAME TO `new`"
    );
    assert_eq!(
        build_rename_table("sqlite", None, "old", "new").unwrap(),
        "ALTER TABLE \"old\" RENAME TO \"new\""
    );
}

#[test]
fn rename_table_mssql() {
    assert_eq!(
        build_rename_table("mssql", None, "old", "new").unwrap(),
        "EXEC sp_rename '[old]', 'new'"
    );
    assert_eq!(
        build_rename_table("mssql", Some("dbo"), "old", "new").unwrap(),
        "EXEC sp_rename '[dbo].[old]', 'new'"
    );
}

#[test]
fn rename_table_mssql_escapes_embedded_quote() {
    // sp_rename's arguments are SQL string literals; an embedded
    // `'` in a name must be doubled or it would close the literal
    // early and splice the remainder in as a second statement.
    let sql = build_rename_table("mssql", None, "o'brien", "new'table").unwrap();
    assert_eq!(sql, "EXEC sp_rename '[o''brien]', 'new''table'");
}

#[test]
fn add_column_basic() {
    let col = nn(def(dc("created_at", "timestamp"), "now()"));
    assert_eq!(
        build_add_column("postgres", None, "users", &col).unwrap(),
        vec!["ALTER TABLE \"users\" ADD COLUMN \"created_at\" timestamp NOT NULL DEFAULT now()"]
    );
}

#[test]
fn add_column_sqlite_not_null_without_default_rejected() {
    let col = nn(dc("name", "text"));
    let err = build_add_column("sqlite", None, "t", &col).unwrap_err();
    assert!(matches!(err, BuildDdlError::SqliteNotSupported(_)));
}

#[test]
fn add_column_sqlite_with_default_ok() {
    let col = nn(def(dc("name", "TEXT"), "''"));
    let stmts = build_add_column("sqlite", None, "t", &col).unwrap();
    assert!(stmts[0].starts_with("ALTER TABLE \"t\" ADD COLUMN"));
}

#[test]
fn add_column_mssql_no_column_keyword() {
    let col = nn(def(dc("created_at", "DATETIME2"), "SYSUTCDATETIME()"));
    let stmts = build_add_column("mssql", None, "users", &col).unwrap();
    assert_eq!(
        stmts,
        vec!["ALTER TABLE [users] ADD [created_at] DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()"]
    );
    assert!(!stmts[0].contains("ADD COLUMN"));
}

#[test]
fn drop_column_each_driver() {
    assert_eq!(
        build_drop_column("postgres", None, "users", "email").unwrap(),
        "ALTER TABLE \"users\" DROP COLUMN \"email\""
    );
    assert_eq!(
        build_drop_column("mysql", None, "users", "email").unwrap(),
        "ALTER TABLE `users` DROP COLUMN `email`"
    );
    assert_eq!(
        build_drop_column("sqlite", None, "users", "email").unwrap(),
        "ALTER TABLE \"users\" DROP COLUMN \"email\""
    );
}

#[test]
fn drop_column_mssql() {
    assert_eq!(
        build_drop_column("mssql", None, "users", "email").unwrap(),
        "ALTER TABLE [users] DROP COLUMN [email]"
    );
}

#[test]
fn rename_column_each_driver() {
    assert_eq!(
        build_rename_column("postgres", None, "t", "old", "new").unwrap(),
        "ALTER TABLE \"t\" RENAME COLUMN \"old\" TO \"new\""
    );
    assert_eq!(
        build_rename_column("mysql", None, "t", "old", "new").unwrap(),
        "ALTER TABLE `t` RENAME COLUMN `old` TO `new`"
    );
}

#[test]
fn rename_column_mssql() {
    assert_eq!(
        build_rename_column("mssql", None, "t", "old", "new").unwrap(),
        "EXEC sp_rename '[t].[old]', 'new', 'COLUMN'"
    );
    assert_eq!(
        build_rename_column("mssql", Some("dbo"), "t", "old", "new").unwrap(),
        "EXEC sp_rename '[dbo].[t].[old]', 'new', 'COLUMN'"
    );
}

#[test]
fn rename_column_mssql_escapes_embedded_quote() {
    let sql = build_rename_column("mssql", None, "t", "o'brien", "new'name").unwrap();
    assert_eq!(sql, "EXEC sp_rename '[t].[o''brien]', 'new''name', 'COLUMN'");
}

#[test]
fn alter_column_postgres_type_change() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "x".into(),
            data_type: "integer".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "x".into(),
        data_type: "bigint".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: None,
        comment: None,
        collation: None,
    };
    let stmts = build_alter_column("postgres", None, "t", &col).unwrap();
    let joined = stmts.join("\n");
    assert!(joined.contains("TYPE bigint"));
    assert!(joined.contains("USING \"x\"::bigint"));
}

#[test]
fn alter_column_postgres_nullable_change() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "x".into(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "x".into(),
        data_type: "text".into(),
        nullable: false,
        primary_key: false,
        auto_increment: false,
        default_value: None,
        comment: None,
        collation: None,
    };
    let stmts = build_alter_column("postgres", None, "t", &col).unwrap();
    assert!(stmts.iter().any(|s| s.contains("SET NOT NULL")));
}

#[test]
fn alter_column_postgres_default_change() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "x".into(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "x".into(),
        data_type: "text".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: Some("'pending'".into()),
        comment: None,
        collation: None,
    };
    let stmts = build_alter_column("postgres", None, "t", &col).unwrap();
    assert!(stmts.iter().any(|s| s.contains("SET DEFAULT 'pending'")));
}

#[test]
fn alter_column_mysql_modify_full_def() {
    let col = nn(def(dc("status", "VARCHAR(64)"), "'open'"));
    let stmts = build_alter_column("mysql", None, "t", &col).unwrap();
    assert_eq!(stmts.len(), 1);
    assert_eq!(
        stmts[0],
        "ALTER TABLE `t` MODIFY COLUMN `status` VARCHAR(64) NOT NULL DEFAULT 'open'"
    );
}

#[test]
fn alter_column_postgres_emits_three_statements_when_all_change() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "x".into(),
            data_type: "integer".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "x".into(),
        data_type: "bigint".into(),
        nullable: false,
        primary_key: false,
        auto_increment: false,
        default_value: Some("'fallback'".into()),
        comment: None,
        collation: None,
    };
    let stmts = build_alter_column("postgres", None, "t", &col).unwrap();
    // Type, nullable AND default all changed — all three must
    // emit. Previously the early-return cascade lost the latter
    // two.
    assert_eq!(stmts.len(), 3);
    assert!(stmts[0].contains("TYPE bigint"));
    assert!(stmts[1].contains("SET NOT NULL"));
    assert!(stmts[2].contains("SET DEFAULT 'fallback'"));
}

#[test]
fn alter_column_sqlite_rejected() {
    let col = dc("x", "TEXT");
    let err = build_alter_column("sqlite", None, "t", &col).unwrap_err();
    assert!(matches!(err, BuildDdlError::SqliteNotSupported(_)));
}

#[test]
fn alter_column_mssql_type_and_nullable_change() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "x".into(),
            data_type: "int".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "x".into(),
        data_type: "int".into(),
        nullable: false,
        primary_key: false,
        auto_increment: false,
        default_value: None,
        comment: None,
        collation: None,
    };
    let stmts = build_alter_column("mssql", None, "t", &col).unwrap();
    assert_eq!(stmts.len(), 1);
    assert_eq!(stmts[0], "ALTER TABLE [t] ALTER COLUMN [x] int NOT NULL");
}

#[test]
fn alter_column_mssql_default_only_replaces_the_constraint() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "x".into(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "x".into(),
        data_type: "text".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: Some("'pending'".into()),
        comment: None,
        collation: None,
    };
    let stmts = build_alter_column("mssql", None, "t", &col).unwrap();
    assert_eq!(stmts.len(), 2);
    assert!(!stmts[0].contains("ALTER COLUMN"));
    assert!(stmts[0].contains("sys.default_constraints"));
    assert!(stmts[0].contains("OBJECT_ID('[t]')"));
    assert!(stmts[0].contains("c.name = 'x'"));
    assert_eq!(stmts[1], "ALTER TABLE [t] ADD DEFAULT ('pending') FOR [x]");
}

#[test]
fn alter_column_mssql_clearing_a_default_only_drops() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "x".into(),
            data_type: "text".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: Some("'pending'".into()),
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "x".into(),
        data_type: "text".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: None,
        comment: None,
        collation: None,
    };
    let stmts = build_alter_column("mssql", None, "t", &col).unwrap();
    assert_eq!(stmts.len(), 1);
    assert!(stmts[0].contains("DROP CONSTRAINT"));
    assert!(!stmts[0].contains("ADD DEFAULT"));
}

#[test]
fn alter_column_mssql_applies_default_alongside_type_change() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "x".into(),
            data_type: "int".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "x".into(),
        data_type: "bigint".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: Some("0".into()),
        comment: None,
        collation: None,
    };
    let stmts = build_alter_column("mssql", None, "t", &col).unwrap();
    assert_eq!(stmts.len(), 3);
    assert_eq!(stmts[0], "ALTER TABLE [t] ALTER COLUMN [x] bigint NULL");
    assert!(stmts[1].contains("DROP CONSTRAINT"));
    assert_eq!(stmts[2], "ALTER TABLE [t] ADD DEFAULT (0) FOR [x]");
}

#[test]
fn alter_column_mssql_unchanged_is_no_change() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "x".into(),
            data_type: "int".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "x".into(),
        data_type: "int".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: None,
        comment: None,
        collation: None,
    };
    let err = build_alter_column("mssql", None, "t", &col).unwrap_err();
    assert!(matches!(err, BuildDdlError::NoChange));
}

#[test]
fn alter_column_mssql_drop_default_escapes_literals() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "o'brien".into(),
            data_type: "int".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: Some("0".into()),
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "o'brien".into(),
        data_type: "int".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: None,
        comment: None,
        collation: None,
    };
    let stmts = build_alter_column("mssql", Some("s'x"), "t'q", &col).unwrap();
    assert!(stmts[0].contains("OBJECT_ID('[s''x].[t''q]')"));
    assert!(stmts[0].contains("c.name = 'o''brien'"));
}

#[test]
fn reorder_column_mysql() {
    let col = nn(dc("status", "VARCHAR(64)"));
    let sql = build_reorder_column("mysql", None, "t", &col, Some("name")).unwrap();
    assert_eq!(
        sql,
        "ALTER TABLE `t` MODIFY COLUMN `status` VARCHAR(64) NOT NULL AFTER `name`"
    );
}

#[test]
fn reorder_column_mysql_first() {
    let col = nn(dc("id", "INT"));
    let sql = build_reorder_column("mysql", None, "t", &col, None).unwrap();
    assert!(sql.ends_with("FIRST"));
}

#[test]
fn reorder_column_postgres_rejected() {
    let col = dc("x", "text");
    let err = build_reorder_column("postgres", None, "t", &col, Some("y")).unwrap_err();
    assert!(matches!(err, BuildDdlError::UnsupportedDriver(_)));
}

#[test]
fn reorder_column_sqlite_rejected() {
    let col = dc("x", "TEXT");
    let err = build_reorder_column("sqlite", None, "t", &col, None).unwrap_err();
    assert!(matches!(err, BuildDdlError::UnsupportedDriver(_)));
}

#[test]
fn create_index_basic() {
    let idx = IndexInfo {
        name: "users_email_idx".into(),
        columns: vec!["email".into()],
        unique: true,
        primary: false,
        predicate: None,
    };
    assert_eq!(
        build_create_index("postgres", None, "users", &idx).unwrap(),
        "CREATE UNIQUE INDEX \"users_email_idx\" ON \"users\" (\"email\")"
    );
}

#[test]
fn create_index_refuses_a_partial_index_instead_of_dropping_its_predicate() {
    let idx = IndexInfo {
        name: "active_email".into(),
        columns: vec!["email".into()],
        unique: true,
        primary: false,
        predicate: Some("deleted_at IS NULL".into()),
    };
    let err = build_create_index("postgres", None, "users", &idx).unwrap_err();
    assert!(matches!(err, BuildDdlError::PartialIndex));
}

#[test]
fn create_index_compound_columns() {
    let idx = IndexInfo {
        name: "idx_a_b".into(),
        columns: vec!["a".into(), "b".into()],
        unique: false,
        primary: false,
        predicate: None,
    };
    let sql = build_create_index("mysql", None, "t", &idx).unwrap();
    assert_eq!(sql, "CREATE INDEX `idx_a_b` ON `t` (`a`, `b`)");
}

#[test]
fn create_index_rejects_empty_name() {
    let idx = IndexInfo {
        name: "".into(),
        columns: vec!["x".into()],
        unique: false,
        primary: false,
        predicate: None,
    };
    let err = build_create_index("postgres", None, "t", &idx).unwrap_err();
    assert!(matches!(err, BuildDdlError::EmptyIndexName));
}

#[test]
fn create_index_mssql() {
    let idx = IndexInfo {
        name: "idx_a_b".into(),
        columns: vec!["a".into(), "b".into()],
        unique: true,
        primary: false,
        predicate: None,
    };
    let sql = build_create_index("mssql", None, "t", &idx).unwrap();
    assert_eq!(sql, "CREATE UNIQUE INDEX [idx_a_b] ON [t] ([a], [b])");
}

#[test]
fn drop_index_postgres() {
    assert_eq!(
        build_drop_index("postgres", Some("public"), "t", "my_idx").unwrap(),
        "DROP INDEX IF EXISTS \"public\".\"my_idx\""
    );
}

#[test]
fn drop_index_mysql_uses_alter_table() {
    assert_eq!(
        build_drop_index("mysql", None, "t", "my_idx").unwrap(),
        "ALTER TABLE `t` DROP INDEX `my_idx`"
    );
}

#[test]
fn drop_index_sqlite() {
    assert_eq!(
        build_drop_index("sqlite", None, "t", "my_idx").unwrap(),
        "DROP INDEX IF EXISTS \"my_idx\""
    );
}

#[test]
fn drop_index_mssql() {
    assert_eq!(
        build_drop_index("mssql", Some("schema"), "t", "ix").unwrap(),
        "DROP INDEX IF EXISTS [ix] ON [schema].[t]"
    );
}

fn fk_basic() -> ForeignKeyInfo {
    ForeignKeyInfo {
        name: "fk_user".into(),
        columns: vec!["user_id".into()],
        ref_schema: None,
        ref_table: "users".into(),
        ref_columns: vec!["id".into()],
        on_delete: Some("CASCADE".into()),
        on_update: Some("RESTRICT".into()),
    }
}

#[test]
fn add_foreign_key_postgres() {
    let sql = build_add_foreign_key("postgres", None, "orders", &fk_basic()).unwrap();
    assert!(sql.contains("ADD CONSTRAINT \"fk_user\""));
    assert!(sql.contains("FOREIGN KEY (\"user_id\")"));
    assert!(sql.contains("REFERENCES \"users\" (\"id\")"));
    assert!(sql.contains("ON DELETE CASCADE"));
    assert!(sql.contains("ON UPDATE RESTRICT"));
}

#[test]
fn add_foreign_key_mysql_backticks() {
    let sql = build_add_foreign_key("mysql", None, "orders", &fk_basic()).unwrap();
    assert!(sql.contains("`fk_user`"));
    assert!(sql.contains("`user_id`"));
}

#[test]
fn add_foreign_key_omits_actions_when_none() {
    let mut fk = fk_basic();
    fk.on_delete = None;
    fk.on_update = None;
    let sql = build_add_foreign_key("postgres", None, "orders", &fk).unwrap();
    assert!(!sql.contains("ON DELETE"));
    assert!(!sql.contains("ON UPDATE"));
}

#[test]
fn add_foreign_key_mssql() {
    let mut fk = fk_basic();
    fk.on_update = Some("NO ACTION".into());
    let sql = build_add_foreign_key("mssql", None, "orders", &fk).unwrap();
    assert!(sql.contains("ADD CONSTRAINT [fk_user]"));
    assert!(sql.contains("FOREIGN KEY ([user_id])"));
    assert!(sql.contains("REFERENCES [users] ([id])"));
    assert!(sql.contains("ON DELETE CASCADE"));
    assert!(sql.contains("ON UPDATE NO ACTION"));
}

#[test]
fn add_foreign_key_mssql_rejects_restrict() {
    // T-SQL has no RESTRICT. Emitting it produces a syntax error at
    // Save time, so the builder refuses it up front and the dialog
    // never offers it.
    let err = build_add_foreign_key("mssql", None, "orders", &fk_basic()).unwrap_err();
    assert!(matches!(err, BuildDdlError::InvalidFkAction(a) if a == "RESTRICT"));
    assert!(!supported_fk_actions("mssql").contains(&"RESTRICT"));
    assert!(supported_fk_actions("postgres").contains(&"RESTRICT"));
}

#[test]
fn drop_foreign_key_postgres() {
    assert_eq!(
        build_drop_foreign_key("postgres", None, "orders", "fk_user").unwrap(),
        "ALTER TABLE \"orders\" DROP CONSTRAINT \"fk_user\""
    );
}

#[test]
fn drop_foreign_key_mysql() {
    assert_eq!(
        build_drop_foreign_key("mysql", None, "orders", "fk_user").unwrap(),
        "ALTER TABLE `orders` DROP FOREIGN KEY `fk_user`"
    );
}

#[test]
fn drop_foreign_key_sqlite_rejected() {
    let err = build_drop_foreign_key("sqlite", None, "orders", "fk_user").unwrap_err();
    assert!(matches!(err, BuildDdlError::SqliteNotSupported(_)));
}

#[test]
fn drop_foreign_key_mssql() {
    assert_eq!(
        build_drop_foreign_key("mssql", None, "orders", "fk_user").unwrap(),
        "ALTER TABLE [orders] DROP CONSTRAINT [fk_user]"
    );
}

#[test]
fn rejects_injection_via_data_type() {
    let mut col = dc("x", "INT; DROP TABLE users; --");
    col.nullable = false;
    let err = build_add_column("postgres", None, "t", &col).unwrap_err();
    assert!(matches!(err, BuildDdlError::UnsafeType(_)), "got {err:?}");
}

#[test]
fn rejects_injection_via_default() {
    let col = def(dc("x", "TEXT"), "'a'); DROP TABLE t; --");
    let err = build_add_column("postgres", None, "t", &col).unwrap_err();
    assert!(matches!(err, BuildDdlError::UnsafeDefault(_)), "got {err:?}");
}

#[test]
fn rejects_unknown_fk_action() {
    let mut fk = fk_basic();
    fk.on_delete = Some("DROP TABLE u; --".into());
    let err = build_add_foreign_key("postgres", None, "t", &fk).unwrap_err();
    assert!(matches!(err, BuildDdlError::InvalidFkAction(_)), "got {err:?}");
}

#[test]
fn fk_action_canonicalised_case_insensitive() {
    let mut fk = fk_basic();
    fk.on_delete = Some("cascade".into());
    fk.on_update = Some("Set Null".into());
    let sql = build_add_foreign_key("postgres", None, "t", &fk).unwrap();
    assert!(sql.contains("ON DELETE CASCADE"));
    assert!(sql.contains("ON UPDATE SET NULL"));
}

#[test]
fn rejects_unicode_line_separator_in_type() {
    let mut col = dc("x", "INT\u{2028}; DROP TABLE u; --");
    col.nullable = false;
    let err = build_add_column("postgres", None, "t", &col).unwrap_err();
    assert!(matches!(err, BuildDdlError::UnsafeType(_)), "got {err:?}");
}

#[test]
fn rejects_unicode_paragraph_separator_in_default() {
    let col = def(dc("x", "TEXT"), "'a\u{2029}; DROP TABLE u; --");
    let err = build_add_column("postgres", None, "t", &col).unwrap_err();
    assert!(matches!(err, BuildDdlError::UnsafeDefault(_)), "got {err:?}");
}

#[test]
fn allows_legitimate_complex_types() {
    // Postgres time-with-tz, ENUM with quoted labels, parameterised
    // DECIMAL, array suffix — must all pass.
    for ty in [
        "TIMESTAMP WITH TIME ZONE",
        "DOUBLE PRECISION",
        "DECIMAL(10, 2)",
        "INTEGER[]",
        "ENUM('open','closed')",
        "Nullable(Int64)",
        "VARCHAR(255)",
    ] {
        assert!(validate_safe_type(ty).is_ok(), "rejected legitimate type: {ty}");
    }
}

#[test]
fn allows_legitimate_default_expressions() {
    for d in ["'foo'", "42", "now()", "CURRENT_TIMESTAMP", "'O''Brien'", "(1+2)"] {
        assert!(validate_safe_default(d).is_ok(), "rejected legitimate default: {d}");
    }
}

#[test]
fn alter_column_postgres_rejects_injection_in_type() {
    let col = DraftColumn {
        original: Some(ColumnInfo {
            name: "x".into(),
            data_type: "integer".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }),
        name: "x".into(),
        data_type: "bigint; DROP TABLE u; --".into(),
        nullable: true,
        primary_key: false,
        auto_increment: false,
        default_value: None,
        comment: None,
        collation: None,
    };
    let err = build_alter_column("postgres", None, "t", &col).unwrap_err();
    assert!(matches!(err, BuildDdlError::UnsafeType(_)), "got {err:?}");
}

#[test]
fn quoted_identifiers_round_trip_through_qualified_table() {
    // Schema + table with embedded quote chars: identifier quoting
    // must double the inner quote.
    let sql = build_drop_table("postgres", Some("a\"b"), "c\"d", false, false).unwrap();
    assert!(sql.contains("\"a\"\"b\".\"c\"\"d\""));
}

#[test]
fn materialize_ops_mssql_orders_rename_alter_then_add() {
    let ops = vec![
        StructureOp::RenameTable {
            schema: None,
            old_name: "old_t".into(),
            new_name: "new_t".into(),
        },
        StructureOp::AlterColumn {
            schema: None,
            table: "new_t".into(),
            column: DraftColumn {
                original: Some(ColumnInfo {
                    name: "x".into(),
                    data_type: "text".into(),
                    nullable: true,
                    primary_key: false,
                    is_auto_increment: false,
                    default_value: None,
                    is_generated: false,
                    comment: None,
                    collation: None,
                    enum_type: None,
                    domain_type: None,
                }),
                name: "x".into(),
                data_type: "text".into(),
                nullable: true,
                primary_key: false,
                auto_increment: false,
                default_value: Some("'x'".into()),
                comment: None,
                collation: None,
            },
        },
        StructureOp::AddColumn {
            schema: None,
            table: "new_t".into(),
            column: nn(dc("flag", "BIT")),
        },
    ];
    let stmts = materialize_ops(&ops, "mssql").unwrap();
    assert_eq!(stmts.len(), 4);
    assert_eq!(stmts[0], "EXEC sp_rename '[old_t]', 'new_t'");
    assert!(stmts[1].contains("DROP CONSTRAINT"));
    assert_eq!(stmts[2], "ALTER TABLE [new_t] ADD DEFAULT ('x') FOR [x]");
    assert_eq!(stmts[3], "ALTER TABLE [new_t] ADD [flag] BIT NOT NULL");
}

fn existing(name: &str, data_type: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: data_type.into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

#[test]
fn a_renamed_column_emits_the_rename_before_its_alters() {
    let original = vec![existing("label", "text")];
    let mut draft = DraftColumn::from_info(original[0].clone());
    draft.name = "title".into();
    draft.nullable = false;

    let ops = diff_to_ops(None, "t", "t", &original, &[draft], &[], &[], &[], &[]);
    let rename_at = ops
        .iter()
        .position(|op| matches!(op, StructureOp::RenameColumn { .. }))
        .expect("a renamed column must emit a rename op");
    let alter_at = ops
        .iter()
        .position(|op| matches!(op, StructureOp::AlterColumn { .. }))
        .expect("the attribute change must still emit an alter op");
    assert!(rename_at < alter_at, "the rename must precede the alter: {ops:?}");

    let stmts = materialize_ops(&ops, "postgres").unwrap();
    assert_eq!(stmts[0], "ALTER TABLE \"t\" RENAME COLUMN \"label\" TO \"title\"");
    assert!(
        stmts[1..].iter().all(|s| !s.contains("\"label\"")),
        "later statements must address the new name: {stmts:?}"
    );
    assert!(stmts.iter().any(|s| s.contains("SET NOT NULL")));
}

#[test]
fn a_pure_column_rename_emits_only_the_rename() {
    let original = vec![existing("label", "text")];
    let mut draft = DraftColumn::from_info(original[0].clone());
    draft.name = "title".into();

    let ops = diff_to_ops(None, "t", "t", &original, &[draft], &[], &[], &[], &[]);
    let stmts = materialize_ops(&ops, "postgres").unwrap();
    assert_eq!(
        stmts,
        vec!["ALTER TABLE \"t\" RENAME COLUMN \"label\" TO \"title\"".to_string()]
    );
}

#[test]
fn an_unrenamed_column_emits_no_rename() {
    let original = vec![existing("label", "text")];
    let mut draft = DraftColumn::from_info(original[0].clone());
    draft.nullable = false;

    let ops = diff_to_ops(None, "t", "t", &original, &[draft], &[], &[], &[], &[]);
    assert!(!ops.iter().any(|op| matches!(op, StructureOp::RenameColumn { .. })));
}

#[test]
fn a_pure_column_rename_needs_no_alter_on_any_dialect() {
    let original = vec![existing("label", "text")];
    let mut draft = DraftColumn::from_info(original[0].clone());
    draft.name = "title".into();
    let ops = diff_to_ops(None, "t", "t", &original, &[draft], &[], &[], &[], &[]);

    assert!(
        !ops.iter().any(|op| matches!(op, StructureOp::AlterColumn { .. })),
        "a name-only change has nothing for an alter to do: {ops:?}"
    );

    assert_eq!(
        materialize_ops(&ops, "sqlite").unwrap(),
        vec!["ALTER TABLE \"t\" RENAME COLUMN \"label\" TO \"title\"".to_string()],
        "SQLite supports RENAME COLUMN even though it refuses every other alter"
    );
    assert_eq!(
        materialize_ops(&ops, "mysql").unwrap(),
        vec!["ALTER TABLE `t` RENAME COLUMN `label` TO `title`".to_string()],
        "a redundant MODIFY COLUMN would restate the definition without its collation"
    );
    assert_eq!(
        materialize_ops(&ops, "mssql").unwrap(),
        vec!["EXEC sp_rename '[t].[label]', 'title', 'COLUMN'".to_string()]
    );
}
