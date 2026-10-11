#[tokio::test]
async fn sqlite_json_each_typed_csv_round_trip_preserves_runtime_storage_classes() {
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
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, key ANY, value ANY, json_type TEXT, \
                 value_class TEXT, atom ANY, atom_class TEXT\
             ) STRICT",
        )
        .await
        .unwrap();
    let result = connection
        .query(
            r#"SELECT key, value, type, typeof(value), atom, typeof(atom)
               FROM json_each('[1,1.25,"text","",null,true,false,{"x":1},[2]]')
               ORDER BY key"#,
        )
        .await
        .unwrap();
    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2), Some(3), Some(4), Some(5)],
    )
    .await;

    let restored = connection
        .query(
            "SELECT typeof(key), key, typeof(value), value, json_type, value_class, \
                    typeof(atom), atom, atom_class FROM restored ORDER BY id",
        )
        .await
        .unwrap();
    let expected = result
        .rows
        .iter()
        .map(|row| {
            vec![
                Value::Text("integer".into()),
                row[0].clone(),
                row[3].clone(),
                row[1].clone(),
                row[2].clone(),
                row[3].clone(),
                row[5].clone(),
                row[4].clone(),
                row[5].clone(),
            ]
        })
        .collect::<Vec<_>>();
    assert_eq!(restored.rows, expected);
}

#[tokio::test]
async fn sqlite_json_each_object_typed_csv_round_trip_preserves_text_keys() {
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
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, key ANY, value ANY, json_type TEXT, \
                 key_class TEXT, value_class TEXT, atom ANY, atom_class TEXT\
             ) STRICT",
        )
        .await
        .unwrap();
    let result = connection
        .query(
            r#"SELECT key, value, type, typeof(key), typeof(value), atom, typeof(atom)
               FROM json_each('{"":null,"01":true,"NULL":"","雪":{"x":1}}')
               ORDER BY key"#,
        )
        .await
        .unwrap();
    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2), Some(3), Some(4), Some(5), Some(6)],
    )
    .await;

    let restored = connection
        .query(
            "SELECT typeof(key), key, typeof(value), value, json_type, key_class, \
                    value_class, typeof(atom), atom, atom_class FROM restored ORDER BY id",
        )
        .await
        .unwrap();
    let expected = result
        .rows
        .iter()
        .map(|row| {
            vec![
                row[3].clone(),
                row[0].clone(),
                row[4].clone(),
                row[1].clone(),
                row[2].clone(),
                row[3].clone(),
                row[4].clone(),
                row[6].clone(),
                row[5].clone(),
                row[6].clone(),
            ]
        })
        .collect::<Vec<_>>();
    assert_eq!(restored.rows, expected);
}

#[tokio::test]
async fn sqlite_json_operators_typed_csv_round_trip_preserves_json_and_sql_values() {
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
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, json_value ANY, json_class TEXT, sql_value ANY, sql_class TEXT\
             ) STRICT",
        )
        .await
        .unwrap();
    let result = connection
        .query(
            r#"WITH source(document) AS (
                   VALUES (json('{"integer":42,"real":1.25,"text":"text","numeric_text":"42","null":null,
                                 "boolean":true,"object":{"x":1},"array":[2],"empty":""}'))
               )
               SELECT 1, document -> '$.integer', typeof(document -> '$.integer'),
                      document ->> '$.integer', typeof(document ->> '$.integer') FROM source
               UNION ALL
               SELECT 2, document -> '$.real', typeof(document -> '$.real'),
                      document ->> '$.real', typeof(document ->> '$.real') FROM source
               UNION ALL
               SELECT 3, document -> '$.numeric_text', typeof(document -> '$.numeric_text'),
                      document ->> '$.numeric_text', typeof(document ->> '$.numeric_text') FROM source
               UNION ALL
               SELECT 4, document -> '$.text', typeof(document -> '$.text'),
                      document ->> '$.text', typeof(document ->> '$.text') FROM source
               UNION ALL
               SELECT 5, document -> '$.null', typeof(document -> '$.null'),
                      document ->> '$.null', typeof(document ->> '$.null') FROM source
               UNION ALL
               SELECT 6, document -> '$.boolean', typeof(document -> '$.boolean'),
                      document ->> '$.boolean', typeof(document ->> '$.boolean') FROM source
               UNION ALL
               SELECT 7, document -> '$.object', typeof(document -> '$.object'),
                      document ->> '$.object', typeof(document ->> '$.object') FROM source
               UNION ALL
               SELECT 8, document -> '$.array', typeof(document -> '$.array'),
                      document ->> '$.array', typeof(document ->> '$.array') FROM source
               UNION ALL
               SELECT 9, document -> '$.empty', typeof(document -> '$.empty'),
                      document ->> '$.empty', typeof(document ->> '$.empty') FROM source
               ORDER BY 1"#,
        )
        .await
        .unwrap();
    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[Some(0), Some(1), Some(2), Some(3), Some(4)],
    )
    .await;

    let restored = connection
        .query(
            "SELECT typeof(json_value), json_value, json_class, typeof(sql_value), sql_value, sql_class \
             FROM restored ORDER BY id",
        )
        .await
        .unwrap();
    let expected = [
        ("42", Value::Int(42), "integer"),
        ("1.25", Value::Float(1.25), "real"),
        ("\"42\"", Value::Text("42".into()), "text"),
        ("\"text\"", Value::Text("text".into()), "text"),
        ("null", Value::Null, "null"),
        ("true", Value::Int(1), "integer"),
        (r#"{"x":1}"#, Value::Text(r#"{"x":1}"#.into()), "text"),
        ("[2]", Value::Text("[2]".into()), "text"),
        ("\"\"", Value::Text(String::new()), "text"),
    ]
    .into_iter()
    .map(|(json_value, sql_value, sql_class)| {
        vec![
            Value::Text("text".into()),
            Value::Text(json_value.into()),
            Value::Text("text".into()),
            Value::Text(sql_class.into()),
            sql_value,
            Value::Text(sql_class.into()),
        ]
    })
    .collect::<Vec<_>>();
    assert_eq!(restored.rows, expected);
}

