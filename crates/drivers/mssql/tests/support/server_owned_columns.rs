use tablepro_core::{Connection, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn value_contract_server_owned_columns_and_identity_copy_inserts_use_defaults() {
    let (_container, options) = super::start_mssql().await;
    let connection = super::connect(options).await;
    create_source(connection.as_ref()).await;
    let columns = connection
        .fetch_columns(Some("owned.schema"), "owned.table")
        .await
        .unwrap();
    let generated: Vec<&str> = columns
        .iter()
        .filter(|column| column.is_generated)
        .map(|column| column.name.as_str())
        .collect();
    assert_eq!(generated, ["calculated", "version", "starts", "ends"]);
    assert!(columns[0].is_auto_increment, "identity metadata must be exact");
    assert!(!columns[0].is_generated);
    assert!(!columns[1].is_generated);
    assert_eq!(columns[1].default_value.as_deref(), Some("N'pending'"));
    assert_eq!(columns[1].data_type, "nvarchar(20)");
    let native = connection
        .query("SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(N'[owned.schema].[owned.table]') AND (is_computed = 1 OR system_type_id = 189 OR generated_always_type > 0) ORDER BY column_id")
        .await
        .unwrap();
    assert_eq!(
        native.rows,
        generated
            .iter()
            .map(|name| vec![Value::Text((*name).into())])
            .collect::<Vec<_>>()
    );
    let mut row = connection
        .query("SELECT id, note, calculated, version, starts, ends FROM [owned.schema].[owned.table]")
        .await
        .unwrap()
        .rows
        .remove(0);
    row[0] = Value::Int(2);
    assert_insert_consumers(connection.as_ref(), &columns, &row).await;
    let rows = connection
        .query("SELECT id, note, calculated, DATALENGTH(version) FROM [owned.schema].[owned.table] ORDER BY id")
        .await
        .unwrap();
    assert_eq!(rows.rows.len(), 3);
    for (row, id) in rows.rows.iter().zip([1, 2, 3]) {
        assert_eq!(
            row,
            &[
                Value::Int(id),
                Value::Text("source".into()),
                Value::Int(id * 2),
                Value::Int(8)
            ]
        );
    }

    connection
        .execute("CREATE TABLE [owned.schema].[identity_only] (id int IDENTITY(1,1) PRIMARY KEY)")
        .await
        .unwrap();
    connection
        .execute("INSERT INTO [owned.schema].[identity_only] DEFAULT VALUES")
        .await
        .unwrap();
    let columns = connection
        .fetch_columns(Some("owned.schema"), "identity_only")
        .await
        .unwrap();
    let row = connection
        .query("SELECT id FROM [owned.schema].[identity_only]")
        .await
        .unwrap()
        .rows
        .remove(0);
    let sql = tablepro_core::sql_literal::build_insert_literal(
        "mssql",
        Some("owned.schema"),
        "identity_only",
        &columns,
        &row,
    )
    .unwrap();
    assert_eq!(sql, "INSERT INTO [owned.schema].[identity_only] DEFAULT VALUES;");
    connection.execute(&sql).await.unwrap();
    assert_eq!(
        connection
            .query("SELECT id FROM [owned.schema].[identity_only] ORDER BY id")
            .await
            .unwrap()
            .rows,
        vec![vec![Value::Int(1)], vec![Value::Int(2)]]
    );
}

async fn create_source(connection: &dyn Connection) {
    for sql in [
        "EXEC(N'CREATE SCHEMA [owned.schema]')",
        "CREATE TABLE [owned.schema].[owned.table] (id int IDENTITY(1,1) PRIMARY KEY, note nvarchar(20) DEFAULT N'pending', calculated AS (id * 2), version rowversion, starts datetime2(7) GENERATED ALWAYS AS ROW START HIDDEN NOT NULL DEFAULT SYSUTCDATETIME(), ends datetime2(7) GENERATED ALWAYS AS ROW END HIDDEN NOT NULL DEFAULT CONVERT(datetime2(7), '9999-12-31 23:59:59.9999999'), PERIOD FOR SYSTEM_TIME (starts, ends)) WITH (SYSTEM_VERSIONING = ON)",
        "INSERT INTO [owned.schema].[owned.table] (note) VALUES (N'source')",
    ] {
        connection.execute(sql).await.unwrap();
    }
}

async fn assert_insert_consumers(connection: &dyn Connection, columns: &[tablepro_core::ColumnInfo], row: &[Value]) {
    let sql =
        tablepro_core::sql_literal::build_insert_literal("mssql", Some("owned.schema"), "owned.table", columns, row)
            .unwrap();
    assert!(!sql.contains("[version]"));
    assert!(!sql.contains("[starts]"));
    assert!(!sql.contains("[ends]"));
    assert!(!sql.contains("[calculated]"));
    connection.execute(&sql).await.unwrap();
    let mut draft = row.to_vec();
    draft[0] = Value::Int(3);
    let (sql, parameters) = tablepro_core::sql_dialect::build_insert_from_draft(
        "mssql",
        Some("owned.schema"),
        "owned.table",
        columns,
        &draft,
    )
    .unwrap();
    connection.execute_params(&sql, &parameters).await.unwrap();
}
