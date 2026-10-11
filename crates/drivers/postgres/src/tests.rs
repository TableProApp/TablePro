use super::*;
use crate::query::undecodable;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

#[test]
fn undecodable_cell_cannot_be_bound_as_null() {
    let params = [Value::Undecodable("NUMERIC".into())];
    assert!(matches!(
        bind_pg_params(sqlx::query(sqlx::AssertSqlSafe("SELECT $1")), &params, &[]),
        Err(DriverError::Unsupported(_))
    ));
}

#[test]
fn server_termination_states_are_disconnections_but_query_cancel_is_not() {
    for sqlstate in ["57P01", "57P02", "57P03", "57P04"] {
        assert!(is_server_disconnect_sqlstate(Some(sqlstate)), "{sqlstate}");
    }
    assert!(!is_server_disconnect_sqlstate(Some("57014")));
    assert!(!is_server_disconnect_sqlstate(Some("23505")));
    assert!(!is_server_disconnect_sqlstate(None));
}

#[test]
fn unexpected_io_eof_is_disconnected_and_connection_refusal_stays_distinct() {
    let eof = sqlx::Error::Io(std::io::Error::new(
        std::io::ErrorKind::UnexpectedEof,
        "server closed the connection",
    ));
    assert!(matches!(map_sqlx_error(eof), DriverError::Disconnected));

    let refused = sqlx::Error::Io(std::io::Error::new(
        std::io::ErrorKind::ConnectionRefused,
        "connection refused",
    ));
    assert!(matches!(map_sqlx_error(refused), DriverError::ConnectionRefused));
}

#[derive(Clone, Default)]
struct CapturedLogs(Arc<Mutex<Vec<u8>>>);

impl CapturedLogs {
    fn text(&self) -> String {
        match self.0.lock() {
            Ok(buffer) => String::from_utf8_lossy(&buffer).into_owned(),
            Err(poisoned) => String::from_utf8_lossy(&poisoned.into_inner()).into_owned(),
        }
    }
}

impl std::io::Write for CapturedLogs {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self.0.lock() {
            Ok(mut buffer) => {
                buffer.extend_from_slice(buf);
                Ok(buf.len())
            }
            Err(_) => Ok(buf.len()),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for CapturedLogs {
    type Writer = Self;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

#[test]
fn an_undecodable_column_is_reported_to_the_logs_with_its_index_and_type() {
    let logs = CapturedLogs::default();
    let subscriber = tracing_subscriber::fmt()
        .with_writer(logs.clone())
        .with_ansi(false)
        .finish();
    let value = tracing::subscriber::with_default(subscriber, || undecodable(3, "MYDOMAIN"));
    assert!(matches!(&value, Value::Undecodable(name) if name == "MYDOMAIN"));
    let text = logs.text();
    assert!(text.contains("WARN"), "{text}");
    assert!(text.contains("column_index=4"), "{text}");
    assert!(text.contains("type_name=\"MYDOMAIN\""), "{text}");
}

#[test]
fn structure_metadata_declarations_match_the_connection_impl() {
    let d = PgDriver;
    let source = include_str!("lib.rs");
    assert!(d.supports_index_metadata());
    assert!(d.supports_foreign_key_metadata());
    assert!(d.supports_view_metadata());
    assert!(source.contains(&["async fn ", "fetch_indexes("].concat()));
    assert!(source.contains(&["async fn ", "fetch_foreign_keys("].concat()));
    assert!(source.contains(&["async fn ", "list_views("].concat()));
}

#[test]
fn map_certificate_failure_returns_tls_error() {
    let err = sqlx::Error::Io(std::io::Error::other(
        "invalid peer certificate: certificate not valid for name \"127.0.0.1\"",
    ));
    let mapped = map_sqlx_error(err);
    assert!(matches!(mapped, DriverError::Tls(detail) if detail.contains("certificate")));
}

#[test]
fn map_plain_io_failure_is_disconnected() {
    let err = sqlx::Error::Io(std::io::Error::other("connection reset by peer"));
    assert!(matches!(map_sqlx_error(err), DriverError::Disconnected));
}

#[test]
fn map_io_refused_returns_connection_refused() {
    let err = sqlx::Error::Io(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));
    assert!(matches!(map_sqlx_error(err), DriverError::ConnectionRefused));
}

#[test]
fn a_pool_startup_timeout_is_not_mapped_as_an_established_disconnect() {
    assert!(matches!(
        map_sqlx_connect_error(sqlx::Error::PoolTimedOut),
        DriverError::ConnectionRefused
    ));
    assert!(matches!(
        map_sqlx_error(sqlx::Error::PoolTimedOut),
        DriverError::Disconnected
    ));
    assert!(matches!(
        map_sqlx_connect_error(sqlx::Error::PoolClosed),
        DriverError::Disconnected
    ));
}

#[derive(Clone, Copy)]
enum HostileScramChallenge {
    ShortNonce,
    NonAsciiNonce,
    ExcessiveIterations,
}

async fn assert_hostile_scram_challenge_rejected(challenge: HostileScramChallenge) {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("fixture listener");
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.expect("client accepted");
        let startup_len = stream.read_i32().await.expect("startup length");
        assert!(startup_len >= 8, "valid PostgreSQL startup frame");
        let mut startup = vec![0; (startup_len - 4) as usize];
        stream.read_exact(&mut startup).await.expect("startup body");

        send_authentication(&mut stream, 10, b"SCRAM-SHA-256\0\0").await;
        let (kind, body) = read_frontend_message(&mut stream).await.expect("SASL initial response");
        assert_eq!(kind, b'p');
        let mechanism_end = body
            .iter()
            .position(|byte| *byte == 0)
            .expect("SASL mechanism terminator");
        assert_eq!(&body[..mechanism_end], b"SCRAM-SHA-256");
        let response_len = i32::from_be_bytes(
            body[mechanism_end + 1..mechanism_end + 5]
                .try_into()
                .expect("SASL response length"),
        );
        let initial = std::str::from_utf8(&body[mechanism_end + 5..mechanism_end + 5 + response_len as usize])
            .expect("SCRAM client first message");
        let client_nonce = initial
            .split(',')
            .find_map(|attribute| attribute.strip_prefix("r="))
            .expect("client nonce");
        let (server_nonce, iterations) = match challenge {
            HostileScramChallenge::ShortNonce => (client_nonce.to_string(), 4096),
            HostileScramChallenge::NonAsciiNonce => (format!("{client_nonce}é"), 4096),
            HostileScramChallenge::ExcessiveIterations => (format!("{client_nonce}fixture"), 100_001),
        };
        let response = format!("r={server_nonce},s=c2FsdA==,i={iterations}");
        send_authentication(&mut stream, 11, response.as_bytes()).await;

        tokio::time::timeout(Duration::from_secs(3), read_frontend_message(&mut stream))
            .await
            .map(|message| message.ok())
            .unwrap_or(None)
    });

