use tablepro_core::{ConnectOptions, DatabaseDriver, Value, import::build_insert_plan};
use testcontainers::ImageExt;
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::postgres::Postgres;

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_postgres_csv_import_preserves_explicit_identity_values() {
    let container = Postgres::default().with_tag("16-alpine").start().await.unwrap();
    let connection = drivers_postgres::PgDriver
        .connect(ConnectOptions {
            host: container.get_host().await.unwrap().to_string(),
            port: container.get_host_port_ipv4(5432).await.unwrap(),
            database: "postgres".into(),
            username: "postgres".into(),
            password: secrecy::SecretString::new("postgres".to_string().into()),
            ..Default::default()
        })
        .await
        .unwrap();
    connection
        .execute(
            "CREATE TABLE csv_identity (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, note text NOT NULL, doubled bigint GENERATED ALWAYS AS (id * 2) STORED)",
        )
        .await
        .unwrap();
    let options = tablepro_core::import::CsvImportOptions::default();
    let sheet = tablepro_core::import::read_csv(
        b"id,note,doubled\n900,alpha,ignored\n901,beta,ignored\n",
        &options,
        None,
    )
    .unwrap();
    let columns = connection.fetch_columns(None, "csv_identity").await.unwrap();
    let plan = build_insert_plan(
        &tablepro_core::import::ImportTarget {
            driver_id: "postgres",
            schema: None,
            table: "csv_identity",
            columns: &columns,
            mapping: &[Some(0), Some(1), Some(2)],
        },
        &sheet,
        &options,
    )
    .unwrap();

    assert_eq!(
        plan.statement,
        "INSERT INTO \"csv_identity\" (\"id\", \"note\") OVERRIDING SYSTEM VALUE VALUES ($1, $2)"
    );
    for row in &plan.rows {
        connection.execute_params(&plan.statement, row).await.unwrap();
    }
    let result = connection
        .query("SELECT id, note, doubled FROM csv_identity ORDER BY id")
        .await
        .unwrap();
    assert_eq!(
        result.rows,
        vec![
            vec![Value::Int(900), Value::Text("alpha".into()), Value::Int(1800)],
            vec![Value::Int(901), Value::Text("beta".into()), Value::Int(1802)],
        ]
    );
}