#[tokio::test]
async fn sqlite_json_constructors_typed_csv_round_trip_preserves_json_text() {
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
            "CREATE TABLE restored (\
                 id INTEGER PRIMARY KEY, object ANY, object_class TEXT, array ANY, array_class TEXT\
             ) STRICT",
        )
        .await
        .unwrap();
    let result = connection
        .query(
            "SELECT json_object('empty', '', 'null', NULL, 'number', 7), \
                    typeof(json_object('empty', '', 'null', NULL, 'number', 7)), \
                    json_array(1, 1.25, '', NULL, json('true'), json('{\"x\":1}')), \
                    typeof(json_array(1, 1.25, '', NULL, json('true'), json('{\"x\":1}'))) ",
        )
        .await
        .unwrap();
    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), Some(1), Some(2), Some(3)],
    )
    .await;

    let restored = connection
        .query(
            "SELECT typeof(object), object, object_class, typeof(array), array, array_class \
             FROM restored ORDER BY id",
        )
        .await
        .unwrap();
    let row = &result.rows[0];
    assert_eq!(
        restored.rows,
        vec![vec![
            row[1].clone(),
            row[0].clone(),
            row[1].clone(),
            row[3].clone(),
            row[2].clone(),
            row[3].clone(),
        ]]
    );
}

#[tokio::test]
async fn sqlite_jsonb_typed_csv_round_trip_preserves_blob_bytes() {
    use tablepro_core::{ConnectOptions, DatabaseDriver};

    let connection = drivers_sqlite::SqliteDriver
        .connect(ConnectOptions {
            database: ":memory:".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE restored (id INTEGER PRIMARY KEY, value ANY) STRICT")
        .await
        .unwrap();
    let result = connection
        .query(
            "SELECT jsonb('{\"empty\":\"\",\"null\":null,\"nested\":[1,true]}') AS value, \
                    typeof(jsonb('{\"empty\":\"\",\"null\":null,\"nested\":[1,true]}')) AS storage_class, \
                    json(jsonb('{\"empty\":\"\",\"null\":null,\"nested\":[1,true]}')) AS json_text, \
                    hex(jsonb('{\"empty\":\"\",\"null\":null,\"nested\":[1,true]}')) AS native_hex",
        )
        .await
        .unwrap();
    sqlite_result_csv_round_trip(
        connection.as_ref(),
        &result,
        "restored",
        &[None, Some(0), None, None],
    )
    .await;

    let restored = connection
        .query("SELECT typeof(value), hex(value), json(value) FROM restored ORDER BY id")
        .await
        .unwrap();
    let source = &result.rows[0];
    assert_eq!(
        restored.rows,
        vec![vec![
            source[1].clone(),
            source[3].clone(),
            source[2].clone(),
        ]]
    );
}
