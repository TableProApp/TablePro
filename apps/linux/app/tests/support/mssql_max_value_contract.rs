use sha2::Digest;
use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, TlsConfig, Value};
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::mssql_server::MssqlServer;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mssql_max_values_survive_connection_session_and_consumers() {
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
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(90));
    connection
        .execute_controlled(
            "CREATE TABLE mssql_max_values (id int PRIMARY KEY, ntext nvarchar(max) NULL, vtext varchar(max) NULL, payload varbinary(max) NULL)",
            &control,
        )
        .await
        .unwrap();

    let mut cases = Vec::new();
    for (id, bytes) in [(1, 65_534usize), (2, 65_536), (3, 65_538), (4, 1_048_576)] {
        cases.push((
            id,
            Value::Text("Ω".repeat(bytes / 2)),
            Value::Text("v".repeat(bytes)),
            Value::Bytes((0..bytes).map(|index| (index % 251) as u8).collect()),
            (bytes, bytes),
        ));
    }
    cases.push((
        5,
        Value::Text(String::new()),
        Value::Text(String::new()),
        Value::Bytes(Vec::new()),
        (0, 0),
    ));
    cases.push((6, Value::Null, Value::Null, Value::Null, (0, 0)));

    let mut session = connection.open_session().await.unwrap();
    for (id, ntext, vtext, payload, _) in &cases {
        for (row_id, params) in [
            (*id, vec![ntext.clone(), vtext.clone(), payload.clone()]),
            (id + 10, vec![ntext.clone(), vtext.clone(), payload.clone()]),
        ] {
            let mut bound = vec![Value::Int(row_id.into())];
            bound.extend(params);
            let affected = if row_id < 10 {
                connection
                    .execute_params_controlled(
                        "INSERT INTO mssql_max_values VALUES (@P1, @P2, @P3, CONVERT(varbinary(max), @P4))",
                        &bound,
                        &control,
                    )
                    .await
                    .unwrap()
                    .rows_affected
            } else {
                session
                    .query_params_controlled(
                        "INSERT INTO mssql_max_values VALUES (@P1, @P2, @P3, CONVERT(varbinary(max), @P4))",
                        &bound,
                        &control,
                    )
                    .await
                    .unwrap();
                1
            };
            assert_eq!(affected, 1);
        }
    }

    let sql = "SELECT id, ntext, vtext, payload, DATALENGTH(ntext), DATALENGTH(vtext), DATALENGTH(payload), HASHBYTES('SHA2_256', ntext), HASHBYTES('SHA2_256', vtext), HASHBYTES('SHA2_256', payload) FROM mssql_max_values ORDER BY id";
    let ordinary = connection.query_controlled(sql, &control).await.unwrap();
    let dedicated = session.query_params_controlled(sql, &[], &control).await.unwrap();
    assert_eq!(
        ordinary.rows, dedicated.rows,
        "ordinary and dedicated sessions returned different values"
    );
    assert_eq!(ordinary.rows.len(), cases.len() * 2);
    let columns = connection.fetch_columns(None, "mssql_max_values").await.unwrap();
    assert_eq!(
        columns
            .iter()
            .map(|column| column.data_type.as_str())
            .collect::<Vec<_>>(),
        ["int", "nvarchar(max)", "varchar(max)", "varbinary(max)"]
    );

    for (id, expected_ntext, expected_vtext, expected_payload, (text_bytes, binary_bytes)) in &cases {
        for row_id in [*id, id + 10] {
            let row = ordinary
                .rows
                .iter()
                .find(|row| row[0] == Value::Int(row_id.into()))
                .unwrap();
            assert_eq!(&row[1], expected_ntext, "nvarchar(max) row {row_id}");
            assert_eq!(&row[2], expected_vtext, "varchar(max) row {row_id}");
            assert_eq!(&row[3], expected_payload, "varbinary(max) row {row_id}");
            let null = matches!(expected_ntext, Value::Null);
            assert_eq!(
                row[4],
                if null {
                    Value::Null
                } else {
                    Value::Int(*text_bytes as i64)
                }
            );
            assert_eq!(
                row[5],
                if null {
                    Value::Null
                } else {
                    Value::Int(*text_bytes as i64)
                }
            );
            assert_eq!(
                row[6],
                if null {
                    Value::Null
                } else {
                    Value::Int(*binary_bytes as i64)
                }
            );
            for (index, (hash, value)) in row[7..10]
                .iter()
                .zip([expected_ntext, expected_vtext, expected_payload])
                .enumerate()
            {
                let expected_hash = match value {
                    Value::Null => Value::Null,
                    Value::Text(text) if index == 0 => Value::Bytes(
                        sha2::Sha256::digest(text.encode_utf16().flat_map(u16::to_le_bytes).collect::<Vec<_>>())
                            .to_vec(),
                    ),
                    Value::Text(text) => Value::Bytes(sha2::Sha256::digest(text.as_bytes()).to_vec()),
                    Value::Bytes(bytes) => Value::Bytes(sha2::Sha256::digest(bytes).to_vec()),
                    other => panic!("unexpected SQL Server max value: {other:?}"),
                };
                assert_eq!(hash, &expected_hash, "native SHA-256 for row {row_id}, value {index}");
            }
        }
    }

    let display = crate::ui::grid::value_to_display_text(&ordinary.rows[0][1]);
    assert!(display.starts_with(&"Ω".repeat(10_000)));
    assert!(display.ends_with("… (+22767 more chars)"));
    assert_eq!(
        crate::ui::grid::value_to_display_text(&ordinary.rows[0][3]),
        "<65534 bytes>"
    );

    let mut csv_options = tablepro_core::export::CsvOptions::default();
    let null_marker = tablepro_core::export::unique_csv_null_marker(&ordinary.rows);
    csv_options.null_marker = Some(null_marker.clone());
    let csv = tablepro_core::export::render_csv(&ordinary.columns[..4], &ordinary.rows, &csv_options);
    let sheet = tablepro_core::import::read_csv(
        csv.as_bytes(),
        &tablepro_core::import::CsvImportOptions {
            null_marker,
            ..Default::default()
        },
        None,
    )
    .unwrap();
    let import_columns = columns.clone();
    let imported = sheet
        .rows
        .iter()
        .enumerate()
        .map(|(index, row)| {
            tablepro_core::import::row_to_values(
                row,
                &[Some(0), Some(1), Some(2), Some(3)],
                &import_columns,
                &tablepro_core::import::CsvImportOptions {
                    null_marker: csv_options.null_marker.clone().unwrap(),
                    ..Default::default()
                },
                index + 2,
            )
            .unwrap()
        })
        .collect::<Vec<_>>();
    assert_eq!(
        imported,
        ordinary.rows.iter().map(|row| row[..4].to_vec()).collect::<Vec<_>>()
    );

    let json: serde_json::Value = serde_json::from_str(&tablepro_core::export::render_json(
        &ordinary.columns[..4],
        &ordinary.rows,
    ))
    .unwrap();
    assert_eq!(json.as_array().unwrap().len(), ordinary.rows.len());
    assert_eq!(
        json[0]["ntext"].as_str().unwrap(),
        match &ordinary.rows[0][1] {
            Value::Text(text) => text.as_str(),
            value => panic!("expected JSON text value, got {value:?}"),
        }
    );
    assert_eq!(json[0]["vtext"].as_str().unwrap(), "v".repeat(65_534));
    assert_eq!(json[0]["payload"].as_str().unwrap().len(), 2 + 65_534 * 2);
    assert!(
        json[0]["payload"]
            .as_str()
            .unwrap()
            .starts_with("\\x00010203040506070809")
    );

    let directory = tempfile::tempdir().unwrap();
    let export = tablepro_core::export::ResultExport {
        format: tablepro_core::export::ResultFormat::Xlsx,
        csv: &csv_options,
        sql: None,
    };
    let xlsx_path = directory.path().join("mssql-max-boundary.xlsx");
    let boundary = tablepro_core::QueryResult {
        columns: vec![ordinary.columns[1].clone()],
        rows: vec![vec![cases[0].1.clone()]],
        truncated: false,
    };
    tablepro_core::export::write_result_file(&xlsx_path, &boundary, &export, || false, |_| {}).unwrap();
    let over_limit = tablepro_core::QueryResult {
        columns: boundary.columns.clone(),
        rows: vec![vec![cases[1].1.clone()]],
        truncated: false,
    };
    assert!(
        tablepro_core::export::write_result_file(&xlsx_path, &over_limit, &export, || false, |_| {}).is_err(),
        "XLSX must report its cell-length limit instead of silently truncating max values"
    );
    session.close().await.unwrap();
}
