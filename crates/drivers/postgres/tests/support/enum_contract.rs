use tablepro_core::Value;
use tablepro_core::{FilterOp, FilterRule, FilterSet, FilterValue};

use crate::{connect, start_pg};

include!("enum_contract_parts/scalar_consumers.rs");
include!("enum_contract_parts/scalar_csv.rs");

include!("enum_contract_parts/writes_and_shadowing.rs");

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_custom_enum_quoted_identifiers_support_keyed_edit_and_filter() {
    let (_container, opts) = start_pg().await;
    let setup = connect(opts.clone()).await;
    setup.execute("CREATE SCHEMA \"Enum \"\"Shadow\"").await.unwrap();
    setup.execute("CREATE SCHEMA \"Enum \"\"Shelf\"").await.unwrap();
    setup
        .execute("CREATE TYPE \"Enum \"\"Shadow\".\"State \"\"Kind\" AS ENUM ('ready', 'shadow_only')")
        .await
        .unwrap();
    setup
        .execute("CREATE TYPE \"Enum \"\"Shelf\".\"State \"\"Kind\" AS ENUM ('ready', 'paused')")
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TABLE \"Enum \"\"Shadow\".\"Row \"\"Box\" \
             (id INT PRIMARY KEY, status \"Enum \"\"Shadow\".\"State \"\"Kind\", sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TABLE \"Enum \"\"Shelf\".\"Row \"\"Box\" \
             (id INT PRIMARY KEY, status \"Enum \"\"Shelf\".\"State \"\"Kind\", sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    setup
        .execute(
            "INSERT INTO \"Enum \"\"Shadow\".\"Row \"\"Box\" \
             VALUES (1, 'ready', 'shadow')",
        )
        .await
        .unwrap();
    setup
        .execute(
            "INSERT INTO \"Enum \"\"Shelf\".\"Row \"\"Box\" \
             VALUES (1, 'ready', 'target'), (2, 'ready', 'sibling')",
        )
        .await
        .unwrap();

    setup
        .execute("ALTER ROLE postgres SET search_path TO \"Enum \"\"Shadow\"")
        .await
        .unwrap();
    drop(setup);
    let connection = connect(opts).await;
    assert_eq!(
        connection.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text("Enum \"Shadow".into())]]
    );
    let columns = connection
        .fetch_columns(Some("Enum \"Shelf"), "Row \"Box")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "Enum \"Shelf".into(),
            name: "State \"Kind".into(),
        })
    );
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "postgres",
        Some("Enum \"Shelf"),
        "Row \"Box",
        &columns,
        &[(1, Value::Text("paused".into()))],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_params(&update.0, &update.1).await.unwrap();

    let rows = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text, \
             pg_typeof(status) = '\"Enum \"\"Shelf\".\"State \"\"Kind\"'::regtype, sibling \
             FROM \"Enum \"\"Shelf\".\"Row \"\"Box\" ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        rows.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("paused".into()),
                Value::Text("\"Enum \"\"Shelf\".\"State \"\"Kind\"".into()),
                Value::Bool(true),
                Value::Text("target".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("ready".into()),
                Value::Text("\"Enum \"\"Shelf\".\"State \"\"Kind\"".into()),
                Value::Bool(true),
                Value::Text("sibling".into()),
            ],
        ]
    );
    let shadow = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text, \
             pg_typeof(status) = '\"Enum \"\"Shadow\".\"State \"\"Kind\"'::regtype, sibling \
             FROM \"Enum \"\"Shadow\".\"Row \"\"Box\"",
        )
        .await
        .unwrap();
    assert_eq!(
        shadow.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("ready".into()),
            Value::Text("\"State \"\"Kind\"".into()),
            Value::Bool(true),
            Value::Text("shadow".into()),
        ]]
    );

    let filters = tablepro_core::FilterSet {
        rules: vec![tablepro_core::FilterRule {
            column: "status".into(),
            op: tablepro_core::FilterOp::Eq,
            value: Some(tablepro_core::FilterValue::Single("paused".into())),
        }],
        ..Default::default()
    };
    let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &filters)
        .unwrap()
        .unwrap();
    let filtered = connection
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text, \
                 pg_typeof(status) = '\"Enum \"\"Shelf\".\"State \"\"Kind\"'::regtype \
                 FROM \"Enum \"\"Shelf\".\"Row \"\"Box\" WHERE {where_sql}"
            ),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        filtered.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("paused".into()),
            Value::Text("\"Enum \"\"Shelf\".\"State \"\"Kind\"".into()),
            Value::Bool(true),
        ]]
    );

    let import_options = tablepro_core::import::CsvImportOptions::default();
    let sheet =
        tablepro_core::import::read_csv(b"id,status,sibling\n3,paused,csv import\n", &import_options, None).unwrap();
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: Some("Enum \"Shelf"),
            table: "Row \"Box",
            columns: &columns,
            mapping: &[Some(0), Some(1), Some(2)],
        },
        &sheet,
        &import_options,
    )
    .unwrap();
    assert!(
        plan.statement
            .contains("$2::text::\"Enum \"\"Shelf\".\"State \"\"Kind\""),
        "CSV import must quote and schema-qualify the enum target: {}",
        plan.statement
    );
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    let imported = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text, sibling \
             FROM \"Enum \"\"Shelf\".\"Row \"\"Box\" ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        imported.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("paused".into()),
                Value::Text("\"Enum \"\"Shelf\".\"State \"\"Kind\"".into()),
                Value::Text("target".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("ready".into()),
                Value::Text("\"Enum \"\"Shelf\".\"State \"\"Kind\"".into()),
                Value::Text("sibling".into()),
            ],
            vec![
                Value::Int(3),
                Value::Text("paused".into()),
                Value::Text("\"Enum \"\"Shelf\".\"State \"\"Kind\"".into()),
                Value::Text("csv import".into()),
            ],
        ]
    );
    let shadow = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text, sibling \
             FROM \"Enum \"\"Shadow\".\"Row \"\"Box\"",
        )
        .await
        .unwrap();
    assert_eq!(
        shadow.rows,
        vec![vec![
            Value::Int(1),
            Value::Text("ready".into()),
            Value::Text("\"State \"\"Kind\"".into()),
            Value::Text("shadow".into()),
        ]]
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_domain_enum_parameters_resolve_shadowed_schema_type() {
    let (_container, opts) = start_pg().await;
    let setup = connect(opts.clone()).await;
    setup.execute("CREATE SCHEMA enum_domain_shadow_a").await.unwrap();
    setup.execute("CREATE SCHEMA enum_domain_shadow_b").await.unwrap();
    setup
        .execute("CREATE TYPE enum_domain_shadow_a.status_kind AS ENUM ('ready', 'paused')")
        .await
        .unwrap();
    setup
        .execute("CREATE TYPE enum_domain_shadow_b.status_kind AS ENUM ('ready', 'paused')")
        .await
        .unwrap();
    setup
        .execute("CREATE DOMAIN enum_domain_shadow_a.status_domain AS enum_domain_shadow_a.status_kind")
        .await
        .unwrap();
    setup
        .execute("CREATE DOMAIN enum_domain_shadow_b.status_domain AS enum_domain_shadow_b.status_kind")
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TABLE enum_domain_shadow_a.items \
             (id INT PRIMARY KEY, status enum_domain_shadow_a.status_domain, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    setup
        .execute(
            "CREATE TABLE enum_domain_shadow_b.items \
             (id INT PRIMARY KEY, status enum_domain_shadow_b.status_domain, sibling TEXT NOT NULL)",
        )
        .await
        .unwrap();
    setup
        .execute(
            "INSERT INTO enum_domain_shadow_a.items VALUES \
             (1, 'ready', 'shadow'), (2, NULL, 'shadow-null')",
        )
        .await
        .unwrap();
    setup
        .execute(
            "INSERT INTO enum_domain_shadow_b.items VALUES \
             (1, 'ready', 'target-ready'), (2, 'paused', 'target-paused'), (3, NULL, 'target-null')",
        )
        .await
        .unwrap();
    setup
        .execute("ALTER ROLE postgres SET search_path TO enum_domain_shadow_a")
        .await
        .unwrap();
    drop(setup);

    let connection = connect(opts).await;
    assert_eq!(
        connection.query("SELECT current_schema()::text").await.unwrap().rows,
        vec![vec![Value::Text("enum_domain_shadow_a".into())]]
    );
    let columns = connection
        .fetch_columns(Some("enum_domain_shadow_b"), "items")
        .await
        .unwrap();
    assert_eq!(
        columns[1].enum_type,
        Some(tablepro_core::QualifiedTypeName {
            schema: "enum_domain_shadow_b".into(),
            name: "status_kind".into(),
        })
    );

    let filters = FilterSet {
        rules: vec![FilterRule {
            column: "status".into(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("paused".into())),
        }],
        ..Default::default()
    };
    let (where_sql, params) = tablepro_core::build_filter_where("postgres", &columns, &filters)
        .unwrap()
        .unwrap();
    let filtered = connection
        .query_params(
            &format!(
                "SELECT id, status::text, pg_typeof(status)::text \
                 FROM enum_domain_shadow_b.items WHERE {where_sql}"
            ),
            &params,
        )
        .await
        .unwrap();
    assert_eq!(
        filtered.rows,
        vec![vec![
            Value::Int(2),
            Value::Text("paused".into()),
            Value::Text("enum_domain_shadow_b.status_domain".into()),
        ]]
    );

    let mut transaction = connection.begin().await.unwrap();
    transaction
        .execute("SET LOCAL search_path TO enum_domain_shadow_a")
        .await
        .unwrap();
    let text_parameter = transaction
        .query_params(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM enum_domain_shadow_b.items \
             WHERE status::enum_domain_shadow_b.status_kind = $1",
            &[Value::Text("paused".into())],
        )
        .await
        .unwrap();
    assert_eq!(
        text_parameter.rows,
        vec![vec![
            Value::Int(2),
            Value::Text("paused".into()),
            Value::Text("enum_domain_shadow_b.status_domain".into()),
        ]]
    );

    let null_parameter = transaction
        .query_params(
            "SELECT id, status::text, pg_typeof(status)::text \
             FROM enum_domain_shadow_b.items \
             WHERE status::enum_domain_shadow_b.status_kind IS NOT DISTINCT FROM $1 ORDER BY id",
            &[Value::Null],
        )
        .await
        .unwrap();
    assert_eq!(
        null_parameter.rows,
        vec![vec![
            Value::Int(3),
            Value::Null,
            Value::Text("enum_domain_shadow_b.status_domain".into()),
        ]]
    );

    type OperatorCase = (&'static str, Vec<Value>, &'static [(i64, Option<&'static str>)]);
    let operator_cases: [OperatorCase; 10] = [
        (
            "status::enum_domain_shadow_b.status_kind <> $1",
            vec![Value::Text("ready".into())],
            &[(2, Some("paused"))],
        ),
        (
            "status::enum_domain_shadow_b.status_kind < $1",
            vec![Value::Text("paused".into())],
            &[(1, Some("ready"))],
        ),
        (
            "status::enum_domain_shadow_b.status_kind <= $1",
            vec![Value::Text("ready".into())],
            &[(1, Some("ready"))],
        ),
        (
            "status::enum_domain_shadow_b.status_kind > $1",
            vec![Value::Text("ready".into())],
            &[(2, Some("paused"))],
        ),
        (
            "status::enum_domain_shadow_b.status_kind >= $1",
            vec![Value::Text("paused".into())],
            &[(2, Some("paused"))],
        ),
        (
            "status::enum_domain_shadow_b.status_kind IN ($1, $2)",
            vec![Value::Text("ready".into()), Value::Text("paused".into())],
            &[(1, Some("ready")), (2, Some("paused"))],
        ),
        (
            "status::enum_domain_shadow_b.status_kind NOT IN ($1)",
            vec![Value::Text("ready".into())],
            &[(2, Some("paused"))],
        ),
        (
            "status::enum_domain_shadow_b.status_kind BETWEEN $1 AND $2",
            vec![Value::Text("ready".into()), Value::Text("paused".into())],
            &[(1, Some("ready")), (2, Some("paused"))],
        ),
        (
            "status::enum_domain_shadow_b.status_kind IS DISTINCT FROM $1",
            vec![Value::Text("ready".into())],
            &[(2, Some("paused")), (3, None)],
        ),
        (
            "status::enum_domain_shadow_b.status_kind IS NOT DISTINCT FROM $1",
            vec![Value::Null],
            &[(3, None)],
        ),
    ];
    for (predicate, params, expected) in operator_cases {
        let result = transaction
            .query_params(
                &format!(
                    "SELECT id, status::text, pg_typeof(status)::text \
                     FROM enum_domain_shadow_b.items WHERE {predicate} ORDER BY id"
                ),
                &params,
            )
            .await
            .unwrap();
        let expected_rows = expected
            .iter()
            .map(|(id, status)| {
                vec![
                    Value::Int(*id),
                    status.map(|value| Value::Text(value.into())).unwrap_or(Value::Null),
                    Value::Text("enum_domain_shadow_b.status_domain".into()),
                ]
            })
            .collect::<Vec<_>>();
        assert_eq!(result.rows, expected_rows, "predicate {predicate:?}");
    }
    transaction.rollback().await.unwrap();

    let shadow = connection
        .query(
            "SELECT id, status::text, pg_typeof(status)::text, sibling \
                FROM enum_domain_shadow_a.items ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        shadow.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("ready".into()),
                Value::Text("status_domain".into()),
                Value::Text("shadow".into()),
            ],
            vec![
                Value::Int(2),
                Value::Null,
                Value::Text("status_domain".into()),
                Value::Text("shadow-null".into()),
            ],
        ]
    );
}
