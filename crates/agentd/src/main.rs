//! Headless TablePro agent process. Serves MCP on demand over stdio with a
//! required policy file and no GTK dependency.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;
use clap::{Parser, ValueEnum};
use drivers_clickhouse::ClickhouseDriver;
#[cfg(feature = "duckdb")]
use drivers_duckdb::DuckdbDriver;
use drivers_mongodb::MongodbDriver;
use drivers_mssql::MssqlDriver;
use drivers_mysql::MysqlDriver;
use drivers_postgres::PgDriver;
use drivers_redis::RedisDriver;
use drivers_sqlite::SqliteDriver;
use tablepro_agentd::DaemonProvider;
use tablepro_core::DriverRegistry;
use tablepro_mcp::{McpBridge, TokenPermissions, TokenStore, serve_stdio};
use tablepro_policy::{ApprovalOutcome, ApprovalRequest, ApprovalSink, AuditState, DenyApprovalSink, load_from_path};
use tablepro_storage::{AuditJournal, SavedConnection, load_connections};
use uuid::Uuid;

#[derive(Parser, Debug)]
#[command(name = "bookie-agentd", about = "Headless BookiE MCP agent daemon")]
struct Args {
    /// Path to policy.toml (required).
    #[arg(long)]
    policy: PathBuf,

    /// Approval strategy when policy requires approval.
    #[arg(long, default_value = "deny")]
    approval: ApprovalMode,

    /// Issue a new token and print it, then exit.
    #[arg(long)]
    issue_token: Option<String>,

    #[arg(long, requires = "issue_token")]
    connection: Vec<Uuid>,

    /// Scope for --issue-token. Defaults to the least privilege that is useful.
    #[arg(long, requires = "issue_token", default_value = "read-only")]
    permissions: TokenScope,

    /// Expire the issued token after this many days.
    #[arg(long, requires = "issue_token")]
    expires_days: Option<u32>,

    /// Write the issued token here with owner-only permissions instead of to stdout.
    #[arg(long, requires = "issue_token")]
    token_file: Option<PathBuf>,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum TokenScope {
    ReadOnly,
    ReadWrite,
}

impl From<TokenScope> for TokenPermissions {
    fn from(scope: TokenScope) -> Self {
        match scope {
            TokenScope::ReadOnly => TokenPermissions::ReadOnly,
            TokenScope::ReadWrite => TokenPermissions::ReadWrite,
        }
    }
}

#[derive(Clone, Debug, ValueEnum)]
enum ApprovalMode {
    Deny,
    Tty,
}

struct TtyApprovalSink;

const MAX_TTY_ANSWER_BYTES: u64 = 64;

/// How long a human has to answer one prompt before it is treated as a
/// denial. Without this, one unanswered prompt would block every later
/// tool call forever, since the stdio server processes requests serially.
const APPROVAL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

#[async_trait]
impl ApprovalSink for TtyApprovalSink {
    async fn request(&self, req: ApprovalRequest) -> ApprovalOutcome {
        let prompt = format!(
            "\n[bookie-agentd] approval required\n  connection: {}\n  rule: {}\n  reason: {}\n  sql: {}\nApprove? [y/N] ",
            sanitize_for_terminal(&req.connection_name),
            sanitize_for_terminal(&req.rule),
            sanitize_for_terminal(&req.reason),
            sanitize_for_terminal(&req.sql),
        );
        approval_with_timeout(APPROVAL_TIMEOUT, move || ask_on_controlling_terminal(&prompt)).await
    }
}

async fn approval_with_timeout<F>(timeout: std::time::Duration, work: F) -> ApprovalOutcome
where
    F: FnOnce() -> ApprovalOutcome + Send + 'static,
{
    match tokio::time::timeout(timeout, tokio::task::spawn_blocking(work)).await {
        Ok(joined) => joined.unwrap_or(ApprovalOutcome::Deny),
        Err(_) => {
            tracing::warn!(
                seconds = timeout.as_secs(),
                "approval prompt unanswered; denying (the blocking read on /dev/tty is left running \
                 and will hold one blocking-pool thread until it eventually gets a line or the process exits)"
            );
            ApprovalOutcome::Deny
        }
    }
}

/// Strips control characters (including ESC) from operator-facing text
/// before it is written to the terminal. `req.sql` is attacker-controlled:
/// an agent could otherwise embed ANSI escapes and carriage returns to
/// erase the displayed rule and reason and redraw a fake prompt, so the
/// human approves something other than what they read.
fn sanitize_for_terminal(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_control() { '\u{FFFD}' } else { c })
        .collect()
}

