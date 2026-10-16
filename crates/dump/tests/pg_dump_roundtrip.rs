#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::path::{Path, PathBuf};

use secrecy::SecretString;
use tablepro_core::{ConnectOptions, TlsConfig};
use tablepro_dump::{ClientTool, DumpError, DumpFormat, PgDumpRequest, PgRestoreRequest, pg_dump, pg_restore};
use testcontainers::core::{CmdWaitFor, ExecCommand};
use testcontainers::{ContainerAsync, ImageExt};
use testcontainers_modules::postgres::Postgres;
use testcontainers_modules::testcontainers::runners::AsyncRunner;
use tokio_util::sync::CancellationToken;

const SERVER_MAJOR: u32 = 18;

async fn psql(container: &ContainerAsync<Postgres>, sql: &str) -> String {
    let mut exec = container
        .exec(
            ExecCommand::new(["psql", "-v", "ON_ERROR_STOP=1", "-tA", "-U", "postgres", "-c", sql])
                .with_cmd_ready_condition(CmdWaitFor::exit_code(0)),
        )
        .await
        .expect("psql");
    String::from_utf8(exec.stdout_to_vec().await.expect("psql output")).unwrap()
}

async fn seeded_postgres() -> (ContainerAsync<Postgres>, ConnectOptions) {
    let container = Postgres::default()
        .with_tag("18-alpine")
        .start()
        .await
        .expect("start postgres container");
    psql(
        &container,
        "CREATE TABLE items (id int PRIMARY KEY, name text); \
         INSERT INTO items VALUES (1, 'plain'), (2, 'colon: and ''quote''');",
    )
    .await;
    let options = ConnectOptions {
        host: container.get_host().await.expect("host").to_string(),
        port: container.get_host_port_ipv4(5432).await.expect("port"),
        database: "postgres".into(),
        username: "postgres".into(),
        password: SecretString::from("postgres"),
        tls: TlsConfig::disabled(),
        ..Default::default()
    };
    (container, options)
}

async fn client_tool(name: &str, variable: &str) -> ClientTool {
    let configured = std::env::var_os(variable).map(PathBuf::from);
    ClientTool::locate(name, configured.as_deref())
        .await
        .unwrap_or_else(|error| panic!("{name} from {variable} or the host: {error}"))
}

async fn dump(options: &ConnectOptions, output: &Path, format: DumpFormat) -> Result<(), DumpError> {
    let tool = client_tool("pg_dump", "TABLEPRO_TEST_PG_DUMP").await;
    let request = PgDumpRequest {
        options,
        output,
        format,
        server_major: SERVER_MAJOR,
    };
    pg_dump(&tool, request, output.parent().unwrap(), CancellationToken::new()).await
}

#[tokio::test]
#[ignore = "requires Docker; run scripts/test-pg-dump.sh"]
async fn pg_dump_writes_the_schema_and_rows_of_a_real_database() {
    let (_container, options) = seeded_postgres().await;
    let dir = tempfile::tempdir().unwrap();
    let output = dir.path().join("postgres.sql");

    dump(&options, &output, DumpFormat::Plain).await.expect("dump");

    let text = std::fs::read_to_string(&output).unwrap();
    assert!(text.contains("CREATE TABLE public.items"), "{text}");
    assert!(text.contains("colon: and 'quote'"), "{text}");
}

#[tokio::test]
#[ignore = "requires Docker; run scripts/test-pg-dump.sh"]
async fn a_wrong_password_fails_without_leaving_a_file() {
    let (_container, mut options) = seeded_postgres().await;
    options.password = SecretString::from("wrong");
    let dir = tempfile::tempdir().unwrap();
    let output = dir.path().join("postgres.sql");

    let error = dump(&options, &output, DumpFormat::Plain).await.unwrap_err();

    let DumpError::Failed { stderr, .. } = error else {
        panic!("unexpected error: {error:?}");
    };
    assert!(!stderr.contains("wrong"), "{stderr}");
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
}

#[tokio::test]
#[ignore = "requires Docker; run scripts/test-pg-dump.sh"]
async fn pg_restore_brings_back_the_dumped_rows() {
    let (container, options) = seeded_postgres().await;
    let dir = tempfile::tempdir().unwrap();
    let archive = dir.path().join("postgres.dump");
    dump(&options, &archive, DumpFormat::Custom).await.expect("dump");
    psql(
        &container,
        "DELETE FROM items WHERE id = 2; INSERT INTO items VALUES (9, 'later');",
    )
    .await;

    let tool = client_tool("pg_restore", "TABLEPRO_TEST_PG_RESTORE").await;
    let request = PgRestoreRequest {
        options: &options,
        input: &archive,
        server_major: SERVER_MAJOR,
    };
    pg_restore(&tool, request, dir.path(), CancellationToken::new())
        .await
        .expect("restore");

    let rows = psql(
        &container,
        "SELECT string_agg(id || '=' || name, ';' ORDER BY id) FROM items",
    )
    .await;
    assert_eq!(rows.trim(), "1=plain;2=colon: and 'quote'");
}
