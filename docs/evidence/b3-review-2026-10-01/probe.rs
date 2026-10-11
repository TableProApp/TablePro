#![allow(
    dead_code,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::print_stdout
)]

#[macro_export]
macro_rules! tr {
    ($text:expr) => {
        $text.to_string()
    };
}

mod parser {
    include!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/ui/browse_tab/value_parse.rs"));
}

use tablepro_core::import::{CsvImportOptions, CsvSheet, ImportTarget, build_insert_plan};
use tablepro_core::{ColumnInfo, ConnectOptions, DatabaseDriver, Value};

fn column(data_type: &str) -> ColumnInfo {
    ColumnInfo {
        name: "value".into(),
        data_type: data_type.into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
    }
}

fn plan(data_type: &str, text: &str) -> tablepro_core::import::InsertPlan {
    build_insert_plan(
        &ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "audit_values",
            columns: &[column(data_type)],
            mapping: &[Some(0)],
        },
        &CsvSheet {
            headers: vec!["value".into()],
            rows: vec![vec![text.into()]],
            truncated: false,
        },
        &CsvImportOptions::default(),
    )
    .unwrap()
}

#[tokio::main]
async fn main() {
    for (driver, kind) in [
        ("mysql", "int"),
        ("mongodb", "int"),
        ("mongodb", "long"),
        ("mongodb", "decimal"),
        ("postgres", "numeric"),
        ("duckdb", "timestamp"),
        ("duckdb", "timestamptz"),
    ] {
        let result = parser::parse_input_for_driver("", Some(&column(kind)), driver);
        println!("empty nullable {driver}/{kind}: {result:?}");
        assert_ne!(result, Ok(Value::Null));
        assert_eq!(parser::parse_input_for_column("", Some(&column(kind))), Ok(Value::Null));
    }
    let text = "  padded  CHAR  ";
    let normalized = parser::normalize_single_line_input(text);
    let edited = parser::parse_input_for_driver(&normalized, Some(&column("char(20)")), "mysql").unwrap();
    assert_eq!(edited, Value::Text("padded CHAR".into()));
    println!("text input {text:?} becomes {edited:?}");

    use testcontainers_modules::{postgres::Postgres, testcontainers::runners::AsyncRunner};
    let server = Postgres::default().start().await.unwrap();
    let connection = drivers_postgres::PgDriver
        .connect(ConnectOptions {
            host: server.get_host().await.unwrap().to_string(),
            port: server.get_host_port_ipv4(5432).await.unwrap(),
            database: "postgres".into(),
            username: "postgres".into(),
            password: "postgres".to_string().into(),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE audit_values(value numeric(65,0))")
        .await
        .unwrap();
    let wide = "1234567890123456789012345678901234567890";
    let import = plan("numeric(65,0)", wide);
    println!("wide numeric plan: {} {:?}", import.statement, import.rows);
    assert_eq!(import.rows[0], vec![Value::Text(wide.into())]);
    let result = connection.execute_params(&import.statement, &import.rows[0]).await;
    println!("wide numeric execution: {result:?}");
    assert!(
        matches!(result, Err(tablepro_core::DriverError::Query { sqlstate: Some(ref code), .. }) if code == "42804")
    );
    connection.execute("DROP TABLE audit_values").await.unwrap();
    connection
        .execute("CREATE TABLE audit_values(value date)")
        .await
        .unwrap();
    let source = connection.query("SELECT DATE '0001-01-02 BC' AS value").await.unwrap();
    let csv = tablepro_core::export::render_csv(&source.columns, &source.rows, &Default::default());
    let sheet = tablepro_core::import::read_csv(csv.as_bytes(), &Default::default(), None).unwrap();
    println!("BC date source {:?}, CSV {csv:?}", source.rows);
    let import = plan("date", &sheet.rows[0][0]);
    println!("year zero plan: {} {:?}", import.statement, import.rows);
    let result = connection.execute_params(&import.statement, &import.rows[0]).await;
    println!("year zero execution: {result:?}");
    assert!(result.is_err());
    let stored = connection.query("SELECT count(*) FROM audit_values").await.unwrap();
    assert_eq!(stored.rows, vec![vec![Value::Int(0)]]);
}