fn ask_on_controlling_terminal(prompt: &str) -> ApprovalOutcome {
    use std::io::{BufRead, BufReader, Read, Write};

    let terminal = match std::fs::OpenOptions::new().read(true).write(true).open("/dev/tty") {
        Ok(terminal) => terminal,
        Err(error) => {
            tracing::warn!(%error, "no controlling terminal for approval; denying");
            return ApprovalOutcome::Deny;
        }
    };
    let mut writer = match terminal.try_clone() {
        Ok(writer) => writer,
        Err(error) => {
            tracing::warn!(%error, "controlling terminal is not writable; denying");
            return ApprovalOutcome::Deny;
        }
    };
    if writer.write_all(prompt.as_bytes()).is_err() || writer.flush().is_err() {
        return ApprovalOutcome::Deny;
    }

    let mut answer = String::new();
    let mut reader = BufReader::new(terminal).take(MAX_TTY_ANSWER_BYTES);
    match reader.read_line(&mut answer) {
        Ok(_) if answer.trim().eq_ignore_ascii_case("y") => ApprovalOutcome::AllowOnce,
        _ => ApprovalOutcome::Deny,
    }
}

fn write_token_file(path: &std::path::Path, plaintext: &str) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    let mut handle = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    handle
        .write_all(plaintext.as_bytes())
        .map_err(|e| format!("{}: {e}", path.display()))?;
    handle.sync_all().map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(())
}

fn validate_token_connections(requested: &[Uuid], saved: &[SavedConnection]) -> Result<(), String> {
    if requested.is_empty() {
        return Err("--issue-token requires at least one --connection UUID".into());
    }
    let saved_ids: HashSet<Uuid> = saved.iter().map(|connection| connection.id).collect();
    if let Some(unknown) = requested.iter().find(|id| !saved_ids.contains(id)) {
        return Err(format!("connection {unknown} not found"));
    }
    Ok(())
}

fn emit_token(plain: &str) -> std::io::Result<()> {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    writeln!(out, "{plain}")?;
    out.flush()
}

fn build_registry() -> DriverRegistry {
    let mut r = DriverRegistry::new();
    r.register(Arc::new(ClickhouseDriver));
    #[cfg(feature = "duckdb")]
    r.register(Arc::new(DuckdbDriver));
    r.register(Arc::new(MongodbDriver));
    r.register(Arc::new(MssqlDriver));
    r.register(Arc::new(MysqlDriver));
    r.register(Arc::new(PgDriver));
    r.register(Arc::new(RedisDriver));
    r.register(Arc::new(SqliteDriver));
    r
}