    let options = ConnectOptions {
        host: "127.0.0.1".into(),
        port,
        database: "postgres".into(),
        username: "bookie".into(),
        ..Default::default()
    };
    let connect = tokio::time::timeout(Duration::from_secs(5), PgDriver.connect(options)).await;
    assert!(connect.is_ok(), "hostile challenge should be rejected promptly");
    assert!(connect.unwrap().is_err(), "hostile challenge must not authenticate");

    let client_message = server.await.expect("fixture task");
    assert!(
        !matches!(client_message, Some((b'p', _))),
        "client must reject the SCRAM challenge before sending its proof"
    );
}

async fn read_frontend_message(stream: &mut TcpStream) -> std::io::Result<(u8, Vec<u8>)> {
    let kind = stream.read_u8().await?;
    let len = stream.read_i32().await?;
    if len < 4 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "invalid PostgreSQL frame length",
        ));
    }
    let mut body = vec![0; (len - 4) as usize];
    stream.read_exact(&mut body).await?;
    Ok((kind, body))
}

async fn send_authentication(stream: &mut TcpStream, code: i32, payload: &[u8]) {
    stream.write_u8(b'R').await.expect("authentication tag");
    stream
        .write_i32((4 + 4 + payload.len()) as i32)
        .await
        .expect("authentication length");
    stream.write_i32(code).await.expect("authentication code");
    stream.write_all(payload).await.expect("authentication payload");
}

#[tokio::test]
async fn postgres_scram_rejects_short_nonce_before_sending_proof() {
    assert_hostile_scram_challenge_rejected(HostileScramChallenge::ShortNonce).await;
}

#[tokio::test]
async fn postgres_scram_rejects_non_ascii_nonce_before_sending_proof() {
    assert_hostile_scram_challenge_rejected(HostileScramChallenge::NonAsciiNonce).await;
}

#[tokio::test]
async fn postgres_scram_rejects_excessive_iterations_before_sending_proof() {
    assert_hostile_scram_challenge_rejected(HostileScramChallenge::ExcessiveIterations).await;
}

#[test]
fn driver_metadata() {
    let d = PgDriver;
    assert_eq!(d.id(), "postgres");
    assert_eq!(d.default_port(), 5432);
    assert_eq!(d.default_database(), "postgres");
    assert_eq!(d.default_username(), "postgres");
    assert!(d.supports_client_tls_auth());
}

#[test]
fn quote_ident_doubles_embedded_quotes() {
    assert_eq!(quote_ident("users"), "\"users\"");
    assert_eq!(quote_ident("My Table"), "\"My Table\"");
    assert_eq!(
        quote_ident("evil\"; DROP TABLE x; --"),
        "\"evil\"\"; DROP TABLE x; --\""
    );
}

#[test]
fn normalize_pg_default_strips_only_the_cast_on_a_plain_literal() {
    assert_eq!(normalize_pg_default("'hi'::text".into()), "'hi'");
    assert_eq!(normalize_pg_default("''::text".into()), "''");
    assert_eq!(normalize_pg_default("NULL::character varying".into()), "NULL");
    assert_eq!(normalize_pg_default("42::integer".into()), "42");
    assert_eq!(normalize_pg_default("'-1'::integer".into()), "'-1'");
    assert_eq!(normalize_pg_default("'2024-01-01'::date".into()), "'2024-01-01'");
    assert_eq!(
        normalize_pg_default("'2024-01-01 12:00:00'::timestamp without time zone".into()),
        "'2024-01-01 12:00:00'"
    );
    assert_eq!(normalize_pg_default("'it''s'::text".into()), "'it''s'");
    assert_eq!(normalize_pg_default("'{}'::text[]".into()), "'{}'");
}

#[test]
fn normalize_pg_default_keeps_an_expression_whole() {
    assert_eq!(normalize_pg_default("now()".into()), "now()");
    assert_eq!(normalize_pg_default("CURRENT_TIMESTAMP".into()), "CURRENT_TIMESTAMP");
    assert_eq!(normalize_pg_default("gen_random_uuid()".into()), "gen_random_uuid()");
    assert_eq!(normalize_pg_default("lower('X'::text)".into()), "lower('X'::text)");
    assert_eq!(
        normalize_pg_default("(a::int + b)::numeric".into()),
        "(a::int + b)::numeric"
    );
    assert_eq!(
        normalize_pg_default("'a'::text || 'b'::text".into()),
        "'a'::text || 'b'::text"
    );
    assert_eq!(normalize_pg_default("'unbalanced".into()), "'unbalanced");
}
