use crate::query::ColumnInfo;

use super::{BuildDdlError, DraftColumn, build_add_column, build_alter_column};

fn collated(data_type: &str, collation: Option<&str>) -> DraftColumn {
    DraftColumn::from_info(ColumnInfo {
        name: "label".into(),
        data_type: data_type.into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: collation.map(str::to_string),
        enum_type: None,
        domain_type: None,
    })
}

#[test]
fn a_postgres_type_change_keeps_the_column_collation() {
    let mut column = collated("character varying(40)", Some("C"));
    column.data_type = "character varying(80)".into();

    let statements = build_alter_column("postgres", None, "people", &column).unwrap();

    assert_eq!(
        statements,
        vec![
            "ALTER TABLE \"people\" ALTER COLUMN \"label\" TYPE character varying(80) COLLATE \"C\" USING \"label\"::character varying(80)"
                .to_string()
        ]
    );
}

#[test]
fn a_type_change_to_a_type_without_collation_drops_the_clause() {
    let mut column = collated("text", Some("C"));
    column.data_type = "integer".into();

    let statements = build_alter_column("postgres", None, "people", &column).unwrap();

    assert!(!statements[0].contains("COLLATE"), "{statements:?}");
}

#[test]
fn a_mysql_modify_restates_the_collation_even_when_only_nullability_changed() {
    let mut column = collated("varchar(40)", Some("utf8mb4_bin"));
    column.nullable = false;

    let statements = build_alter_column("mysql", None, "people", &column).unwrap();

    assert_eq!(
        statements,
        vec!["ALTER TABLE `people` MODIFY COLUMN `label` varchar(40) COLLATE `utf8mb4_bin` NOT NULL".to_string()]
    );
}

#[test]
fn a_mssql_nullability_change_keeps_the_column_collation() {
    let mut column = collated("nvarchar(40)", Some("Latin1_General_100_BIN2"));
    column.nullable = false;

    let statements = build_alter_column("mssql", None, "people", &column).unwrap();

    assert_eq!(
        statements,
        vec![
            "ALTER TABLE [people] ALTER COLUMN [label] nvarchar(40) COLLATE Latin1_General_100_BIN2 NOT NULL"
                .to_string()
        ]
    );
    column.collation = Some("bad;DROP TABLE people".into());
    assert!(matches!(
        build_alter_column("mssql", None, "people", &column),
        Err(BuildDdlError::UnsafeCollation(_))
    ));
}

#[test]
fn a_collation_name_from_the_catalog_is_quoted_or_refused() {
    let mut quoted = collated("text", Some("odd\"name"));
    quoted.nullable = false;
    let statements = build_add_column("postgres", None, "people", &quoted).unwrap();
    assert!(statements[0].contains("COLLATE \"odd\"\"name\""), "{statements:?}");

    let mut hostile = collated("varchar(10)", Some("x\u{0}y"));
    hostile.nullable = false;
    let error = build_alter_column("mysql", None, "people", &hostile).unwrap_err();
    assert!(matches!(error, BuildDdlError::UnsafeCollation(_)), "{error:?}");
}

#[test]
fn engines_without_collation_support_here_ignore_it() {
    for driver in ["sqlite", "clickhouse"] {
        let column = collated("text", Some("C"));
        let statements = build_add_column(driver, None, "people", &column).unwrap();
        assert!(!statements[0].contains("COLLATE"), "{driver}: {statements:?}");
    }
}