async fn daemon_provider(
    policy: Arc<tablepro_policy::PolicyConfig>,
    audit: Arc<dyn tablepro_policy::AuditSink>,
    approval: Arc<dyn tablepro_policy::ApprovalSink>,
) -> DaemonProvider {
    let provider = DaemonProvider::new(
        Arc::new(build_registry()),
        policy,
        audit,
        Arc::new(AuditState::new()),
        approval,
    );
    match tablepro_transport::system_openssh(Arc::new(tablepro_ssh::openssh::UnattendedPrompter)).await {
        Ok(openssh) => provider.with_system_openssh(openssh),
        Err(error) => {
            tracing::info!(error = %error, "system OpenSSH connections are unavailable");
            provider
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tablepro_transport::install_crypto_provider();
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();
    tablepro_policy::withhold_panic_messages();

    let args = Args::parse();
    if !args.policy.exists() {
        tracing::error!(path = %args.policy.display(), "policy file not found");
        std::process::exit(2);
    }
    let policy = Arc::new(load_from_path(&args.policy).map_err(|e| e.to_string())?);

    let tokens = Arc::new(TokenStore::open_default().map_err(|e| e.to_string())?);
    if let Some(name) = args.issue_token {
        let saved = load_connections().await?;
        validate_token_connections(&args.connection, &saved)?;
        let expires_at = match args.expires_days {
            Some(days) => Some(
                chrono::Utc::now()
                    .checked_add_signed(chrono::TimeDelta::days(i64::from(days)))
                    .ok_or("--expires-days is too large")?,
            ),
            None => None,
        };
        let (_meta, plain) = tokens.issue(name, args.permissions.into(), args.connection, expires_at)?;
        match args.token_file {
            Some(path) => write_token_file(&path, &plain)?,
            None => emit_token(&plain)?,
        }
        return Ok(());
    }

    let approval: Arc<dyn tablepro_policy::ApprovalSink> = match args.approval {
        ApprovalMode::Deny => Arc::new(DenyApprovalSink),
        ApprovalMode::Tty => Arc::new(TtyApprovalSink),
    };
    let journal =
        AuditJournal::open_default().map_err(|error| format!("required audit journal unavailable: {error}"))?;
    if journal.recovery().has_unresolved_writes() {
        return Err(format!(
            "refusing to start with {} unresolved audit operation(s)",
            journal.recovery().unresolved_operation_ids().len()
        )
        .into());
    }
    let audit: Arc<dyn tablepro_policy::AuditSink> = Arc::new(journal);

    let provider = Arc::new(daemon_provider(policy, audit, approval).await);
    let bridge = Arc::new(McpBridge::new(provider, tokens));

    serve_stdio(bridge).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{AuthMode, Environment};

    #[test]
    fn sanitize_for_terminal_strips_ansi_escapes_and_carriage_returns() {
        // The exact shape of the bypass: erase the displayed rule/reason
        // with CR and an ANSI clear-line, then redraw a fake benign prompt.
        let hostile = "\x1b[2K\rApprove? [y/N] y\x1b[0m";
        let sanitized = sanitize_for_terminal(hostile);
        assert!(!sanitized.contains('\x1b'));
        assert!(!sanitized.contains('\r'));
        assert_eq!(sanitized.chars().filter(|c| *c == '\u{FFFD}').count(), 3);
    }

    #[test]
    fn sanitize_for_terminal_leaves_ordinary_sql_untouched() {
        let sql = "SELECT pan FROM cards WHERE id = 1";
        assert_eq!(sanitize_for_terminal(sql), sql);
    }

    #[tokio::test]
    async fn an_unanswered_prompt_is_denied_after_the_timeout_instead_of_hanging_forever() {
        // The blocking closure outlives the timeout but is still bounded:
        // tokio's runtime waits for spawned blocking work to finish on
        // shutdown, so an unbounded sleep here would hang the test process.
        let started = std::time::Instant::now();
        let outcome = approval_with_timeout(std::time::Duration::from_millis(20), || {
            std::thread::sleep(std::time::Duration::from_millis(300));
            ApprovalOutcome::AllowOnce
        })
        .await;
        assert_eq!(outcome, ApprovalOutcome::Deny);
        assert!(started.elapsed() < std::time::Duration::from_secs(2));
    }

    fn saved_connection(id: Uuid) -> SavedConnection {
        SavedConnection {
            id,
            name: "test".into(),
            driver_id: "postgres".into(),
            host: "localhost".into(),
            port: 5432,
            socket_dir: None,
            database: "postgres".into(),
            username: "postgres".into(),
            use_tls: false,
            tls_mode: None,
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            read_only: false,
            auth_mode: AuthMode::Password,
            environment: Environment::Local,
            ssh: None,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }

    #[test]
    fn an_issued_token_is_read_only_unless_asked_otherwise() {
        let id = Uuid::new_v4();
        let args = Args::parse_from([
            "tablepro-agentd",
            "--policy",
            "policy.toml",
            "--issue-token",
            "agent",
            "--connection",
            &id.to_string(),
        ]);
        assert!(matches!(args.permissions, TokenScope::ReadOnly));
        assert!(args.expires_days.is_none());
        assert!(args.token_file.is_none());

        let elevated = Args::parse_from([
            "tablepro-agentd",
            "--policy",
            "policy.toml",
            "--issue-token",
            "agent",
            "--connection",
            &id.to_string(),
            "--permissions",
            "read-write",
            "--expires-days",
            "7",
        ]);
        assert!(matches!(elevated.permissions, TokenScope::ReadWrite));
        assert_eq!(elevated.expires_days, Some(7));
    }

    #[test]
    fn a_token_file_is_written_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().join("token");
        write_token_file(&path, "secret").unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "token file mode was {mode:o}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "secret");
    }

    #[test]
    fn the_daemon_exposes_no_network_bind_option() {
        for flag in ["--bind", "--host", "--port", "--listen", "--http", "--address"] {
            let parsed = Args::try_parse_from(["tablepro-agentd", "--policy", "policy.toml", flag, "0.0.0.0"]);
            assert!(parsed.is_err(), "{flag} must not be accepted");
        }
        let stdio_only = Args::try_parse_from(["tablepro-agentd", "--policy", "policy.toml"]);
        assert!(stdio_only.is_ok(), "the daemon serves stdio with only a policy path");
    }

    #[test]
    fn token_connections_require_at_least_one_saved_connection() {
        let id = Uuid::new_v4();
        let saved = vec![saved_connection(id)];

        assert!(validate_token_connections(&[], &saved).is_err());
        assert!(validate_token_connections(&[Uuid::new_v4()], &saved).is_err());
        assert!(validate_token_connections(&[id], &saved).is_ok());
    }
}
