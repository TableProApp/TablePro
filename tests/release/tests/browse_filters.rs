#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::{
    ColumnInfo, Combinator, Connection, FilterOp, FilterRule, FilterSet, FilterValue, Value, build_filter_where,
    keyset_order_by, keyset_where_clause,
};
use tablepro_release_tests::Fixture;

const TABLE: &str = "browse_filter_items";

async fn setup(connection: &dyn Connection) -> Vec<ColumnInfo> {
    connection
        .execute(&format!("DROP TABLE IF EXISTS {TABLE}"))
        .await
        .expect("drop any earlier fixture table");
    connection
        .execute(&format!(
            "CREATE TABLE {TABLE} (id integer PRIMARY KEY, name text, amount integer, note text)"
        ))
        .await
        .expect("create the browse fixture table");
    connection
        .execute(&format!(
            "INSERT INTO {TABLE} (id, name, amount, note) VALUES \
             (1, 'alpha', 10, 'first'), \
             (2, 'Beta', 20, NULL), \
             (3, 'gamma', 30, 'third'), \
             (4, 'delta', 40, NULL), \
             (5, 'alpine', 50, 'fifth')"
        ))
        .await
        .expect("seed the browse fixture table");

    connection
        .fetch_columns(None, TABLE)
        .await
        .expect("fetch the fixture columns")
}

async fn ids_matching(connection: &dyn Connection, columns: &[ColumnInfo], set: &FilterSet) -> Vec<i64> {
    let built = build_filter_where("postgres", columns, set).expect("build the filter clause");
    let sql = match &built {
        Some((clause, _)) => format!("SELECT id FROM {TABLE} WHERE {clause} ORDER BY id"),
        None => format!("SELECT id FROM {TABLE} ORDER BY id"),
    };
    let params = built.map(|(_, params)| params).unwrap_or_default();
    let result = connection
        .query_params(&sql, &params)
        .await
        .unwrap_or_else(|e| panic!("filtered select failed for {sql}: {e}"));
    result
        .rows
        .iter()
        .map(|row| match row.first() {
            Some(Value::Int(id)) => *id,
            other => panic!("unexpected id value: {other:?}"),
        })
        .collect()
}

