use crate::query::{ColumnInfo, QualifiedTypeName, Value};
use crate::sql_dialect::{build_insert_from_draft, build_keyed_update, build_optimistic_keyed_update};

#[test]
fn postgres_enum_write_casts_quote_catalog_schema_and_type_names() {
    let columns = [
        ColumnInfo {
            name: "id".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        ColumnInfo {
            name: "status".into(),
            data_type: "status_type".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: Some(QualifiedTypeName {
                schema: "odd schema".into(),
                name: "status\"type".into(),
            }),
            domain_type: None,
        },
    ];

    let (sql, _) = build_keyed_update(
        "postgres",
        None,
        "t",
        &columns,
        &[(1, Value::Text("ready".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(
        sql,
        r#"UPDATE "t" SET "status" = $1::text::"odd schema"."status""type" WHERE "id" = $2"#
    );

    let (sql, params) = build_optimistic_keyed_update(
        "postgres",
        None,
        "t",
        &columns,
        &[(1, Value::Text("old".into()), Value::Text("ready".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(
        sql,
        r#"UPDATE "t" SET "status" = $1::text::"odd schema"."status""type" WHERE "id" = $2 AND "status" IS NOT DISTINCT FROM $3::text::"odd schema"."status""type""#
    );
    assert_eq!(
        params,
        vec![Value::Text("ready".into()), Value::Int(1), Value::Text("old".into())]
    );

    let (sql, _) = build_insert_from_draft("postgres", None, "t", &columns[1..], &[Value::Null]).unwrap();
    assert_eq!(
        sql,
        r#"INSERT INTO "t" ("status") VALUES ($1::text::"odd schema"."status""type")"#
    );
}

#[test]
fn postgres_enum_array_writes_cast_text_to_the_qualified_array_type() {
    let column = ColumnInfo {
        name: "labels".into(),
        data_type: "enum_schema.status_type[]".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: Some(QualifiedTypeName {
            schema: "odd schema".into(),
            name: "status\"type".into(),
        }),
        domain_type: None,
    };
    let (sql, params) = build_insert_from_draft(
        "postgres",
        None,
        "t",
        std::slice::from_ref(&column),
        &[Value::Text("{ready,NULL}".into())],
    )
    .unwrap();
    assert_eq!(
        sql,
        r#"INSERT INTO "t" ("labels") VALUES ($1::text::"odd schema"."status""type"[])"#
    );
    assert_eq!(params, vec![Value::Text("{ready,NULL}".into())]);

    let columns = [
        ColumnInfo {
            name: "id".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        column,
    ];
    let (sql, params) = build_optimistic_keyed_update(
        "postgres",
        None,
        "t",
        &columns,
        &[(1, Value::Text("{old}".into()), Value::Text("{ready,NULL}".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(
        sql,
        r#"UPDATE "t" SET "labels" = $1::text::"odd schema"."status""type"[] WHERE "id" = $2 AND "labels" IS NOT DISTINCT FROM $3::text::"odd schema"."status""type"[]"#
    );
    assert_eq!(
        params,
        vec![
            Value::Text("{ready,NULL}".into()),
            Value::Int(1),
            Value::Text("{old}".into()),
        ]
    );
}
