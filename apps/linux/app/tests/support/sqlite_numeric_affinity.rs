use super::parse_input_for_grid_cell;
use tablepro_core::Value;

#[tokio::test]
async fn sqlite_numeric_affinity_grid_edit_preserves_text_and_sibling_values() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE flexible (\
                 id INTEGER PRIMARY KEY, integer_amount INTEGER, \
                 real_amount REAL, numeric_amount NUMERIC, enum_like ENUM\
             )",
        )
        .await
        .unwrap();
    connection
        .execute("INSERT INTO flexible VALUES (1, 1, 1.5, 1, 'queued'), (2, 2, 2.5, 2, '2.5')")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "flexible").await.unwrap();
    let before = connection.query("SELECT * FROM flexible ORDER BY id").await.unwrap();
    let integer_index = columns
        .iter()
        .position(|column| column.name == "integer_amount")
        .unwrap();
    let decimal = parse_input_for_grid_cell(
        "42.50",
        Some(&columns[integer_index]),
        "sqlite",
        Some(&before.rows[0][integer_index]),
    )
    .unwrap();
    assert_eq!(decimal, Value::Decimal("42.50".parse().unwrap()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "sqlite",
        None,
        "flexible",
        &columns,
        &[(integer_index, decimal)],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();

    let enum_index = columns.iter().position(|column| column.name == "enum_like").unwrap();
    let enum_value = parse_input_for_grid_cell(
        "4.25",
        Some(&columns[enum_index]),
        "sqlite",
        Some(&before.rows[0][enum_index]),
    )
    .unwrap();
    assert_eq!(enum_value, Value::Decimal("4.25".parse().unwrap()));
    assert!(
        parse_input_for_grid_cell(
            "1e999",
            Some(&columns[enum_index]),
            "sqlite",
            Some(&Value::Text("queued".into()))
        )
        .is_err(),
        "numeric overflow must not be passed to SQLite as text and coerced by affinity"
    );
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "sqlite",
        None,
        "flexible",
        &columns,
        &[(enum_index, enum_value)],
        &[Value::Int(1)],
    )
    .unwrap();
    connection.execute_in_transaction(&[update]).await.unwrap();
    assert_eq!(
        connection
            .query("SELECT typeof(integer_amount), integer_amount FROM flexible WHERE id = 1")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Text("real".into()), Value::Float(42.5)]],
        "an exact decimal edit in an INTEGER-affinity column remains a REAL"
    );

    for (name, input) in [
        ("integer_amount", "9223372036854775808"),
        ("real_amount", "1e999"),
        ("real_amount", "1e-400"),
        ("numeric_amount", "0.123456789012345678901234567890123"),
    ] {
        let column = columns.iter().find(|column| column.name == name).unwrap();
        assert!(
            parse_input_for_grid_cell(input, Some(column), "sqlite", Some(&Value::Int(1))).is_err(),
            "SQLite grid must reject numeric-looking input that affinity could round: {name}"
        );
    }

    for name in ["integer_amount", "real_amount", "numeric_amount"] {
        let index = columns.iter().position(|column| column.name == name).unwrap();
        let current = &before.rows[0][index];
        let edit = parse_input_for_grid_cell("not numeric", Some(&columns[index]), "sqlite", Some(current))
            .unwrap_or_else(|error| panic!("SQLite affinity column {name} must accept TEXT: {error}"));
        assert_eq!(edit, Value::Text("not numeric".into()), "column {name}");
        for driver in ["mysql", "mssql"] {
            assert!(
                parse_input_for_grid_cell("not numeric", Some(&columns[index]), driver, Some(current)).is_err(),
                "the SQLite affinity fallback must not relax {driver} column {name}"
            );
        }
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "sqlite",
            None,
            "flexible",
            &columns,
            &[(index, edit)],
            &[Value::Int(1)],
        )
        .unwrap();
        connection.execute_in_transaction(&[update]).await.unwrap();
    }

    let after = connection
        .query(
            "SELECT id, typeof(integer_amount), integer_amount, \
                    typeof(real_amount), real_amount, \
                    typeof(numeric_amount), numeric_amount, \
                    typeof(enum_like), quote(enum_like) \
             FROM flexible ORDER BY id",
        )
        .await
        .unwrap();
    assert_eq!(
        after.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("text".into()),
                Value::Text("not numeric".into()),
                Value::Text("text".into()),
                Value::Text("not numeric".into()),
                Value::Text("text".into()),
                Value::Text("not numeric".into()),
                Value::Text("real".into()),
                Value::Text("4.25".into()),
            ],
            vec![
                Value::Int(2),
                Value::Text("integer".into()),
                Value::Int(2),
                Value::Text("real".into()),
                Value::Float(2.5),
                Value::Text("integer".into()),
                Value::Int(2),
                Value::Text("real".into()),
                Value::Text("2.5".into()),
            ],
        ]
    );
}

#[tokio::test]
async fn sqlite_numeric_affinity_grid_edit_respects_storage_class_constraints() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE constrained (id INTEGER PRIMARY KEY, amount NUMERIC CHECK (typeof(amount) != 'text'))")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO constrained VALUES (1, 1)")
        .await
        .unwrap();
    let columns = connection.fetch_columns(None, "constrained").await.unwrap();
    let amount_index = columns.iter().position(|column| column.name == "amount").unwrap();
    let current = connection
        .query("SELECT amount FROM constrained WHERE id = 1")
        .await
        .unwrap();
    let edit = parse_input_for_grid_cell(
        "not numeric",
        Some(&columns[amount_index]),
        "sqlite",
        Some(&current.rows[0][0]),
    )
    .unwrap();
    assert_eq!(edit, Value::Text("not numeric".into()));
    let update = tablepro_core::sql_dialect::build_keyed_update(
        "sqlite",
        None,
        "constrained",
        &columns,
        &[(amount_index, edit)],
        &[Value::Int(1)],
    )
    .unwrap();

    assert!(connection.execute_in_transaction(&[update]).await.is_err());
    assert_eq!(
        connection
            .query("SELECT typeof(amount), amount FROM constrained WHERE id = 1")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Text("integer".into()), Value::Int(1)]],
        "a constraint-rejected TEXT edit must leave the prior value unchanged"
    );
}
