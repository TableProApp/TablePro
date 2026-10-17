use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, OperationControl};
use tablepro_dump::{ClientTool, DumpError, DumpFormat, PgDumpRequest, PgRestoreRequest, pg_dump, pg_restore};
use tablepro_policy::{AdministrativeOperation, PolicyGuard};
use tablepro_storage::SavedConnection;
use tablepro_transport::{
    SshEnvironment, SshRoute, TransportError, connect_options_for, open_tool_endpoint, saved_ssh_route,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackupJob {
    Backup { output: PathBuf },
    Restore { input: PathBuf },
}

impl BackupJob {
    fn tool_name(&self) -> &'static str {
        match self {
            Self::Backup { .. } => "pg_dump",
            Self::Restore { .. } => "pg_restore",
        }
    }

    fn operation(&self) -> AdministrativeOperation {
        match self {
            Self::Backup { .. } => AdministrativeOperation::Backup,
            Self::Restore { .. } => AdministrativeOperation::Restore,
        }
    }
}

pub struct SavedBackupContext<'a> {
    pub guard: &'a PolicyGuard,
    pub driver: &'a dyn DatabaseDriver,
    pub saved: &'a SavedConnection,
    pub environment: &'a SshEnvironment,
    pub server_version: Option<&'a str>,
    pub runtime_dir: &'a Path,
}

pub struct BackupContext<'a> {
    pub guard: &'a PolicyGuard,
    pub driver: &'a dyn DatabaseDriver,
    pub tool: &'a ClientTool,
    pub options: ConnectOptions,
    pub ssh: Option<SshRoute>,
    pub environment: &'a SshEnvironment,
    pub server_major: u32,
    pub runtime_dir: &'a Path,
}

pub async fn run_saved_backup_job(
    context: SavedBackupContext<'_>,
    job: BackupJob,
    control: &OperationControl,
) -> Result<(), DriverError> {
    let server_major = postgres_server_major(&context.saved.driver_id, context.server_version)?;
    let tool = ClientTool::locate(job.tool_name(), None).await.map_err(dump_error)?;
    let options = connect_options_for(context.saved).await.map_err(transport_error)?;
    let ssh = saved_ssh_route(context.saved).await.map_err(transport_error)?;
    let context = BackupContext {
        guard: context.guard,
        driver: context.driver,
        tool: &tool,
        options,
        ssh,
        environment: context.environment,
        server_major,
        runtime_dir: context.runtime_dir,
    };
    run_backup_job(context, job, control).await
}

pub async fn run_backup_job(
    context: BackupContext<'_>,
    job: BackupJob,
    control: &OperationControl,
) -> Result<(), DriverError> {
    let token = control.cancellation_token().clone();
    let dispatched = Arc::new(AtomicBool::new(false));
    let restore_dispatched = dispatched.clone();
    let operation = job.operation();
    let work = async {
        let (endpoint, _tunnel) = open_tool_endpoint(
            context.driver,
            context.options,
            context.ssh,
            context.environment,
            token.clone(),
        )
        .await
        .map_err(transport_error)?;
        let outcome = match &job {
            BackupJob::Backup { output } => {
                let request = PgDumpRequest {
                    options: &endpoint,
                    output,
                    format: DumpFormat::Custom,
                    server_major: context.server_major,
                };
                pg_dump(context.tool, request, context.runtime_dir, token.clone()).await
            }
            BackupJob::Restore { input } => {
                let request = PgRestoreRequest {
                    options: &endpoint,
                    input,
                    server_major: context.server_major,
                };
                pg_restore(
                    context.tool,
                    request,
                    context.runtime_dir,
                    token.clone(),
                    restore_dispatched.as_ref(),
                )
                .await
            }
        };
        outcome.map_err(dump_error)
    };
    context
        .guard
        .run_administrative_with_dispatch(operation, control, dispatched, work)
        .await
}

fn postgres_server_major(driver_id: &str, server_version: Option<&str>) -> Result<u32, DriverError> {
    if driver_id != "postgres" {
        return Err(DriverError::Unsupported(
            "backups are available for PostgreSQL connections".into(),
        ));
    }
    server_version
        .and_then(parse_postgres_major)
        .ok_or_else(|| DriverError::Unsupported("the server version is not known yet; reconnect and try again".into()))
}

fn parse_postgres_major(version: &str) -> Option<u32> {
    let number = version.strip_prefix("PostgreSQL ")?.split_whitespace().next()?;
    let digits: String = number.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().ok()
}

fn dump_error(error: DumpError) -> DriverError {
    match error {
        DumpError::Cancelled => DriverError::Cancelled,
        DumpError::Failed { .. } | DumpError::Io(_) => DriverError::Internal(error.to_string()),
        _ => DriverError::Unsupported(error.to_string()),
    }
}

fn transport_error(error: TransportError) -> DriverError {
    match error {
        TransportError::Cancelled => DriverError::Cancelled,
        TransportError::Driver(error) => error,
        error => DriverError::Unsupported(error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_major_version_is_read_from_the_driver_version_text() {
        assert_eq!(
            parse_postgres_major("PostgreSQL 16.4 (Debian 16.4-1.pgdg120+2)"),
            Some(16)
        );
        assert_eq!(parse_postgres_major("PostgreSQL 18beta1"), Some(18));
        assert_eq!(parse_postgres_major("MySQL 8.4.2"), None);
    }

    #[test]
    fn only_postgres_connections_with_a_known_version_can_be_backed_up() {
        assert_eq!(postgres_server_major("postgres", Some("PostgreSQL 17.2")).unwrap(), 17);
        for (driver, version) in [
            ("mysql", Some("PostgreSQL 17.2")),
            ("postgres", None),
            ("postgres", Some("odd")),
        ] {
            assert!(matches!(
                postgres_server_major(driver, version),
                Err(DriverError::Unsupported(_))
            ));
        }
    }

    #[test]
    fn a_cancelled_tool_or_tunnel_is_reported_as_cancelled() {
        assert!(matches!(dump_error(DumpError::Cancelled), DriverError::Cancelled));
        assert!(matches!(
            transport_error(TransportError::Cancelled),
            DriverError::Cancelled
        ));
        assert!(matches!(
            dump_error(DumpError::ToolMissing { tool: "pg_dump".into() }),
            DriverError::Unsupported(_)
        ));
    }
}
