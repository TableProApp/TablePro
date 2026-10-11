use super::*;

#[test]
fn postgres_wide_numeric_inserts_cast_text_to_the_builtin_numeric_type() {
    let mut columns = [col("amount", false)];
    columns[0].data_type = "numeric(65, 0)".into();
    let wide = "1234567890123456789012345678901234567890";
    let (sql, params) =
        build_insert_from_draft("postgres", None, "ledger", &columns, &[Value::Text(wide.into())]).unwrap();

    assert_eq!(
        sql,
        r#"INSERT INTO "ledger" ("amount") VALUES ($1::text::pg_catalog.numeric)"#
    );
    assert_eq!(params, vec![Value::Text(wide.into())]);
}

#[test]
fn postgres_wide_numeric_updates_cast_text_to_the_builtin_numeric_type() {
    let mut columns = [col("id", true), col("amount", false)];
    columns[1].data_type = "numeric(80, 40)".into();
    let (sql, params) = build_keyed_update(
        "postgres",
        None,
        "ledger",
        &columns,
        &[(1, Value::Text("1234567890123456789012345678901234567890.1".into()))],
        &[Value::Int(7)],
    )
    .unwrap();

    assert_eq!(
        sql,
        r#"UPDATE "ledger" SET "amount" = $1::text::pg_catalog.numeric WHERE "id" = $2"#
    );
    assert_eq!(
        params,
        vec![
            Value::Text("1234567890123456789012345678901234567890.1".into()),
            Value::Int(7)
        ]
    );
}

#[test]
fn postgres_domain_text_updates_cast_to_the_qualified_type() {
    let mut columns = [col("id", true), col("items", false)];
    columns[1].domain_type = Some(tablepro_core::QualifiedTypeName {
        schema: "domain_over_array".into(),
        name: "small_ints".into(),
    });
    let (sql, params) = build_keyed_update(
        "postgres",
        Some("domain_over_array"),
        "rows",
        &columns,
        &[(1, Value::Text("[0:2]={2,4,NULL}".into()))],
        &[Value::Int(1)],
    )
    .unwrap();

    assert_eq!(
        sql,
        r#"UPDATE "domain_over_array"."rows" SET "items" = $1::text::"domain_over_array"."small_ints" WHERE "id" = $2"#
    );
    assert_eq!(params, vec![Value::Text("[0:2]={2,4,NULL}".into()), Value::Int(1)]);

    let (sql, params) = build_optimistic_keyed_update(
        "postgres",
        Some("domain_over_array"),
        "rows",
        &columns,
        &[(
            1,
            Value::Text("[0:2]={1,4,NULL}".into()),
            Value::Text("[0:2]={2,4,NULL}".into()),
        )],
        &[Value::Int(1)],
    )
    .unwrap();
    assert_eq!(
        sql,
        r#"UPDATE "domain_over_array"."rows" SET "items" = $1::text::"domain_over_array"."small_ints" WHERE "id" = $2 AND "items" IS NOT DISTINCT FROM $3::text::"domain_over_array"."small_ints""#
    );
    assert_eq!(
        params,
        vec![
            Value::Text("[0:2]={2,4,NULL}".into()),
            Value::Int(1),
            Value::Text("[0:2]={1,4,NULL}".into()),
        ]
    );
}
