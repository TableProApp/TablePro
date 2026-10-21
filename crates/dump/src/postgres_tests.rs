use std::os::unix::fs::PermissionsExt;
use std::time::Duration;

use secrecy::SecretString;
use tablepro_core::TlsConfig;

use super::*;

fn options() -> ConnectOptions {
    ConnectOptions {
        auth_source: None,
        host: "db.example".into(),
        port: 5432,
        database: "appdb".into(),
        username: "alice".into(),
        password: SecretString::from("s3cr:et"),
        tls: TlsConfig::default(),
        auth_mode: AuthMode::Password,
        service_endpoint: None,
        local_socket_dir: None,
        local_socket_path: None,
        forwarded_socket_dir: None,
        application_name: None,
        connect_timeout_secs: Some(7),
        read_only: false,
    }
}

fn env_value(env: &[(&'static str, OsString)], key: &str) -> Option<String> {
    env.iter()
        .find(|(name, _)| *name == key)
        .map(|(_, value)| value.to_string_lossy().into_owned())
}

fn fake_tool(dir: &Path, body: &str) -> ClientTool {
    let path = dir.join("pg_dump");
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
    ClientTool {
        name: "pg_dump".into(),
        path,
        major: 18,
    }
}

fn request<'a>(options: &'a ConnectOptions, output: &'a Path) -> PgDumpRequest<'a> {
    PgDumpRequest {
        options,
        output,
        format: DumpFormat::Custom,
        server_major: 17,
    }
}

#[test]
fn a_tunnelled_connection_dials_the_tunnel_and_verifies_the_service_name() {
    let mut options = options();
    options.host = "127.0.0.1".into();
    options.port = 40123;
    options.service_endpoint = Some(("db.example".into(), 5432));
    let env = libpq_env(&options, 18).unwrap();
    assert_eq!(env_value(&env, "PGHOST").as_deref(), Some("db.example"));
    assert_eq!(env_value(&env, "PGHOSTADDR").as_deref(), Some("127.0.0.1"));
    assert_eq!(env_value(&env, "PGPORT").as_deref(), Some("40123"));
    assert_eq!(env_value(&env, "PGSSLMODE").as_deref(), Some("verify-full"));
    assert_eq!(env_value(&env, "PGSSLROOTCERT").as_deref(), Some("system"));
}

#[test]
fn system_certificate_roots_require_libpq_sixteen_but_custom_roots_do_not() {
    let options = options();
    assert!(matches!(libpq_env(&options, 15), Err(DumpError::Unsupported(_))));
    assert!(libpq_env(&options, 16).is_ok());
    let mut custom_root = options;
    custom_root.tls.root_cert = Some("/etc/ssl/custom-ca.pem".into());
    assert!(libpq_env(&custom_root, 15).is_ok());
}

#[test]
fn connections_the_client_tools_cannot_honour_are_refused() {
    let mut forwarded = options();
    forwarded.forwarded_socket_dir = Some("/run/user/1000/bookie".into());
    let mut pinned = options();
    pinned.tls.pinned_fingerprint = Some("ab:cd".into());
    let mut kerberos = options();
    kerberos.auth_mode = AuthMode::Kerberos;
    for options in [forwarded, pinned, kerberos] {
        assert!(matches!(libpq_env(&options, 18), Err(DumpError::Unsupported(_))));
    }
}

#[tokio::test]
async fn the_password_reaches_the_tool_only_through_the_passfile() {
    let dir = tempfile::tempdir().unwrap();
    let tool = fake_tool(
        dir.path(),
        r#"out="${3#--file=}"; { echo "ARGS $*"; env | sort; printf 'PASS '; cat "$PGPASSFILE"; } > "$out""#,
    );
    let options = options();
    let output = dir.path().join("appdb.dump");
    pg_dump(&tool, request(&options, &output), dir.path(), CancellationToken::new())
        .await
        .unwrap();

    let written = std::fs::read_to_string(&output).unwrap();
    let args = written.lines().next().unwrap();
    assert!(args.starts_with("ARGS --no-password --format=custom --file="), "{args}");
    assert!(!args.contains("s3cr"), "{args}");
    assert!(written.contains("PASS *:*:*:*:s3cr\\:et"), "{written}");
    assert!(written.contains("PGUSER=alice"), "{written}");
    assert!(!written.contains("HOME="), "the environment was not cleared: {written}");
    let leftovers: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .filter(|name| name.contains("pgpass") || name.contains(".partial-"))
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
}

#[tokio::test]
async fn a_failed_dump_keeps_the_previous_file_and_redacts_connection_details() {
    let dir = tempfile::tempdir().unwrap();
    let tool = fake_tool(
        dir.path(),
        r#"echo 'connection to "db.example" failed for user "alice" on "appdb"' >&2; touch "${3#--file=}"; exit 1"#,
    );
    let options = options();
    let output = dir.path().join("appdb.dump");
    std::fs::write(&output, "previous backup").unwrap();

    let error = pg_dump(&tool, request(&options, &output), dir.path(), CancellationToken::new())
        .await
        .unwrap_err();

    let DumpError::Failed { status, stderr, .. } = error else {
        panic!("unexpected error: {error:?}");
    };
    assert_eq!(status, Some(1));
    assert!(
        !stderr.contains("db.example") && !stderr.contains("alice") && !stderr.contains("appdb"),
        "{stderr}"
    );
    assert_eq!(std::fs::read_to_string(&output).unwrap(), "previous backup");
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 2);
}

#[tokio::test]
async fn cancelling_stops_the_tool() {
    let dir = tempfile::tempdir().unwrap();
    let tool = fake_tool(dir.path(), "exec sleep 30");
    let options = options();
    let output = dir.path().join("appdb.dump");
    let cancel = CancellationToken::new();
    let trigger = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(100)).await;
        trigger.cancel();
    });

    let outcome = tokio::time::timeout(
        Duration::from_secs(5),
        pg_dump(&tool, request(&options, &output), dir.path(), cancel),
    )
    .await
    .unwrap();

    assert!(matches!(outcome, Err(DumpError::Cancelled)), "{outcome:?}");
    assert!(!output.exists());
}

