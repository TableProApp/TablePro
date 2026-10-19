use super::*;

#[tokio::test]
#[ignore = "requires docker"]
async fn reverse_composite_keyset_pages_keep_native_identity_and_skip_gaps() {
    let (_container, options) = super::start_pg().await;
    let connection = super::connect(options).await;
    connection
        .execute("CREATE TABLE reverse_pages (tenant integer NOT NULL, id integer NOT NULL, PRIMARY KEY (tenant, id))")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO reverse_pages SELECT tenant, id FROM generate_series(1, 3) AS tenant CROSS JOIN generate_series(1, 1000) AS id",
        )
        .await
        .unwrap();
    connection
        .execute("DELETE FROM reverse_pages WHERE tenant = 2 AND id = 998")
        .await
        .unwrap();

    let previous = connection
        .query_params(
            "SELECT tenant, id FROM reverse_pages WHERE (tenant, id) < ($1, $2) ORDER BY tenant DESC, id DESC LIMIT 3",
            &[Value::Int(2), Value::Int(1000)],
        )
        .await
        .unwrap();
    let mut ascending = previous.rows;
    ascending.reverse();
    assert_eq!(integer_pairs(&ascending), vec![(2, 996), (2, 997), (2, 999)]);
    let next = connection
        .query_params(
            "SELECT tenant, id FROM reverse_pages WHERE (tenant, id) > ($1, $2) ORDER BY tenant ASC, id ASC LIMIT 3",
            &[Value::Int(2), Value::Int(997)],
        )
        .await
        .unwrap();
    assert_eq!(integer_pairs(&next.rows), vec![(2, 999), (2, 1000), (3, 1)]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn reverse_keyset_handles_empty_exact_and_partial_pages_with_gapped_keys() {
    let (_container, options) = super::start_pg().await;
    let connection = super::connect(options).await;
    connection
        .execute("CREATE TABLE reverse_gaps (id integer PRIMARY KEY)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO reverse_gaps VALUES (1), (4), (7), (10), (13)")
        .await
        .unwrap();

    let exact = reverse_ids(connection.as_ref(), 10, 2).await;
    assert_eq!(exact, vec![4, 7]);
    let partial = reverse_ids(connection.as_ref(), 4, 2).await;
    assert_eq!(partial, vec![1]);
    let empty = reverse_ids(connection.as_ref(), 1, 2).await;
    assert!(empty.is_empty());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn reverse_deep_page_plan_uses_the_composite_primary_key_index() {
    let (_container, options) = super::start_pg().await;
    let connection = super::connect(options).await;
    connection
        .execute("CREATE TABLE reverse_plan (tenant integer NOT NULL, id integer NOT NULL, PRIMARY KEY (tenant, id))")
        .await
        .unwrap();
    connection
        .execute(
            "INSERT INTO reverse_plan SELECT tenant, id FROM generate_series(1, 20) AS tenant CROSS JOIN generate_series(1, 10000) AS id",
        )
        .await
        .unwrap();
    connection.execute("ANALYZE reverse_plan").await.unwrap();

    let plan = connection
        .query_params(
            "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) SELECT tenant, id FROM reverse_plan WHERE (tenant, id) < ($1, $2) ORDER BY tenant DESC, id DESC LIMIT 100",
            &[Value::Int(15), Value::Int(5000)],
        )
        .await
        .unwrap();
    let plan_text = plan
        .rows
        .iter()
        .filter_map(|row| row.first())
        .filter_map(|value| match value {
            Value::Text(line) => Some(line.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        plan_text.contains("Scan Backward using reverse_plan_pkey"),
        "{plan_text}"
    );
    assert!(plan_text.contains("Index Cond:"), "{plan_text}");
    assert!(plan_text.contains("Execution Time:"), "{plan_text}");
    let last_plan = connection
        .query(
            "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) SELECT tenant, id FROM reverse_plan ORDER BY tenant DESC, id DESC LIMIT 100",
        )
        .await
        .unwrap();
    let last_plan_text = last_plan
        .rows
        .iter()
        .filter_map(|row| row.first())
        .filter_map(|value| match value {
            Value::Text(line) => Some(line.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        last_plan_text.contains("Scan Backward using reverse_plan_pkey"),
        "{last_plan_text}"
    );
    assert!(!last_plan_text.contains("Sort"), "{last_plan_text}");
    assert!(last_plan_text.contains("Execution Time:"), "{last_plan_text}");
}

async fn reverse_ids(connection: &dyn Connection, boundary: i64, limit: u64) -> Vec<i64> {
    let result = connection
        .query_params(
            "SELECT id FROM reverse_gaps WHERE id < $1 ORDER BY id DESC LIMIT $2",
            &[Value::Int(boundary), Value::Int(limit as i64)],
        )
        .await
        .unwrap();
    let mut ids = result
        .rows
        .iter()
        .filter_map(|row| match row.first() {
            Some(Value::Int(value)) => Some(*value),
            _ => None,
        })
        .collect::<Vec<_>>();
    ids.reverse();
    ids
}

fn integer_pairs(rows: &[Vec<Value>]) -> Vec<(i64, i64)> {
    rows.iter()
        .map(|row| match (&row[0], &row[1]) {
            (Value::Int(tenant), Value::Int(id)) => (*tenant, *id),
            values => panic!("expected integer key pair, got {values:?}"),
        })
        .collect()
}
