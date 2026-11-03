//! Integrated login through SSPI against a SQL Server on this Windows
//! machine, which `tests/windows/sql-server.ps1` installs and gives a
//! self-signed certificate, exported to the PEM file
//! `TABLEPRO_TEST_MSSQL_WINDOWS_CA` names. The machine is in no domain,
//! so SSPI signs in with NTLM.

use std::path::PathBuf;
use std::sync::Arc;

use tablepro_core::dialect::BindTarget;
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{
    Connection, Credentials, DriverError, ReadStatement, RowLimit, TlsConfig, TlsFailure, TlsMode, Value,
    WorkspaceSettings,
};
use tablepro_test_support::conformance::test_liveness;

use crate::support::{CALL, Events, columns, dbo, dial, direct, options_over, rows, setup, statement, within, write};

const HOST: &str = "localhost";
const PORT: u16 = 1433;
const CA: &str = "TABLEPRO_TEST_MSSQL_WINDOWS_CA";
const LINK: &str = "SELECT c.auth_scheme, CONVERT(nvarchar(20), CAST(c.protocol_version AS varbinary(4)), 1), \
     c.encrypt_option, SUSER_SNAME() FROM sys.dm_exec_connections c WHERE c.session_id = @@SPID";

struct Link {
    auth_scheme: String,
    protocol: String,
    encrypted: String,
    login: String,
}

fn checked(mode: TlsMode) -> TlsConfig {
    let ca = std::env::var_os(CA).expect("the server certificate's PEM file");
    TlsConfig {
        mode,
        ca_file: Some(PathBuf::from(ca)),
        client_identity: None,
        server_name: None,
    }
}

async fn open(tls: TlsConfig) -> Result<Arc<dyn Connection>, DriverError> {
    let liveness = test_liveness();
    dial(options_over(
        direct(HOST, PORT, &liveness),
        Credentials::Integrated,
        tls,
        WorkspaceSettings::workspace(false),
        liveness,
    ))
    .await
}

async fn link(connection: &dyn Connection) -> Link {
    let row = rows(connection, LINK).await.remove(0);
    let text = |value: &Value| match value {
        Value::Text(text) => text.clone(),
        other => format!("not text: {other:?}"),
    };
    Link {
        auth_scheme: text(&row[0]),
        protocol: text(&row[1]),
        encrypted: text(&row[2]),
        login: text(&row[3]),
    }
}

async fn signs_in(mode: TlsMode, protocol: &str) {
    let connection = open(checked(mode)).await.expect("an integrated login");
    let version: [u32; 4] = connection
        .server_info()
        .version
        .split('.')
        .map(|part| part.parse().expect("a numeric SQL Server version"))
        .collect::<Vec<_>>()
        .try_into()
        .expect("four SQL Server version parts");
    assert!(
        version >= [16, 0, 4003, 1],
        "Strict RPC needs SQL Server 2022 CU1: {version:?}"
    );

    let link = link(connection.as_ref()).await;

    assert!(
        matches!(link.auth_scheme.as_str(), "NTLM" | "KERBEROS"),
        "{}",
        link.auth_scheme
    );
    assert_eq!(link.protocol, protocol);
    assert_eq!(link.encrypted, "TRUE");
    assert!(link.login.contains('\\'), "a Windows account, not {}", link.login);
    workspace_round_trip(connection.as_ref()).await;
    connection.close().await.expect("a close");
}

async fn workspace_round_trip(connection: &dyn Connection) {
    let name = format!("rpc_{}", uuid::Uuid::new_v4().simple());
    let table = dbo(&name);
    let dialect = connection.dialect();
    let qualified = dialect.qualify(&table);
    setup(
        connection,
        &[&format!(
            "CREATE TABLE {qualified} (label nvarchar(max), amount decimal(20,4), payload varbinary(max))"
        )],
    )
    .await;
    let columns = columns(connection, &table).await;
    let text = "🙂Zoë'; DROP TABLE ignored; --".repeat(300);
    let values = vec![
        Value::Text(text),
        Value::Decimal("1234567890123456.1234".parse().expect("a decimal")),
        Value::Null,
    ];
    let mut insert = StatementBuilder::new();
    insert.push_sql(&format!("INSERT INTO {qualified} VALUES ("));
    for (index, (column, value)) in columns.iter().zip(&values).enumerate() {
        if index > 0 {
            insert.push_sql(", ");
        }
        insert
            .push_value(dialect.as_ref(), value.clone(), BindTarget::Column(column))
            .expect("a bound value");
    }
    insert.push_sql(")");
    let report = write(connection, vec![insert.finish()])
        .await
        .expect("a parameterized write");
    assert_eq!(report.rows_affected, vec![Some(1)]);

    let mut select = StatementBuilder::new();
    select.push_sql(&format!(
        "SELECT label, amount, payload FROM {qualified} WHERE label = "
    ));
    select
        .push_value(dialect.as_ref(), values[0].clone(), BindTarget::Column(&columns[0]))
        .expect("a bound filter");
    let select = select.finish();
    let read = connection
        .query_bound(&select, RowLimit::EDITOR_DEFAULT, within(CALL))
        .await
        .expect("a parameterized read");
    assert_eq!(read.rows, vec![values.clone()]);
    assert_eq!(
        connection
            .count_rows(
                &statement(&format!("SELECT COUNT_BIG(*) FROM {qualified}")),
                within(CALL)
            )
            .await
            .expect("a count"),
        1
    );
    let events = Events::default();
    connection
        .stream_read(
            &ReadStatement::Generated(select),
            Box::new(events.clone()),
            within(CALL),
        )
        .await
        .expect("a streamed read");
    assert_eq!(events.rows(), vec![values]);
    setup(connection, &[&format!("DROP TABLE {qualified}")]).await;
}

/// Run before the server is set to Force Strict Encryption.
mod sspi {
    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires a SQL Server on this Windows machine"]
    async fn integrated_login_over_tds_7() {
        signs_in(TlsMode::VerifyFull, "0x74000004").await;
        let connection = open(checked(TlsMode::VerifyFull)).await.expect("an integrated login");
        let read = rows(connection.as_ref(), "SELECT SUSER_SNAME()").await;
        assert!(
            matches!(&read[0][0], Value::Text(login) if login.contains('\\')),
            "{read:?}"
        );
        connection.close().await.expect("a close");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires a SQL Server on this Windows machine"]
    async fn integrated_login_over_strict_tls() {
        signs_in(TlsMode::Strict, "0x08000000").await;
    }
}

/// Run after the server is set to Force Strict Encryption.
mod force_strict {
    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires a SQL Server on this Windows machine"]
    async fn tds_7_is_refused_and_strict_signs_in() {
        let refused = open(checked(TlsMode::VerifyFull)).await;

        assert!(
            matches!(
                refused,
                Err(DriverError::Tls {
                    failure: TlsFailure::ServerRequiresStrict,
                    ..
                })
            ),
            "{:?}",
            refused.err()
        );
        signs_in(TlsMode::Strict, "0x08000000").await;
    }
}