#[tokio::test]
async fn dropping_a_cancelled_dump_future_removes_its_partial_file() {
    let dir = tempfile::tempdir().unwrap();
    let tool = fake_tool(dir.path(), r#"touch "${3#--file=}"; exec sleep 30"#);
    let options = options();
    let output = dir.path().join("appdb.dump");
    let runtime_dir = dir.path().to_path_buf();
    let task = tokio::spawn(async move {
        pg_dump(
            &tool,
            request(&options, &output),
            &runtime_dir,
            CancellationToken::new(),
        )
        .await
    });
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if std::fs::read_dir(dir.path())
                .unwrap()
                .any(|entry| entry.unwrap().file_name().to_string_lossy().contains(".partial-"))
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    task.abort();
    let _ = task.await;
    assert!(
        !std::fs::read_dir(dir.path())
            .unwrap()
            .any(|entry| { entry.unwrap().file_name().to_string_lossy().contains(".partial-") })
    );
}

#[tokio::test]
async fn a_client_older_than_the_server_does_not_run() {
    let dir = tempfile::tempdir().unwrap();
    let tool = fake_tool(dir.path(), "touch \"${3#--file=}\"");
    let options = options();
    let output = dir.path().join("appdb.dump");
    let mut request = request(&options, &output);
    request.server_major = 19;
    let outcome = pg_dump(&tool, request, dir.path(), CancellationToken::new()).await;
    assert!(matches!(outcome, Err(DumpError::ToolTooOld { .. })), "{outcome:?}");
    assert!(!output.exists());
}

#[tokio::test]
async fn a_restore_runs_in_one_transaction_and_stops_at_the_first_error() {
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("args.log");
    let tool = fake_tool(
        dir.path(),
        &format!(r#"echo "$* PGDATABASE=$PGDATABASE" > "{}""#, log.display()),
    );
    let options = options();
    let input = dir.path().join("appdb.dump");
    std::fs::write(&input, "archive").unwrap();
    let request = PgRestoreRequest {
        options: &options,
        input: &input,
        server_major: 18,
    };

    pg_restore(
        &tool,
        request,
        dir.path(),
        CancellationToken::new(),
        &std::sync::atomic::AtomicBool::new(false),
    )
    .await
    .unwrap();

    let args = std::fs::read_to_string(&log).unwrap();
    assert_eq!(
        args.trim(),
        format!(
            "--no-password --dbname= --clean --if-exists --single-transaction --exit-on-error {} PGDATABASE=appdb",
            input.display()
        )
    );
}

#[tokio::test]
async fn cancelling_a_started_restore_marks_its_outcome_as_dispatched() {
    let dir = tempfile::tempdir().unwrap();
    let tool = fake_tool(dir.path(), "exec sleep 30");
    let options = options();
    let input = dir.path().join("appdb.dump");
    std::fs::write(&input, "archive").unwrap();
    let request = PgRestoreRequest {
        options: &options,
        input: &input,
        server_major: 18,
    };
    let cancel = CancellationToken::new();
    let trigger = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(100)).await;
        trigger.cancel();
    });
    let dispatched = std::sync::atomic::AtomicBool::new(false);

    let outcome = tokio::time::timeout(
        Duration::from_secs(5),
        pg_restore(&tool, request, dir.path(), cancel, &dispatched),
    )
    .await
    .unwrap();

    assert!(matches!(outcome, Err(DumpError::Cancelled)), "{outcome:?}");
    assert!(dispatched.load(std::sync::atomic::Ordering::Acquire));
}

#[tokio::test]
async fn a_restore_client_newer_than_the_server_does_not_run() {
    let dir = tempfile::tempdir().unwrap();
    let marker = dir.path().join("ran");
    let tool = fake_tool(dir.path(), &format!(r#"touch "{}""#, marker.display()));
    let options = options();
    let input = dir.path().join("appdb.dump");
    std::fs::write(&input, "archive").unwrap();
    let request = PgRestoreRequest {
        options: &options,
        input: &input,
        server_major: 16,
    };
    let outcome = pg_restore(
        &tool,
        request,
        dir.path(),
        CancellationToken::new(),
        &std::sync::atomic::AtomicBool::new(false),
    )
    .await;
    assert!(matches!(outcome, Err(DumpError::ToolTooNew { .. })), "{outcome:?}");
    assert!(!marker.exists());
}
