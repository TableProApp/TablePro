#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::{FilterOp, FilterRule, FilterSet, FilterValue, Value};

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_enum_identifiers_at_catalog_byte_limit_preserve_typed_edits() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let schema = "s".repeat(63);
    let type_name = format!("{}é", "t".repeat(61));
    assert_eq!(schema.len(), 63);
    assert_eq!(type_name.len(), 63);
    let quoted_schema = format!("\"{schema}\"");
    let quoted_type = format!("\"{type_name}\"");

    connection
        .execute(&format!("CREATE SCHEMA {quoted_schema}"))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {quoted_schema}.{quoted_type} AS ENUM ('ready', 'updated')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE {quoted_schema}.rows \
             (id INT PRIMARY KEY, state {quoted_schema}.{quoted_type}, sibling TEXT NOT NULL)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!("INSERT INTO {quoted_schema}.rows VALUES (1, 'ready', 'keep')"))
        .await
        .unwrap();

    let columns = connection.fetch_columns(Some(&schema), "rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.clone(),
            name: type_name.clone(),
        })
    );
    let (sql, params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(&schema),
        "rows",
        &columns,
        &[(1, Value::Text("updated".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&sql, &params).await.unwrap();

    let stored = connection
        .query(&format!(
            "SELECT state::text, n.nspname, t.typname, sibling \
             FROM {quoted_schema}.rows \
             JOIN pg_type t ON t.oid = pg_typeof(state)::oid \
             JOIN pg_namespace n ON n.oid = t.typnamespace"
        ))
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![vec![
            Value::Text("updated".into()),
            Value::Text(schema),
            Value::Text(type_name),
            Value::Text("keep".into()),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_quoted_enum_identifiers_preserve_metadata_and_typed_writes() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let schema = "enum audit \"schema\"";
    let type_name = "state \"kind\"";
    let quoted_schema = "\"enum audit \"\"schema\"\"\"";
    let quoted_type = "\"state \"\"kind\"\"\"";
    connection
        .execute(&format!("CREATE SCHEMA {quoted_schema}"))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {quoted_schema}.{quoted_type} AS ENUM ('NULL', '', 'ready', '東京')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE {quoted_schema}.rows (id INT PRIMARY KEY, state {quoted_schema}.{quoted_type}, sibling TEXT NOT NULL)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {quoted_schema}.rows VALUES (1, 'ready', 'keyed'), (2, 'NULL', 'literal-null'), (3, NULL, 'sql-null')"
        ))
        .await
        .unwrap();

    let columns = connection.fetch_columns(Some(schema), "rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: type_name.into(),
        })
    );

    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, Value::Text(String::new()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(
        update_sql.contains(&format!("{quoted_schema}.{quoted_type}")),
        "{update_sql}"
    );
    connection.execute_params(&update_sql, &update_params).await.unwrap();

    let (insert_sql, insert_params) = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[Value::Int(4), Value::Text("東京".into()), Value::Text("draft".into())],
    )
    .unwrap();
    assert!(
        insert_sql.contains(&format!("{quoted_schema}.{quoted_type}")),
        "{insert_sql}"
    );
    connection.execute_params(&insert_sql, &insert_params).await.unwrap();

    let (where_sql, filter_params) = tablepro_core::build_filter_where(
        "postgres",
        &columns,
        &FilterSet {
            rules: vec![FilterRule {
                column: "state".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single("NULL".into())),
            }],
            ..Default::default()
        },
    )
    .unwrap()
    .unwrap();
    assert!(
        where_sql.contains(&format!("{quoted_schema}.{quoted_type}")),
        "{where_sql}"
    );
    let filtered = connection
        .query_params(
            &format!("SELECT id, state::text FROM {quoted_schema}.rows WHERE {where_sql}"),
            &filter_params,
        )
        .await
        .unwrap();
    assert_eq!(filtered.rows, vec![vec![Value::Int(2), Value::Text("NULL".into())]]);

    let stored = connection
        .query(&format!(
            "SELECT r.id, r.state::text, n.nspname, t.typname, r.sibling \
             FROM {quoted_schema}.rows r \
             JOIN pg_type t ON t.oid = pg_typeof(r.state)::oid \
             JOIN pg_namespace n ON n.oid = t.typnamespace ORDER BY r.id"
        ))
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text(String::new()),
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("keyed".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("NULL".into()),
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("literal-null".into()),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("sql-null".into()),
            ],
            vec![
                Value::Int(4),
                Value::Text("東京".into()),
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("draft".into()),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_quoted_enum_identifiers_resist_shadowed_search_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let schema = "enum audit \"schema\"";
    let type_name = "state \"kind\"";
    let quoted_schema = "\"enum audit \"\"schema\"\"\"";
    let quoted_type = "\"state \"\"kind\"\"\"";
    connection
        .execute(&format!("CREATE SCHEMA {quoted_schema}"))
        .await
        .unwrap();
    connection.execute("CREATE SCHEMA enum_quoted_shadow").await.unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {quoted_schema}.{quoted_type} AS ENUM ('ready', 'target-only', 'NULL')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE enum_quoted_shadow.{quoted_type} AS ENUM ('ready', 'shadow-only')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE {quoted_schema}.rows \
             (id INT PRIMARY KEY, state {quoted_schema}.{quoted_type}, sibling TEXT NOT NULL)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE enum_quoted_shadow.rows \
             (id INT PRIMARY KEY, state enum_quoted_shadow.{quoted_type}, sibling TEXT NOT NULL)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {quoted_schema}.rows VALUES \
             (1, 'ready', 'target-one'), (2, 'NULL', 'target-two'), (3, NULL, 'target-null')"
        ))
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO enum_quoted_shadow.rows VALUES \
             (1, 'ready', 'shadow-one'), (2, 'shadow-only', 'shadow-two')",
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(Some(schema), "rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: type_name.into(),
        })
    );

    let quoted_import_table = "\"import rows\"";
    connection
        .execute(&format!(
            "CREATE TABLE {quoted_schema}.{quoted_import_table} \
             (id INT PRIMARY KEY, state {quoted_schema}.{quoted_type}, sibling TEXT NOT NULL)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE enum_quoted_shadow.{quoted_import_table} \
             (id INT PRIMARY KEY, state enum_quoted_shadow.{quoted_type}, sibling TEXT NOT NULL)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO enum_quoted_shadow.{quoted_import_table} VALUES (99, 'ready', 'shadow-seed')"
        ))
        .await
        .unwrap();
    let import_columns = connection.fetch_columns(Some(schema), "import rows").await.unwrap();
    assert_eq!(
        import_columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: type_name.into(),
        })
    );

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO enum_quoted_shadow, public")
        .await
        .unwrap();
    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, Value::Text("target-only".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(
        update_sql.contains(&format!("{quoted_schema}.{quoted_type}")),
        "{update_sql}"
    );
    transaction.execute_params(&update_sql, &update_params).await.unwrap();

    let (where_sql, filter_params) = tablepro_core::build_filter_where(
        "postgres",
        &columns,
        &FilterSet {
            rules: vec![FilterRule {
                column: "state".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single("target-only".into())),
            }],
            ..Default::default()
        },
    )
    .unwrap()
    .unwrap();
    let filtered = transaction
        .query_params(
            &format!("SELECT id, state::text FROM {quoted_schema}.rows WHERE {where_sql}"),
            &filter_params,
        )
        .await
        .unwrap();
    assert_eq!(
        filtered.rows,
        vec![vec![Value::Int(1), Value::Text("target-only".into())]]
    );

    transaction
        .execute("SAVEPOINT reject_shadow_only_enum_label")
        .await
        .unwrap();
    let (invalid_sql, invalid_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, Value::Text("shadow-only".into()))],
        &[Value::Int(2)],
    )
    .unwrap();
    let invalid = transaction
        .execute_params(&invalid_sql, &invalid_params)
        .await
        .expect_err("a label present only in the shadow enum must be refused");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected target enum invalid-label SQLSTATE 22P02, got {invalid:?}"
    );
    transaction
        .execute("ROLLBACK TO SAVEPOINT reject_shadow_only_enum_label")
        .await
        .unwrap();

    let source = transaction
        .query(&format!(
            "SELECT id, state, sibling FROM {quoted_schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    let null_marker = tablepro_core::export::unique_csv_null_marker(&source.rows);
    let csv_options = tablepro_core::export::CsvOptions {
        null_to_empty: false,
        null_marker: Some(null_marker.clone()),
        ..Default::default()
    };
    let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &csv_options);
    let import_options = tablepro_core::import::CsvImportOptions {
        null_marker,
        ..Default::default()
    };
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &import_options, None).unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some(schema),
            table: "import rows",
            columns: &import_columns,
            mapping: &[Some(0), Some(1), Some(2)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert!(
        plan.statement
            .contains(&format!("$2::text::{quoted_schema}.{quoted_type}")),
        "CSV import must cast to the quoted destination enum despite search_path: {}",
        plan.statement
    );
    for row in &plan.rows {
        transaction.execute_params(&plan.statement, row).await.unwrap();
    }

    let target = transaction
        .query(&format!(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM {quoted_schema}.rows ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(
        target.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("target-only".into()),
                Value::Text(format!("{quoted_schema}.{quoted_type}")),
                Value::Text("target-one".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("NULL".into()),
                Value::Text(format!("{quoted_schema}.{quoted_type}")),
                Value::Text("target-two".into()),
            ],
            vec![
                Value::Int(3),
                Value::Null,
                Value::Text(format!("{quoted_schema}.{quoted_type}")),
                Value::Text("target-null".into()),
            ],
        ]
    );
    let imported = transaction
        .query(&format!(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM {quoted_schema}.{quoted_import_table} ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(imported.rows, target.rows);
    let shadow_rows = transaction
        .query("SELECT id, state::text, pg_typeof(state)::text, sibling FROM enum_quoted_shadow.rows ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        shadow_rows.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("ready".into()),
                Value::Text(quoted_type.into()),
                Value::Text("shadow-one".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("shadow-only".into()),
                Value::Text(quoted_type.into()),
                Value::Text("shadow-two".into()),
            ],
        ]
    );
    let shadow = transaction
        .query(&format!(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM enum_quoted_shadow.{quoted_import_table} ORDER BY id"
        ))
        .await
        .unwrap();
    assert_eq!(
        shadow.rows,
        vec![vec![
            Value::Int(99),
            Value::Text("ready".into()),
            Value::Text(quoted_type.into()),
            Value::Text("shadow-seed".into()),
        ]]
    );
    transaction.rollback().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mixed_case_enum_identifiers_resist_folded_shadow_names_and_hidden_role_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let schema = "EnumCaseTarget";
    let type_name = "StateKind";
    connection.execute("CREATE SCHEMA \"EnumCaseTarget\"").await.unwrap();
    connection.execute("CREATE SCHEMA enumcasetarget").await.unwrap();
    connection
        .execute("CREATE TYPE \"EnumCaseTarget\".\"StateKind\" AS ENUM ('ready', 'target-only')")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE enumcasetarget.statekind AS ENUM ('ready', 'shadow-only')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE \"EnumCaseTarget\".\"Rows\" \
             (id INT PRIMARY KEY, state \"EnumCaseTarget\".\"StateKind\", sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE enumcasetarget.rows \
             (id INT PRIMARY KEY, state enumcasetarget.statekind, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO \"EnumCaseTarget\".\"Rows\" VALUES \
             (1, 'ready', 'target-one'), (2, 'ready', 'target-two')",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO enumcasetarget.rows VALUES (1, 'ready', 'shadow-one')")
        .await
        .unwrap();
    connection
        .execute("SET search_path TO enumcasetarget, \"EnumCaseTarget\", public")
        .await
        .unwrap();

    let columns = connection.fetch_columns(Some(schema), "Rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: type_name.into(),
        })
    );

    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "Rows",
        &columns,
        &[(1, Value::Text("target-only".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(update_sql.contains("\"EnumCaseTarget\".\"StateKind\""), "{update_sql}");
    connection.execute_params(&update_sql, &update_params).await.unwrap();

    let (where_sql, filter_params) = tablepro_core::build_filter_where(
        "postgres",
        &columns,
        &FilterSet {
            rules: vec![FilterRule {
                column: "state".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single("target-only".into())),
            }],
            ..Default::default()
        },
    )
    .unwrap()
    .unwrap();
    let filtered = connection
        .query_params(
            &format!("SELECT id, state::text FROM \"EnumCaseTarget\".\"Rows\" WHERE {where_sql}"),
            &filter_params,
        )
        .await
        .unwrap();
    assert_eq!(
        filtered.rows,
        vec![vec![Value::Int(1), Value::Text("target-only".into())]]
    );

    let native = connection
        .query(
            "SELECT n.nspname, t.typname, r.state::text, r.sibling \
             FROM \"EnumCaseTarget\".\"Rows\" r \
             JOIN pg_type t ON t.oid = pg_typeof(r.state)::oid \
             JOIN pg_namespace n ON n.oid = t.typnamespace \
             UNION ALL \
             SELECT n.nspname, t.typname, r.state::text, r.sibling \
             FROM enumcasetarget.rows r \
             JOIN pg_type t ON t.oid = pg_typeof(r.state)::oid \
             JOIN pg_namespace n ON n.oid = t.typnamespace \
             ORDER BY 1, 2, 4",
        )
        .await
        .unwrap();
    assert_eq!(
        native.rows,
        vec![
            vec![
                Value::Text("EnumCaseTarget".into()),
                Value::Text("StateKind".into()),
                Value::Text("target-only".into()),
                Value::Text("target-one".into()),
            ],
            vec![
                Value::Text("EnumCaseTarget".into()),
                Value::Text("StateKind".into()),
                Value::Text("ready".into()),
                Value::Text("target-two".into()),
            ],
            vec![
                Value::Text("enumcasetarget".into()),
                Value::Text("statekind".into()),
                Value::Text("ready".into()),
                Value::Text("shadow-one".into()),
            ],
        ]
    );

    connection
        .execute("CREATE ROLE mixed_case_enum_contract NOLOGIN")
        .await
        .unwrap();
    connection
        .execute("GRANT USAGE ON SCHEMA \"EnumCaseTarget\", enumcasetarget TO mixed_case_enum_contract")
        .await
        .unwrap();
    connection
        .execute(
            "GRANT USAGE ON TYPE \"EnumCaseTarget\".\"StateKind\", enumcasetarget.statekind \
             TO mixed_case_enum_contract",
        )
        .await
        .unwrap();
    connection
        .execute("GRANT SELECT, UPDATE ON \"EnumCaseTarget\".\"Rows\" TO mixed_case_enum_contract")
        .await
        .unwrap();

    let mut session = connection.open_session().await.unwrap();
    let control = crate::no_timeout();
    let original_search_path = session
        .query_params_controlled("SHOW search_path", &[], &control)
        .await
        .unwrap()
        .rows[0][0]
        .clone();
    session
        .query_params_controlled("SET ROLE mixed_case_enum_contract", &[], &control)
        .await
        .unwrap();
    session
        .query_params_controlled("SET search_path TO enumcasetarget, public", &[], &control)
        .await
        .unwrap();
    assert_eq!(
        session
            .query_params_controlled(
                "SELECT current_user::text, current_setting('search_path')::text",
                &[],
                &control,
            )
            .await
            .unwrap()
            .rows,
        vec![vec![
            Value::Text("mixed_case_enum_contract".into()),
            Value::Text("enumcasetarget, public".into()),
        ]]
    );

    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some("EnumCaseTarget"),
        "Rows",
        &columns,
        &[(1, Value::Text("target-only".into()))],
        &[Value::Int(2)],
    )
    .unwrap();
    assert!(update_sql.contains("\"EnumCaseTarget\".\"StateKind\""), "{update_sql}");
    session
        .query_params_controlled(&update_sql, &update_params, &control)
        .await
        .unwrap();

    let selected = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text \
             FROM \"EnumCaseTarget\".\"Rows\" \
             WHERE state IS NOT DISTINCT FROM $1 ORDER BY id",
            &[Value::Text("target-only".into())],
            &control,
        )
        .await
        .unwrap();
    let native_selected = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text \
             FROM \"EnumCaseTarget\".\"Rows\" \
             WHERE state IS NOT DISTINCT FROM 'target-only'::\"EnumCaseTarget\".\"StateKind\" \
             ORDER BY id",
            &[],
            &control,
        )
        .await
        .unwrap();
    assert_eq!(selected.rows, native_selected.rows);
    assert_eq!(
        selected.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("target-only".into()),
                Value::Text("\"EnumCaseTarget\".\"StateKind\"".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("target-only".into()),
                Value::Text("\"EnumCaseTarget\".\"StateKind\"".into()),
            ],
        ]
    );

    let invalid = session
        .query_params_controlled(
            "UPDATE \"EnumCaseTarget\".\"Rows\" SET state = $1 WHERE id = 2",
            &[Value::Text("shadow-only".into())],
            &control,
        )
        .await
        .expect_err("a shadow label must be rejected for the quoted target enum");
    let native_invalid = connection
        .query("SELECT 'shadow-only'::\"EnumCaseTarget\".\"StateKind\"")
        .await
        .expect_err("native target enum rejects the shadow-only label");
    let sqlstate = |error: &tablepro_core::DriverError| match error {
        tablepro_core::DriverError::Query { sqlstate, .. } => sqlstate.clone(),
        _ => None,
    };
    assert_eq!(sqlstate(&invalid).as_deref(), Some("22P02"));
    assert_eq!(sqlstate(&invalid), sqlstate(&native_invalid));

    let target_rows = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM \"EnumCaseTarget\".\"Rows\" ORDER BY id",
            &[],
            &control,
        )
        .await
        .unwrap();
    session
        .query_params_controlled(
            "SELECT set_config('search_path', $1, false)",
            &[original_search_path],
            &control,
        )
        .await
        .unwrap();
    session
        .query_params_controlled("RESET ROLE", &[], &control)
        .await
        .unwrap();
    let native_target_rows = session
        .query_params_controlled(
            "SELECT id, state::text, pg_typeof(state)::text, sibling \
             FROM \"EnumCaseTarget\".\"Rows\" ORDER BY id",
            &[],
            &control,
        )
        .await
        .unwrap();
    session.close().await.unwrap();
    assert_eq!(target_rows.rows, native_target_rows.rows);
    assert_eq!(
        target_rows.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("target-only".into()),
                Value::Text("\"EnumCaseTarget\".\"StateKind\"".into()),
                Value::Text("target-one".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("target-only".into()),
                Value::Text("\"EnumCaseTarget\".\"StateKind\"".into()),
                Value::Text("target-two".into()),
            ],
        ]
    );
    let shadow_rows = connection
        .query("SELECT id, state::text, sibling FROM enumcasetarget.rows ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        shadow_rows.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("ready".into()),
            Value::Text("shadow-one".into()),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mixed_case_enum_identifiers_survive_local_shadowed_search_path() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let schema = "EnumCaseLocal";
    let type_name = "StateKind";
    connection.execute("CREATE SCHEMA \"EnumCaseLocal\"").await.unwrap();
    connection.execute("CREATE SCHEMA enumcaselocal").await.unwrap();
    connection
        .execute("CREATE TYPE \"EnumCaseLocal\".\"StateKind\" AS ENUM ('ready', 'target-only')")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE enumcaselocal.statekind AS ENUM ('ready', 'shadow-only')")
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE \"EnumCaseLocal\".\"Rows\" \
             (id INT PRIMARY KEY, state \"EnumCaseLocal\".\"StateKind\", sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE enumcaselocal.rows \
             (id INT PRIMARY KEY, state enumcaselocal.statekind, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO \"EnumCaseLocal\".\"Rows\" VALUES \
             (1, 'ready', 'target-one'), (2, 'ready', 'target-two')",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO enumcaselocal.rows VALUES (1, 'ready', 'shadow-one')")
        .await
        .unwrap();

    let original_path = connection.query("SHOW search_path").await.unwrap().rows;
    let columns = connection.fetch_columns(Some(schema), "Rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: type_name.into(),
        })
    );
    let (update_sql, _) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "Rows",
        &columns,
        &[(1, Value::Text("target-only".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    assert!(update_sql.contains("\"EnumCaseLocal\".\"StateKind\""), "{update_sql}");
    let (where_sql, filter_params) = tablepro_core::build_filter_where(
        "postgres",
        &columns,
        &FilterSet {
            rules: vec![FilterRule {
                column: "state".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single("target-only".into())),
            }],
            ..Default::default()
        },
    )
    .unwrap()
    .unwrap();

    for (search_path, id, expected_ids) in [
        ("enumcaselocal, \"EnumCaseLocal\", public", 1, vec![1]),
        ("enumcaselocal, public", 2, vec![1, 2]),
    ] {
        let mut transaction = connection.begin().await.unwrap();
        transaction
            .execute(&format!("SET LOCAL search_path TO {search_path}"))
            .await
            .unwrap();
        assert_eq!(
            transaction.query("SHOW search_path").await.unwrap().rows,
            vec![vec![Value::Text(search_path.into())]],
            "the target schema should be present only in the first path"
        );

        transaction
            .execute_params(&update_sql, &[Value::Text("target-only".into()), Value::Int(id)])
            .await
            .unwrap();
        let filtered = transaction
            .query_params(
                &format!("SELECT id FROM \"EnumCaseLocal\".\"Rows\" WHERE {where_sql}"),
                &filter_params,
            )
            .await
            .unwrap();
        assert_eq!(
            filtered.rows,
            expected_ids
                .into_iter()
                .map(|id| vec![Value::Int(id)])
                .collect::<Vec<_>>()
        );

        transaction.execute("SAVEPOINT before_invalid_label").await.unwrap();
        let invalid = transaction
            .execute_params(&update_sql, &[Value::Text("shadow-only".into()), Value::Int(id)])
            .await
            .expect_err("a shadow-only label is invalid for the target enum");
        assert!(
            matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
            "expected native enum SQLSTATE 22P02, got {invalid:?}"
        );
        transaction
            .execute("ROLLBACK TO SAVEPOINT before_invalid_label")
            .await
            .unwrap();
        transaction.commit().await.unwrap();

        assert_eq!(connection.query("SHOW search_path").await.unwrap().rows, original_path);
    }

    let mut session = connection.open_session().await.unwrap();
    let control = crate::no_timeout();
    let session_path = session
        .query_params_controlled("SHOW search_path", &[], &control)
        .await
        .unwrap()
        .rows;
    session.query_params_controlled("BEGIN", &[], &control).await.unwrap();
    session
        .query_params_controlled(
            "SET LOCAL search_path TO enumcaselocal, \"EnumCaseLocal\", public",
            &[],
            &control,
        )
        .await
        .unwrap();
    let update = format!("{update_sql} RETURNING id");
    assert_eq!(
        session
            .query_params_controlled(&update, &[Value::Text("ready".into()), Value::Int(2)], &control)
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(2)]]
    );
    assert_eq!(
        session
            .query_params_controlled(
                &format!("SELECT id FROM \"EnumCaseLocal\".\"Rows\" WHERE {where_sql}"),
                &filter_params,
                &control,
            )
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)]],
        "typed filtering should still identify the target enum under the shadow path"
    );
    session
        .query_params_controlled("ROLLBACK", &[], &control)
        .await
        .unwrap();
    assert_eq!(
        session
            .query_params_controlled("SHOW search_path", &[], &control)
            .await
            .unwrap()
            .rows,
        session_path,
        "rollback must restore the original path on the same backend"
    );
    session.close().await.unwrap();

    let native = connection
        .query(
            "SELECT n.nspname, t.typname, r.state::text, r.sibling \
             FROM \"EnumCaseLocal\".\"Rows\" r \
             JOIN pg_type t ON t.oid = pg_typeof(r.state)::oid \
             JOIN pg_namespace n ON n.oid = t.typnamespace \
             UNION ALL \
             SELECT n.nspname, t.typname, r.state::text, r.sibling \
             FROM enumcaselocal.rows r \
             JOIN pg_type t ON t.oid = pg_typeof(r.state)::oid \
             JOIN pg_namespace n ON n.oid = t.typnamespace \
             ORDER BY 1, 2, 4",
        )
        .await
        .unwrap();
    assert_eq!(
        native.rows,
        vec![
            vec![
                Value::Text("EnumCaseLocal".into()),
                Value::Text("StateKind".into()),
                Value::Text("target-only".into()),
                Value::Text("target-one".into()),
            ],
            vec![
                Value::Text("EnumCaseLocal".into()),
                Value::Text("StateKind".into()),
                Value::Text("target-only".into()),
                Value::Text("target-two".into()),
            ],
            vec![
                Value::Text("enumcaselocal".into()),
                Value::Text("statekind".into()),
                Value::Text("ready".into()),
                Value::Text("shadow-one".into()),
            ],
        ]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_unicode_enum_identifiers_survive_metadata_and_typed_writes() {
    let (_container, opts) = start_pg().await;
    let connection = connect(opts).await;
    let schema = "value_contract_東京";
    let type_name = "状態";
    let quoted_schema = format!("\"{schema}\"");
    let quoted_type = format!("\"{type_name}\"");
    connection
        .execute(&format!("CREATE SCHEMA {quoted_schema}"))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TYPE {quoted_schema}.{quoted_type} AS ENUM ('ready', '東京', 'NULL', '')"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "CREATE TABLE {quoted_schema}.rows \
             (id INT PRIMARY KEY, state {quoted_schema}.{quoted_type}, sibling TEXT NOT NULL)"
        ))
        .await
        .unwrap();
    connection
        .execute(&format!(
            "INSERT INTO {quoted_schema}.rows VALUES (1, 'ready', 'keyed'), (2, NULL, 'sql-null')"
        ))
        .await
        .unwrap();

    let columns = connection.fetch_columns(Some(schema), "rows").await.unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: schema.into(),
            name: type_name.into(),
        })
    );

    let (update_sql, update_params) = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[(1, Value::Text("東京".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&update_sql, &update_params).await.unwrap();

    let (insert_sql, insert_params) = tablepro_core::sql_dialect::build_insert_from_draft(
        "postgres",
        Some(schema),
        "rows",
        &columns,
        &[Value::Int(3), Value::Text("NULL".into()), Value::Text("draft".into())],
    )
    .unwrap();
    connection.execute_params(&insert_sql, &insert_params).await.unwrap();

    let (where_sql, filter_params) = tablepro_core::build_filter_where(
        "postgres",
        &columns,
        &FilterSet {
            rules: vec![FilterRule {
                column: "state".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single("東京".into())),
            }],
            ..Default::default()
        },
    )
    .unwrap()
    .unwrap();
    let filtered = connection
        .query_params(
            &format!("SELECT id FROM {quoted_schema}.rows WHERE {where_sql}"),
            &filter_params,
        )
        .await
        .unwrap();
    assert_eq!(filtered.rows, vec![vec![Value::Int(1)]]);

    let invalid = connection
        .execute_params(&update_sql, &[Value::Text("not-a-label".into()), Value::Int(1)])
        .await
        .expect_err("invalid label must not enter the Unicode-named enum");
    assert!(
        matches!(&invalid, tablepro_core::DriverError::Query { sqlstate: Some(code), .. } if code == "22P02"),
        "expected native enum SQLSTATE 22P02, got {invalid:?}"
    );

    let stored = connection
        .query(&format!(
            "SELECT r.id, r.state::text, n.nspname, t.typname, r.sibling \
             FROM {quoted_schema}.rows r \
             JOIN pg_type t ON t.oid = pg_typeof(r.state)::oid \
             JOIN pg_namespace n ON n.oid = t.typnamespace ORDER BY r.id"
        ))
        .await
        .unwrap();
    assert_eq!(
        stored.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("東京".into()),
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("keyed".into()),
            ],
            vec![
                Value::Int(2),
                Value::Null,
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("sql-null".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("NULL".into()),
                Value::Text(schema.into()),
                Value::Text(type_name.into()),
                Value::Text("draft".into()),
            ],
        ]
    );
}
