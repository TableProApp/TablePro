use tablepro_core::DriverError;
use tablepro_policy::{
    AuditErrorCategory, AuditEvent, AuditTerminalStatus, AuditTransportClient, AuditTransportOutcome,
};
use uuid::Uuid;

use crate::{SshEnvironment, SshRoute, TransportError};

pub(crate) fn audit_client(ssh: Option<&SshRoute>) -> Option<AuditTransportClient> {
    match ssh? {
        SshRoute::Builtin(_) => Some(AuditTransportClient::BuiltinSsh),
        SshRoute::OpenSsh(_) => Some(AuditTransportClient::SystemOpenSsh),
    }
}

pub(crate) async fn record_transport_attempt<T>(
    environment: &SshEnvironment,
    client: Option<AuditTransportClient>,
    started: std::time::Instant,
    result: &Result<T, TransportError>,
) -> Result<(), TransportError> {
    let (Some(client), Some(context)) = (client, environment.audit.as_ref()) else {
        return Ok(());
    };
    let (outcome, status, category) = classify_transport_result(result);
    let event = AuditEvent::transport_attempt(
        Uuid::new_v4(),
        context.principal.clone(),
        context.connection_id,
        context.connection_name.clone(),
        context.environment,
        context.driver_id.clone(),
        client,
        outcome,
        status,
        category,
        started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64,
    );
    context.sink.record(event).await.map_err(|error| {
        context.state.disable_after_audit_failure();
        TransportError::AuditWriteFailed(error.to_string())
    })
}

fn classify_transport_result<T>(
    result: &Result<T, TransportError>,
) -> (AuditTransportOutcome, AuditTerminalStatus, Option<AuditErrorCategory>) {
    use AuditTerminalStatus as Status;
    use AuditTransportOutcome as Outcome;
    match result {
        Ok(_) => (Outcome::Connected, Status::Succeeded, None),
        Err(TransportError::HostKeyRefused(_)) => (
            Outcome::HostKeyRefused,
            Status::Denied,
            Some(AuditErrorCategory::Authentication),
        ),
        Err(TransportError::HostKeyChanged(_)) => (
            Outcome::HostKeyChanged,
            Status::Denied,
            Some(AuditErrorCategory::Authentication),
        ),
        Err(TransportError::HostKeyRevoked(_)) => (
            Outcome::HostKeyRevoked,
            Status::Denied,
            Some(AuditErrorCategory::Authentication),
        ),
        Err(TransportError::Cancelled) => (
            Outcome::Cancelled,
            Status::Cancelled,
            Some(AuditErrorCategory::Cancelled),
        ),
        Err(TransportError::SshTimeout(_) | TransportError::DatabaseTimeout { .. }) => {
            (Outcome::TimedOut, Status::TimedOut, Some(AuditErrorCategory::Timeout))
        }
        Err(TransportError::Driver(DriverError::Tls(_))) => {
            (Outcome::TlsFailed, Status::Failed, Some(AuditErrorCategory::Tls))
        }
        Err(TransportError::Driver(DriverError::AuthFailed)) => (
            Outcome::AuthenticationFailed,
            Status::Failed,
            Some(AuditErrorCategory::Authentication),
        ),
        Err(_) => (
            Outcome::ConnectionFailed,
            Status::Failed,
            Some(AuditErrorCategory::Connection),
        ),
    }
}