fn rule(column: &str, op: FilterOp, value: Option<FilterValue>) -> FilterSet {
    FilterSet {
        combinator: Combinator::And,
        rules: vec![FilterRule {
            column: column.into(),
            op,
            value,
        }],
        extra_sql: None,
    }
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn every_filter_operator_selects_the_expected_rows() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    let columns = setup(connection.as_ref()).await;

    let cases: Vec<(&str, FilterSet, Vec<i64>)> = vec![
        (
            "eq",
            rule("name", FilterOp::Eq, Some(FilterValue::Single("alpha".into()))),
            vec![1],
        ),
        (
            "not_eq",
            rule("amount", FilterOp::NotEq, Some(FilterValue::Single("10".into()))),
            vec![2, 3, 4, 5],
        ),
        (
            "lt",
            rule("amount", FilterOp::Lt, Some(FilterValue::Single("30".into()))),
            vec![1, 2],
        ),
        (
            "lt_eq",
            rule("amount", FilterOp::LtEq, Some(FilterValue::Single("30".into()))),
            vec![1, 2, 3],
        ),
        (
            "gt",
            rule("amount", FilterOp::Gt, Some(FilterValue::Single("30".into()))),
            vec![4, 5],
        ),
        (
            "gt_eq",
            rule("amount", FilterOp::GtEq, Some(FilterValue::Single("30".into()))),
            vec![3, 4, 5],
        ),
        (
            "contains",
            rule("name", FilterOp::Contains, Some(FilterValue::Single("lp".into()))),
            vec![1, 5],
        ),
        (
            "starts_with",
            rule("name", FilterOp::StartsWith, Some(FilterValue::Single("al".into()))),
            vec![1, 5],
        ),
        (
            "ends_with",
            rule("name", FilterOp::EndsWith, Some(FilterValue::Single("ta".into()))),
            vec![2, 4],
        ),
        (
            "like",
            rule("name", FilterOp::Like, Some(FilterValue::Single("g%".into()))),
            vec![3],
        ),
        (
            "not_like",
            rule("name", FilterOp::NotLike, Some(FilterValue::Single("a%".into()))),
            vec![2, 3, 4],
        ),
        (
            "ilike",
            rule("name", FilterOp::Ilike, Some(FilterValue::Single("beta".into()))),
            vec![2],
        ),
        ("is_null", rule("note", FilterOp::IsNull, None), vec![2, 4]),
        ("is_not_null", rule("note", FilterOp::IsNotNull, None), vec![1, 3, 5]),
        (
            "in",
            rule(
                "amount",
                FilterOp::In,
                Some(FilterValue::List(vec!["10".into(), "40".into()])),
            ),
            vec![1, 4],
        ),
        (
            "not_in",
            rule(
                "amount",
                FilterOp::NotIn,
                Some(FilterValue::List(vec!["10".into(), "40".into()])),
            ),
            vec![2, 3, 5],
        ),
        (
            "between",
            rule(
                "amount",
                FilterOp::Between,
                Some(FilterValue::Pair("20".into(), "40".into())),
            ),
            vec![2, 3, 4],
        ),
    ];

    for (label, set, expected) in cases {
        let got = ids_matching(connection.as_ref(), &columns, &set).await;
        assert_eq!(got, expected, "operator {label} selected the wrong rows");
    }
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn combinators_and_raw_sql_compose_with_bound_rules() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    let columns = setup(connection.as_ref()).await;

    let disjunction = FilterSet {
        combinator: Combinator::Or,
        rules: vec![
            FilterRule {
                column: "amount".into(),
                op: FilterOp::Lt,
                value: Some(FilterValue::Single("20".into())),
            },
            FilterRule {
                column: "name".into(),
                op: FilterOp::Eq,
                value: Some(FilterValue::Single("delta".into())),
            },
        ],
        extra_sql: None,
    };
    assert_eq!(
        ids_matching(connection.as_ref(), &columns, &disjunction).await,
        vec![1, 4]
    );

    let with_raw = FilterSet {
        combinator: Combinator::And,
        rules: vec![FilterRule {
            column: "amount".into(),
            op: FilterOp::GtEq,
            value: Some(FilterValue::Single("20".into())),
        }],
        extra_sql: Some("length(name) = 5".into()),
    };
    assert_eq!(ids_matching(connection.as_ref(), &columns, &with_raw).await, vec![3, 4]);
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_filter_value_carrying_sql_stays_data() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    let columns = setup(connection.as_ref()).await;

    let payload = rule(
        "name",
        FilterOp::Eq,
        Some(FilterValue::Single(
            "' OR 1=1; DROP TABLE browse_filter_items --".into(),
        )),
    );
    assert!(ids_matching(connection.as_ref(), &columns, &payload).await.is_empty());

    let intact = connection
        .query(&format!("SELECT count(*) FROM {TABLE}"))
        .await
        .expect("the table must still exist");
    assert_eq!(intact.rows[0].first(), Some(&Value::Int(5)));
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn an_unknown_filter_column_is_refused_before_reaching_the_database() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    let columns = setup(connection.as_ref()).await;

    let set = rule("no_such_column", FilterOp::Eq, Some(FilterValue::Single("x".into())));
    let error = build_filter_where("postgres", &columns, &set).expect_err("unknown columns must be rejected");
    assert!(format!("{error}").contains("no_such_column"));
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn keyset_paging_walks_the_same_rows_as_offset_paging() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    setup(connection.as_ref()).await;

    let order_by = keyset_order_by("postgres", &["id"]);
    let mut seen: Vec<i64> = Vec::new();
    let mut last = Value::Int(0);

    for _ in 0..3 {
        let (clause, params) =
            keyset_where_clause("postgres", &["id"], std::slice::from_ref(&last), 0).expect("keyset clause");
        let sql = format!("SELECT id FROM {TABLE} WHERE {clause} {order_by} LIMIT 2");
        let page = connection
            .query_params(&sql, &params)
            .await
            .unwrap_or_else(|e| panic!("keyset page failed for {sql}: {e}"));
        if page.rows.is_empty() {
            break;
        }
        for row in &page.rows {
            match row.first() {
                Some(Value::Int(id)) => seen.push(*id),
                other => panic!("unexpected id value: {other:?}"),
            }
        }
        last = Value::Int(*seen.last().expect("at least one row"));
    }

    assert_eq!(seen, vec![1, 2, 3, 4, 5]);

    let offset_page = connection
        .query(&format!("SELECT id FROM {TABLE} ORDER BY id OFFSET 2 LIMIT 2"))
        .await
        .expect("offset page");
    let keyset_third_page = {
        let (clause, params) = keyset_where_clause("postgres", &["id"], &[Value::Int(2)], 0).expect("keyset clause");
        connection
            .query_params(
                &format!("SELECT id FROM {TABLE} WHERE {clause} {order_by} LIMIT 2"),
                &params,
            )
            .await
            .expect("keyset page")
    };
    assert_eq!(offset_page.rows, keyset_third_page.rows);
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_composite_keyset_seeks_past_the_last_seen_pair() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    setup(connection.as_ref()).await;

    let (clause, params) =
        keyset_where_clause("postgres", &["amount", "id"], &[Value::Int(30), Value::Int(3)], 0).expect("keyset clause");
    let order_by = keyset_order_by("postgres", &["amount", "id"]);
    let page = connection
        .query_params(&format!("SELECT id FROM {TABLE} WHERE {clause} {order_by}"), &params)
        .await
        .expect("composite keyset page");

    let ids: Vec<Value> = page.rows.iter().filter_map(|row| row.first().cloned()).collect();
    assert_eq!(ids, vec![Value::Int(4), Value::Int(5)]);
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn postgres_patterns_search_non_text_columns_without_changing_comparisons() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    let columns = setup(connection.as_ref()).await;
    // Expressions supply real PostgreSQL types without shared enum DDL.
    let cases = [
        ("uuid", "'550e8400-e29b-41d4-a716-446655440000'::uuid", "550e"),
        ("numeric", "123.45::numeric", "123"),
        ("integer", "123::integer", "123"),
        ("date", "DATE '2026-09-07'", "2026"),
        ("json", "'{\"label\":\"Alpha\"}'::json", "Alpha"),
        ("jsonb", "'{\"label\":\"Alpha\"}'::jsonb", "Alpha"),
        ("integer[]", "ARRAY[123,456]", "123"),
        ("enum", "'Alpha'::browse_filter_mood", "Alpha"),
    ];
    // A fixture-owned enum avoids relying on server-version-specific system enums.
    connection
        .execute("DROP TYPE IF EXISTS browse_filter_mood")
        .await
        .unwrap();
    connection
        .execute("CREATE TYPE browse_filter_mood AS ENUM ('Alpha', 'Beta')")
        .await
        .unwrap();
    for (data_type, expression, search) in cases {
        let mut column = columns[0].clone();
        column.name = "value".into();
        column.data_type = data_type.into();
        for op in [FilterOp::Contains, FilterOp::Ilike] {
            let pattern = if op == FilterOp::Ilike {
                format!("%{}%", search.to_lowercase())
            } else {
                search.into()
            };
            let set = rule("value", op, Some(FilterValue::Single(pattern)));
            let (clause, params) = build_filter_where("postgres", &[column.clone()], &set)
                .unwrap()
                .unwrap();
            let sql = format!("SELECT 1 AS matched FROM (SELECT {expression} AS value) t WHERE {clause}");
            let result = connection
                .query_params(&sql, &params)
                .await
                .unwrap_or_else(|e| panic!("{data_type}: {e}"));
            assert_eq!(result.rows.len(), 1, "{data_type} {op:?}");
        }
    }
    let set = rule("amount", FilterOp::Gt, Some(FilterValue::Single("20".into())));
    assert_eq!(ids_matching(connection.as_ref(), &columns, &set).await, vec![3, 4, 5]);
    connection.execute("DROP TYPE browse_filter_mood").await.unwrap();
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn capped_stream_preserves_columns_values_and_connection_reuse() {
    use std::time::Duration;
    use tablepro_core::{MAX_QUERY_ROWS, OperationControl};
    let connection = Fixture::from_env().connect_verified().await;
    let result = connection
        .query_controlled(
            &format!(
                "SELECT n::bigint AS id, 'kept'::text AS label FROM generate_series(1, {}) n",
                MAX_QUERY_ROWS + 1
            ),
            &OperationControl::with_timeout(Duration::from_secs(60)),
        )
        .await
        .unwrap();
    assert_eq!(
        result.columns.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(),
        ["id", "label"]
    );
    assert!(!result.rows.is_empty());
    assert!(
        result.rows.len() < MAX_QUERY_ROWS,
        "decoded memory budget binds before row cap"
    );
    assert!(result.truncated);
    assert_eq!(result.rows[0], [Value::Int(1), Value::Text("kept".into())]);
    let last_id = result.rows.len() as i64;
    assert_eq!(result.rows.last().unwrap()[0], Value::Int(last_id));
    assert_eq!(result.rows.last().unwrap()[1], Value::Text("kept".into()));
    drop(result);
    let next = connection.query("SELECT 42::bigint AS answer").await.unwrap();
    assert_eq!(next.rows, vec![vec![Value::Int(42)]]);
    assert!(!next.truncated);
}
