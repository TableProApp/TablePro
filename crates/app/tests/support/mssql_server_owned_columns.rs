use tablepro_core::{ConnectOptions, DatabaseDriver, TlsConfig, Value};
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::mssql_server::MssqlServer;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_mssql_server_owned_columns_use_native_defaults_across_consumers() {
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
    connection
        .execute(
            "CREATE TABLE csv_owned (id int IDENTITY(1,1) PRIMARY KEY, note nvarchar(20) NOT NULL DEFAULT N'default', calculated AS (id * 2), version rowversion); INSERT INTO csv_owned (note) VALUES (N'source')",
        )
        .await
        .unwrap();

    let columns = connection.fetch_columns(None, "csv_owned").await.unwrap();
    assert!(columns[0].is_auto_increment);
    assert!(columns[2].is_generated);
    assert!(columns[3].is_generated);
    assert!(!crate::ui::grid::cell_allows_inline_edit(&columns[0], &Value::Int(1)));
    assert!(crate::ui::grid::cell_allows_inline_edit(
        &columns[1],
        &Value::Text("editable".into())
    ));
    assert!(!crate::ui::grid::cell_allows_inline_edit(&columns[2], &Value::Int(2)));
    assert!(!crate::ui::grid::cell_allows_inline_edit(
        &columns[3],
        &Value::Bytes(vec![0; 8])
    ));
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(
        b"id,note,calculated,version\n900,first,ignored,ignored\n901,second,ignored,ignored\n",
        &options,
        None,
    )
    .unwrap();
    let mapping = vec![Some(0), Some(1), Some(2), Some(3)];
    let plan = tablepro_core::import::build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "mssql",
            schema: None,
            table: "csv_owned",
            columns: &columns,
            mapping: &mapping,
        },
        &sheet,
        &options,
    )
    .unwrap();
    assert_eq!(
        plan.columns
            .iter()
            .map(|column| column.name.as_str())
            .collect::<Vec<_>>(),
        ["note"]
    );
    assert_eq!(
        plan.rows,
        vec![vec![Value::Text("first".into())], vec![Value::Text("second".into())]]
    );
    assert_eq!(plan.statement, "INSERT INTO [csv_owned] ([note]) VALUES (@P1)");
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }

    let result = connection
        .query("SELECT id, note, calculated, DATALENGTH(version) FROM csv_owned ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("source".into()),
                Value::Int(2),
                Value::Int(8)
            ],
            vec![Value::Int(2), Value::Text("first".into()), Value::Int(4), Value::Int(8)],
            vec![
                Value::Int(3),
                Value::Text("second".into()),
                Value::Int(6),
                Value::Int(8)
            ],
        ]
    );

    let copy_sql =
        tablepro_core::sql_literal::build_insert_literal("mssql", None, "csv_owned", &columns, &result.rows[1])
            .unwrap();
    assert_eq!(copy_sql, "INSERT INTO [csv_owned] ([note]) VALUES (N'first');");
    connection.execute(&copy_sql).await.unwrap();

    connection
        .execute(
            "CREATE TABLE csv_owned_export (id int IDENTITY(1,1) PRIMARY KEY, note nvarchar(20) NOT NULL DEFAULT N'default', calculated AS (id * 2), version rowversion)",
        )
        .await
        .unwrap();
    let source = connection
        .query("SELECT id, note, calculated, version FROM csv_owned ORDER BY id")
        .await
        .unwrap();
    let export_result = tablepro_core::QueryResult {
        columns: columns.clone(),
        rows: source.rows,
        truncated: false,
    };
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("server-owned.sql");
    let csv = tablepro_core::export::CsvOptions::default();
    let export = tablepro_core::export::ResultExport {
        format: tablepro_core::export::ResultFormat::Sql,
        csv: &csv,
        sql: Some(tablepro_core::export::SqlTarget {
            driver_id: "mssql",
            schema: None,
            table: "csv_owned_export",
        }),
    };
    tablepro_core::export::write_result_file(&path, &export_result, &export, || false, |_| {}).unwrap();
    let sql_file = std::fs::read_to_string(path).unwrap();
    assert_eq!(sql_file.lines().count(), 4);
    assert!(
        sql_file
            .lines()
            .all(|line| line.contains("([note])") && !line.contains("[id]"))
    );
    for statement in sql_file.lines() {
        connection.execute(statement).await.unwrap();
    }
    assert_eq!(
        connection
            .query("SELECT id, note, calculated, DATALENGTH(version) FROM csv_owned_export ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![
            vec![
                Value::Int(1),
                Value::Text("source".into()),
                Value::Int(2),
                Value::Int(8)
            ],
            vec![Value::Int(2), Value::Text("first".into()), Value::Int(4), Value::Int(8)],
            vec![
                Value::Int(3),
                Value::Text("second".into()),
                Value::Int(6),
                Value::Int(8)
            ],
            vec![Value::Int(4), Value::Text("first".into()), Value::Int(8), Value::Int(8)],
        ]
    );
}
