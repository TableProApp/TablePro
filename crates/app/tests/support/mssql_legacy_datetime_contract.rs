use super::parse_input_for_driver;
use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, TlsConfig, Value};
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::mssql_server::MssqlServer;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mssql_legacy_datetime_text_grid_edit_preserves_wire_value_and_siblings() {
    let container = MssqlServer::default().with_accept_eula().start().await.unwrap();
    let connection = drivers_mssql::MssqlDriver
        .connect(ConnectOptions {
            host: container.get_host().await.unwrap().to_string(),
            port: container.get_host_port_ipv4(1433).await.unwrap(),
            database: "master".into(),
            username: "sa".into(),
            password: secrecy::SecretString::new(MssqlServer::DEFAULT_SA_PASSWORD.to_string().into()),
            tls: TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    connection
        .execute_controlled(
            "CREATE TABLE legacy_datetime_grid (id int PRIMARY KEY, value datetime NOT NULL, note nvarchar(20)); \
             INSERT INTO legacy_datetime_grid VALUES \
             (1, '2024-01-02T03:04:05.002', N'first'), \
             (2, '2024-01-02T03:04:05.005', N'second'), \
             (3, '2024-01-02T03:04:05.010', N'exact tick'), \
             (4, '2024-01-02T03:04:05.020', N'untouched sibling')",
            &control,
        )
        .await
        .unwrap();
    let columns = connection
        .fetch_columns_controlled(None, "legacy_datetime_grid", &control)
        .await
        .unwrap();
    let value_index = columns.iter().position(|column| column.name == "value").unwrap();
    let id_index = columns.iter().position(|column| column.name == "id").unwrap();
    assert_eq!(columns[value_index].data_type, "datetime");
    assert!(columns[id_index].primary_key);

    let before = connection
        .query_controlled(
            "SELECT id, value, CONVERT(varchar(23), value, 126) AS server_text, \
             CONVERT(varbinary(8), value) AS wire, note \
             FROM legacy_datetime_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(before.rows[0][1], Value::Text("2024-01-02T03:04:05.003".into()));
    assert_eq!(before.rows[1][1], Value::Text("2024-01-02T03:04:05.007".into()));
    assert_eq!(
        before.rows[2][1],
        Value::DateTime("2024-01-02T03:04:05.010".parse().unwrap())
    );

    let mut updates = Vec::new();
    for row in &before.rows[..3] {
        let Value::Text(server_text) = &row[2] else {
            panic!("native style-126 result must be text: {:?}", row[2]);
        };
        let displayed = crate::ui::grid::value_to_display_text(&row[1]);
        let expected_display = if matches!(row[1], Value::Text(_)) {
            server_text.clone()
        } else {
            server_text.replace('T', " ")
        };
        assert_eq!(displayed, expected_display);
        let parsed = parse_input_for_driver(&displayed, Some(&columns[value_index]), "mssql").unwrap();
        let Value::DateTime(parsed) = parsed else {
            panic!("datetime grid input should parse as DateTime");
        };
        let expected =
            chrono::NaiveDateTime::parse_from_str(&expected_display.replace('T', " "), "%Y-%m-%d %H:%M:%S%.f").unwrap();
        assert_eq!(
            parsed, expected,
            "grid parsing must retain the displayed fractional tick"
        );
        let update = tablepro_core::sql_dialect::build_keyed_update(
            "mssql",
            None,
            "legacy_datetime_grid",
            &columns,
            &[(value_index, Value::DateTime(parsed))],
            &[row[id_index].clone()],
        )
        .unwrap();
        updates.push(update);
    }
    assert_eq!(
        connection
            .execute_in_transaction_controlled(&updates, &control)
            .await
            .unwrap(),
        vec![1, 1, 1]
    );

    let after = connection
        .query_controlled(
            "SELECT id, value, CONVERT(varchar(23), value, 126) AS server_text, \
             CONVERT(varbinary(8), value) AS wire, note \
             FROM legacy_datetime_grid ORDER BY id",
            &control,
        )
        .await
        .unwrap();
    assert_eq!(
        after.rows, before.rows,
        "grid no-op changed a legacy datetime tick or sibling value"
    );
}
