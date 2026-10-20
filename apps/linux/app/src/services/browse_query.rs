pub(crate) use tablepro_app_services::browse_query::{BoundQuery, BrowseTarget, PageQuery};

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use tablepro_core::{ColumnInfo, FilterSet, Value};
    #[path = "mongodb_value.rs"]
    mod mongodb_value;
    #[path = "redis_value.rs"]
    mod redis_value;
    fn column(name: &str, primary_key: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "text".into(),
            nullable: false,
            primary_key,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    async fn guarded_value_refetch(
        connection: std::sync::Arc<dyn tablepro_core::Connection>,
        driver_id: &str,
        query: &BoundQuery,
        control: &tablepro_core::OperationControl,
    ) -> tablepro_core::QueryResult {
        use tablepro_core::{Connection, Environment};
        use tablepro_policy::{
            AuditState, DenyApprovalSink, GuardContext, NullAuditSink, PolicyConfig, PolicyGuard, Principal,
        };

        PolicyGuard::new(
            connection,
            GuardContext {
                connection_id: uuid::Uuid::new_v4(),
                connection_name: format!("{driver_id} value refetch"),
                driver_id: driver_id.into(),
                environment: Environment::Local,
                read_only: true,
                principal: Principal::human_gui(),
                policy: std::sync::Arc::new(PolicyConfig::default()),
                approval: std::sync::Arc::new(DenyApprovalSink),
                audit: std::sync::Arc::new(NullAuditSink),
                audit_state: std::sync::Arc::new(AuditState::new()),
            },
        )
        .query_params_controlled(&query.sql, &query.params, control)
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn sqlite_hidden_projection_keeps_the_primary_key_and_leaves_hidden_values_stored() {
        use tablepro_core::{ConnectOptions, DatabaseDriver};

        let directory = tempfile::tempdir().unwrap();
        let connection = drivers_sqlite::SqliteDriver
            .connect(ConnectOptions {
                database: directory.path().join("projection.db").to_string_lossy().into_owned(),
                ..Default::default()
            })
            .await
            .unwrap();
        let control = crate::services::operation_control::bounded(30);
        connection
            .execute_controlled(
                "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, secret TEXT)",
                &control,
            )
            .await
            .unwrap();
        connection
            .execute_controlled("INSERT INTO items VALUES (7, 'Ada', 'still stored')", &control)
            .await
            .unwrap();

        let columns = vec![column("id", true), column("name", false), column("secret", false)];
        let hidden: HashSet<String> = ["secret"].map(str::to_owned).into();
        let target = BrowseTarget {
            driver_id: "sqlite",
            schema: None,
            table: "items",
            columns: &columns,
            filter: &FilterSet::default(),
            hidden_columns: Some(&hidden),
        };
        let PageQuery::Sql(query) = target.page(0, 10, None, None).unwrap() else {
            panic!("expected projected SQL")
        };
        assert_eq!(query.projected_columns, Some(vec![0, 1]));
        let projected = connection
            .query_params_controlled(&query.sql, &query.params, &control)
            .await
            .unwrap();
        assert_eq!(projected.rows, vec![vec![Value::Int(7), Value::Text("Ada".into())]]);

        let native = connection
            .query_controlled("SELECT secret FROM items WHERE id = 7", &control)
            .await
            .unwrap();
        assert_eq!(native.rows, vec![vec![Value::Text("still stored".into())]]);
    }

    #[tokio::test]
    async fn sqlite_value_query_refetches_the_exact_blob_for_a_composite_key() {
        use tablepro_core::{ConnectOptions, DatabaseDriver};

        let directory = tempfile::tempdir().unwrap();
        let connection = drivers_sqlite::SqliteDriver
            .connect(ConnectOptions {
                database: directory.path().join("value-fetch.db").to_string_lossy().into_owned(),
                ..Default::default()
            })
            .await
            .unwrap();
        let control = crate::services::operation_control::bounded(30);
        connection
            .execute_controlled(
                "CREATE TABLE records (tenant TEXT, id INTEGER, payload BLOB, PRIMARY KEY (tenant, id))",
                &control,
            )
            .await
            .unwrap();
        let tenant = "tenant ' OR 1=1 --";
        let bytes: Vec<u8> = (0..9000).map(|index| (index % 256) as u8).collect();
        connection
            .execute_params_controlled(
                "INSERT INTO records VALUES (?1, ?2, ?3)",
                &[Value::Text(tenant.into()), Value::Int(7), Value::Bytes(bytes.clone())],
                &control,
            )
            .await
            .unwrap();
        let native = connection
            .query_controlled(
                "SELECT typeof(payload), length(payload), hex(substr(payload, 1, 8)) FROM records WHERE tenant = 'tenant '' OR 1=1 --' AND id = 7",
                &control,
            )
            .await
            .unwrap();
        assert_eq!(
            native.rows,
            vec![vec![
                Value::Text("blob".into()),
                Value::Int(9000),
                Value::Text("0001020304050607".into())
            ]]
        );

        let columns = vec![column("tenant", true), column("id", true), column("payload", false)];
        let target = BrowseTarget {
            driver_id: "sqlite",
            schema: None,
            table: "records",
            columns: &columns,
            filter: &FilterSet::default(),
            hidden_columns: None,
        };
        let query = target
            .value_query(2, &[Value::Text(tenant.into()), Value::Int(7)])
            .unwrap();
        let fetched = connection
            .query_params_controlled(&query.sql, &query.params, &control)
            .await
            .unwrap();
        assert_eq!(fetched.rows, vec![vec![Value::Bytes(bytes.clone())]]);

        let guarded = guarded_value_refetch(std::sync::Arc::from(connection), "sqlite", &query, &control).await;
        assert_eq!(guarded.rows, vec![vec![Value::Bytes(bytes)]]);
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn mysql_value_query_refetches_the_exact_blob_for_a_composite_key() {
        use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, TlsConfig};
        use testcontainers::ImageExt;
        use testcontainers::runners::AsyncRunner;
        use testcontainers_modules::mysql::Mysql;

        let container = Mysql::default()
            .with_env_var("MYSQL_ROOT_PASSWORD", "tablepro_test")
            .with_cmd(["--default-authentication-plugin=mysql_native_password"])
            .start()
            .await
            .unwrap();
        let connection = drivers_mysql::MysqlDriver
            .connect(ConnectOptions {
                host: container.get_host().await.unwrap().to_string(),
                port: container.get_host_port_ipv4(3306).await.unwrap(),
                database: "test".into(),
                username: "root".into(),
                password: secrecy::SecretString::new("tablepro_test".into()),
                tls: TlsConfig::disabled(),
                ..Default::default()
            })
            .await
            .unwrap();
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
        let tenant = b"tenant ' OR 1=1 --".to_vec();
        let bytes: Vec<u8> = (0..9000).map(|index| (index % 256) as u8).collect();
        insert_mysql_value_preview_rows(&*connection, &control, &tenant, &bytes).await;
        assert_mysql_value_preview_native(&*connection, &control, &tenant).await;
        let columns = connection
            .fetch_columns_controlled(None, "value_preview_records", &control)
            .await
            .unwrap();
        assert!(columns[0].primary_key && columns[1].primary_key);
        let target = BrowseTarget {
            driver_id: "mysql",
            schema: None,
            table: "value_preview_records",
            columns: &columns,
            filter: &FilterSet::default(),
            hidden_columns: None,
        };
        let query = target.value_query(2, &[Value::Bytes(tenant), Value::Int(7)]).unwrap();
        let fetched = connection
            .query_params_controlled(&query.sql, &query.params, &control)
            .await
            .unwrap();
        assert_eq!(fetched.rows, vec![vec![Value::Bytes(bytes.clone())]]);
        let guarded = guarded_value_refetch(std::sync::Arc::from(connection), "mysql", &query, &control).await;
        assert_eq!(guarded.rows, vec![vec![Value::Bytes(bytes)]]);
    }

    #[cfg(feature = "duckdb")]
    #[tokio::test]
    async fn value_contract_duckdb_guarded_value_query_refetches_exact_blob() {
        use tablepro_core::{ConnectOptions, DatabaseDriver};

        let connection = drivers_duckdb::DuckdbDriver
            .connect(ConnectOptions {
                database: ":memory:".into(),
                ..Default::default()
            })
            .await
            .unwrap();
        let control = crate::services::operation_control::bounded(30);
        let tenant = "tenant ' OR 1=1 --";
        let bytes: Vec<u8> = (0..9000).map(|index| (index % 256) as u8).collect();
        seed_duckdb_value_preview(&*connection, &control, &tenant, &bytes).await;
        assert_duckdb_value_preview_native(&*connection, &control, &tenant).await;
        let columns = connection
            .fetch_columns_controlled(None, "value_preview_records", &control)
            .await
            .unwrap();
        assert!(columns[0].primary_key && columns[1].primary_key);
        let target = BrowseTarget {
            driver_id: "duckdb",
            schema: None,
            table: "value_preview_records",
            columns: &columns,
            filter: &FilterSet::default(),
            hidden_columns: None,
        };
        let query = target
            .value_query(2, &[Value::Text(tenant.into()), Value::Int(7)])
            .unwrap();
        let guarded = guarded_value_refetch(std::sync::Arc::from(connection), "duckdb", &query, &control).await;
        assert_eq!(guarded.rows, vec![vec![Value::Bytes(bytes)]]);
    }

    #[cfg(feature = "duckdb")]
    async fn seed_duckdb_value_preview(
        connection: &dyn tablepro_core::Connection,
        control: &tablepro_core::OperationControl,
        tenant: &str,
        bytes: &[u8],
    ) {
        connection
            .execute_controlled(
                "CREATE TABLE value_preview_records (tenant VARCHAR, id BIGINT, payload BLOB, PRIMARY KEY (tenant, id))",
                control,
            )
            .await
            .unwrap();
        connection
            .execute_params_controlled(
                "INSERT INTO value_preview_records VALUES (?, ?, ?), (?, ?, ?)",
                &[
                    Value::Text(tenant.into()),
                    Value::Int(7),
                    Value::Bytes(bytes.to_vec()),
                    Value::Bytes(b"other tenant".to_vec()),
                    Value::Int(7),
                    Value::Bytes(vec![0xff; bytes.len()]),
                ],
                control,
            )
            .await
            .unwrap();
    }

    #[cfg(feature = "duckdb")]
    async fn assert_duckdb_value_preview_native(
        connection: &dyn tablepro_core::Connection,
        control: &tablepro_core::OperationControl,
        tenant: &str,
    ) {
        let native = connection
            .query_params_controlled(
                "SELECT typeof(payload), octet_length(payload), substr(hex(payload), 1, 16) FROM value_preview_records WHERE tenant = ? AND id = ?",
                &[Value::Text(tenant.into()), Value::Int(7)],
                control,
            )
            .await
            .unwrap();
        assert_eq!(
            native.rows,
            vec![vec![
                Value::Text("BLOB".into()),
                Value::Int(9000),
                Value::Text("0001020304050607".into()),
            ]]
        );
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn clickhouse_value_query_refetches_the_exact_text_for_a_composite_key() {
        use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, TlsConfig};
        use testcontainers::core::wait::HttpWaitStrategy;
        use testcontainers::core::{IntoContainerPort, WaitFor};
        use testcontainers::runners::AsyncRunner;
        use testcontainers::{GenericImage, ImageExt};

        let container = GenericImage::new("clickhouse/clickhouse-server", "24.8")
            .with_exposed_port(8123.tcp())
            .with_wait_for(WaitFor::http(
                HttpWaitStrategy::new("/ping")
                    .with_port(8123.tcp())
                    .with_expected_status_code(200u16),
            ))
            .with_env_var("CLICKHOUSE_USER", "default")
            .with_env_var("CLICKHOUSE_PASSWORD", "tablepro")
            .with_env_var("CLICKHOUSE_DB", "default")
            .with_env_var("CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT", "1")
            .with_startup_timeout(std::time::Duration::from_secs(180))
            .start()
            .await
            .unwrap();
        let connection = drivers_clickhouse::ClickhouseDriver
            .connect(ConnectOptions {
                host: container.get_host().await.unwrap().to_string(),
                port: container.get_host_port_ipv4(8123).await.unwrap(),
                database: "default".into(),
                username: "default".into(),
                password: secrecy::SecretString::new("tablepro".into()),
                tls: TlsConfig::disabled(),
                ..Default::default()
            })
            .await
            .unwrap();
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
        let tenant = "tenant ' OR 1=1 --";
        let value = "BookiE-clickhouse-value-".repeat(500);
        seed_clickhouse_value_preview(&*connection, &control, tenant, &value).await;
        assert_clickhouse_value_preview_native(&*connection, &control, tenant).await;

        let columns = connection
            .fetch_columns_controlled(None, "value_preview_records", &control)
            .await
            .unwrap();
        assert!(columns[0].primary_key && columns[1].primary_key);
        let target = BrowseTarget {
            driver_id: "clickhouse",
            schema: None,
            table: "value_preview_records",
            columns: &columns,
            filter: &FilterSet::default(),
            hidden_columns: None,
        };
        let query = target
            .value_query(2, &[Value::Text(tenant.into()), Value::Int(7)])
            .unwrap();
        let guarded = guarded_value_refetch(std::sync::Arc::from(connection), "clickhouse", &query, &control).await;
        assert_eq!(guarded.rows, vec![vec![Value::Text(value)]]);
    }

    async fn seed_clickhouse_value_preview(
        connection: &dyn tablepro_core::Connection,
        control: &tablepro_core::OperationControl,
        tenant: &str,
        value: &str,
    ) {
        connection
            .execute_controlled(
                "CREATE TABLE value_preview_records (tenant String, id UInt64, payload String) ENGINE = MergeTree ORDER BY (tenant, id)",
                control,
            )
            .await
            .unwrap();
        connection
            .execute_params_controlled(
                "INSERT INTO value_preview_records VALUES (?, ?, ?), (?, ?, ?)",
                &[
                    Value::Text(tenant.into()),
                    Value::Int(7),
                    Value::Text(value.into()),
                    Value::Text("other tenant".into()),
                    Value::Int(7),
                    Value::Text("distractor".into()),
                ],
                control,
            )
            .await
            .unwrap();
    }

    async fn assert_clickhouse_value_preview_native(
        connection: &dyn tablepro_core::Connection,
        control: &tablepro_core::OperationControl,
        tenant: &str,
    ) {
        let native = connection
            .query_params_controlled(
                "SELECT toTypeName(payload), length(payload), hex(substring(payload, 1, 8)) FROM value_preview_records WHERE tenant = ? AND id = ?",
                &[Value::Text(tenant.into()), Value::Int(7)],
                control,
            )
            .await
            .unwrap();
        assert_eq!(
            native.rows,
            vec![vec![
                Value::Text("String".into()),
                Value::Int(12000),
                Value::Text("426F6F6B69452D63".into()),
            ]]
        );
    }

    async fn insert_mysql_value_preview_rows(
        connection: &dyn tablepro_core::Connection,
        control: &tablepro_core::OperationControl,
        tenant: &[u8],
        bytes: &[u8],
    ) {
        connection
            .execute_controlled(
                "CREATE TABLE value_preview_records (tenant VARBINARY(64), id BIGINT, payload LONGBLOB, PRIMARY KEY (tenant, id))",
                control,
            )
            .await
            .unwrap();
        connection
            .execute_params_controlled(
                "INSERT INTO value_preview_records VALUES (?, ?, ?), (?, ?, ?)",
                &[
                    Value::Bytes(tenant.to_vec()),
                    Value::Int(7),
                    Value::Bytes(bytes.to_vec()),
                    Value::Bytes(b"other tenant".to_vec()),
                    Value::Int(7),
                    Value::Bytes(vec![0xff; bytes.len()]),
                ],
                control,
            )
            .await
            .unwrap();
    }

    async fn assert_mysql_value_preview_native(
        connection: &dyn tablepro_core::Connection,
        control: &tablepro_core::OperationControl,
        tenant: &[u8],
    ) {
        let native_type = connection
            .query_controlled(
                "SELECT DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'value_preview_records' AND COLUMN_NAME = 'payload'",
                control,
            )
            .await
            .unwrap();
        assert_eq!(native_type.rows, vec![vec![Value::Bytes(b"longblob".to_vec())]]);
        let native_value = connection
            .query_params_controlled(
                "SELECT OCTET_LENGTH(payload), HEX(SUBSTRING(payload, 1, 8)) FROM value_preview_records WHERE tenant = ? AND id = ?",
                &[Value::Bytes(tenant.to_vec()), Value::Int(7)],
                control,
            )
            .await
            .unwrap();
        assert_eq!(
            native_value.rows,
            vec![vec![Value::Int(9000), Value::Text("0001020304050607".into())]]
        );
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn postgres_value_query_refetches_by_enum_and_domain_composite_key() {
        use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl};
        use testcontainers::ImageExt;
        use testcontainers::runners::AsyncRunner;
        use testcontainers_modules::postgres::Postgres;

        let container = Postgres::default().with_tag("16-alpine").start().await.unwrap();
        let connection = drivers_postgres::PgDriver
            .connect(ConnectOptions {
                host: container.get_host().await.unwrap().to_string(),
                port: container.get_host_port_ipv4(5432).await.unwrap(),
                database: "postgres".into(),
                username: "postgres".into(),
                password: secrecy::SecretString::new("postgres".into()),
                ..Default::default()
            })
            .await
            .unwrap();
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
        for sql in [
            "CREATE TYPE value_preview_state AS ENUM ('ready')",
            "CREATE DOMAIN value_preview_tenant AS text CHECK (VALUE <> '')",
            "CREATE TABLE value_preview_records (state value_preview_state, tenant value_preview_tenant, payload bytea, PRIMARY KEY (state, tenant))",
            "INSERT INTO value_preview_records VALUES ('ready', 'tenant '' OR 1=1 --', decode(repeat('ab', 9000), 'hex'))",
        ] {
            connection.execute_controlled(sql, &control).await.unwrap();
        }
        let columns = connection
            .fetch_columns_controlled(None, "value_preview_records", &control)
            .await
            .unwrap();
        assert!(columns[0].enum_type.is_some());
        assert!(columns[1].domain_type.is_some());
        let native = connection
            .query_controlled(
                "SELECT pg_typeof(state)::text, state::text, pg_typeof(tenant)::text, tenant::text, octet_length(payload), encode(substring(payload from 1 for 8), 'hex') FROM value_preview_records",
                &control,
            )
            .await
            .unwrap();
        assert_eq!(
            native.rows,
            vec![vec![
                Value::Text("value_preview_state".into()),
                Value::Text("ready".into()),
                Value::Text("value_preview_tenant".into()),
                Value::Text("tenant ' OR 1=1 --".into()),
                Value::Int(9000),
                Value::Text("abababababababab".into()),
            ]]
        );

        let target = BrowseTarget {
            driver_id: "postgres",
            schema: None,
            table: "value_preview_records",
            columns: &columns,
            filter: &FilterSet::default(),
            hidden_columns: None,
        };
        let query = target
            .value_query(
                2,
                &[Value::Text("ready".into()), Value::Text("tenant ' OR 1=1 --".into())],
            )
            .unwrap();
        let fetched = connection
            .query_params_controlled(&query.sql, &query.params, &control)
            .await
            .unwrap();
        assert_eq!(fetched.rows, vec![vec![Value::Bytes(vec![0xab; 9000])]]);
        let guarded = guarded_value_refetch(std::sync::Arc::from(connection), "postgres", &query, &control).await;
        assert_eq!(guarded.rows, vec![vec![Value::Bytes(vec![0xab; 9000])]]);
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn mssql_value_query_refetches_the_exact_blob_for_a_composite_key() {
        use tablepro_core::{ConnectOptions, DatabaseDriver, OperationControl, TlsConfig};
        use testcontainers::runners::AsyncRunner;
        use testcontainers_modules::mssql_server::MssqlServer;

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
        let tenant = b"tenant ' OR 1=1 --".to_vec();
        let bytes: Vec<u8> = (0..9000).map(|index| (index % 256) as u8).collect();
        insert_mssql_value_preview_rows(&*connection, &control, &tenant, &bytes).await;
        assert_mssql_value_preview_native(&*connection, &control).await;

        let columns = connection
            .fetch_columns_controlled(None, "value_preview_records", &control)
            .await
            .unwrap();
        let target = BrowseTarget {
            driver_id: "mssql",
            schema: None,
            table: "value_preview_records",
            columns: &columns,
            filter: &FilterSet::default(),
            hidden_columns: None,
        };
        let query = target.value_query(2, &[Value::Bytes(tenant), Value::Int(7)]).unwrap();
        let fetched = connection
            .query_params_controlled(&query.sql, &query.params, &control)
            .await
            .unwrap();
        assert_eq!(fetched.rows, vec![vec![Value::Bytes(bytes.clone())]]);
        let guarded = guarded_value_refetch(std::sync::Arc::from(connection), "mssql", &query, &control).await;
        assert_eq!(guarded.rows, vec![vec![Value::Bytes(bytes)]]);
    }

    async fn insert_mssql_value_preview_rows(
        connection: &dyn tablepro_core::Connection,
        control: &tablepro_core::OperationControl,
        tenant: &[u8],
        bytes: &[u8],
    ) {
        connection
            .execute_controlled(
                "CREATE TABLE value_preview_records (tenant VARBINARY(64), id BIGINT, payload VARBINARY(MAX), PRIMARY KEY (tenant, id))",
                control,
            )
            .await
            .unwrap();
        connection
            .execute_params_controlled(
                "INSERT INTO value_preview_records VALUES (@P1, @P2, @P3), (@P4, @P5, @P6)",
                &[
                    Value::Bytes(tenant.to_vec()),
                    Value::Int(7),
                    Value::Bytes(bytes.to_vec()),
                    Value::Bytes(b"other tenant".to_vec()),
                    Value::Int(7),
                    Value::Bytes(vec![0xff; bytes.len()]),
                ],
                control,
            )
            .await
            .unwrap();
    }

    async fn assert_mssql_value_preview_native(
        connection: &dyn tablepro_core::Connection,
        control: &tablepro_core::OperationControl,
    ) {
        let native = connection
            .query_controlled(
                "SELECT DATALENGTH(payload), sys.fn_varbintohexstr(SUBSTRING(payload, 1, 8)) FROM value_preview_records WHERE tenant = 0x74656e616e742027204f5220313d31202d2d AND id = 7",
                control,
            )
            .await
            .unwrap();
        assert_eq!(
            native.rows,
            vec![vec![Value::Int(9000), Value::Text("0x0001020304050607".into())]]
        );
    }
}
