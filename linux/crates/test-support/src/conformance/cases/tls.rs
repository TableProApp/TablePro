//! The TLS suite: what a driver does against a server that accepts only
//! TLS, with trust and names right and wrong.

use std::path::Path;
use std::sync::Arc;

use tablepro_core::{
    ConnectOptions, Connection, DriverError, ErrorCategory, ServerNameOverride, TlsConfig, TlsFailure, TlsMode,
};

use crate::conformance::support::{dial, expect, unexpected, within};
use crate::conformance::{ClientIdentityEngine, ConformanceFailure, TlsConformanceEngine, test_liveness};

const ISSUING_CASE: &str = "verify_full_with_issuing_ca_connects";
const UNRELATED_CASE: &str = "verify_full_with_unrelated_ca_reports_unknown_issuer";
const NAME_CASE: &str = "verify_full_with_wrong_server_name_reports_name_mismatch";
const REQUIRE_CASE: &str = "require_connects_without_ca";
const DISABLE_CASE: &str = "disable_against_tls_only_server_is_refused";
const IDENTITY_CASE: &str = "client_identity_is_required_by_the_server";
const FLAGS_CASE: &str = "tls_suite_flags_match_driver_capabilities";

/// Full verification against `ca`. The served name goes in as the server
/// name only where the driver accepts one on a direct route; elsewhere
/// the engine already targets a name on the certificate.
fn verified<E: TlsConformanceEngine>(engine: &E, ca: &Path) -> TlsConfig {
    let overridable = E::driver()
        .capabilities()
        .tls
        .is_some_and(|tls| tls.server_name_override == ServerNameOverride::AnyRoute);
    TlsConfig {
        mode: TlsMode::VerifyFull,
        ca_file: Some(ca.to_owned()),
        client_identity: None,
        server_name: overridable.then(|| engine.served_name().to_owned()),
    }
}

async fn open<E: TlsConformanceEngine>(
    case: &'static str,
    options: ConnectOptions,
) -> Result<Result<Arc<dyn Connection>, DriverError>, ConformanceFailure> {
    dial(case, E::driver(), options).await
}

/// Connect, prove the session answers, and close it.
async fn connects<E: TlsConformanceEngine>(
    case: &'static str,
    options: ConnectOptions,
) -> Result<(), ConformanceFailure> {
    let connection = open::<E>(case, options).await?;
    let connection = connection.map_err(|error| unexpected(case, format!("the connect failed: {error:?}")))?;
    connection.probe(within(test_liveness().probe_timeout)).await?;
    connection.close().await?;
    Ok(())
}

fn tls_failure(outcome: &Result<Arc<dyn Connection>, DriverError>) -> Option<TlsFailure> {
    match outcome {
        Err(DriverError::Tls { failure, .. }) => Some(*failure),
        _ => None,
    }
}

fn describe(outcome: &Result<Arc<dyn Connection>, DriverError>) -> String {
    match outcome {
        Ok(_) => "a connection".to_owned(),
        Err(error) => format!("{error:?}"),
    }
}

/// TLS case 1.
pub async fn verify_full_with_issuing_ca_connects<E: TlsConformanceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let tls = verified(&engine, engine.ca_file());
    connects::<E>(ISSUING_CASE, engine.connect_options(tls)).await
}

/// TLS case 2.
pub async fn verify_full_with_unrelated_ca_reports_unknown_issuer<E: TlsConformanceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let tls = verified(&engine, engine.unrelated_ca_file());
    let outcome = open::<E>(UNRELATED_CASE, engine.connect_options(tls)).await?;
    expect(
        UNRELATED_CASE,
        tls_failure(&outcome) == Some(TlsFailure::UnknownIssuer),
        || format!("trusting an unrelated CA gave {}", describe(&outcome)),
    )
}

/// TLS case 3.
pub async fn verify_full_with_wrong_server_name_reports_name_mismatch<E: TlsConformanceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let tls = verified(&engine, engine.ca_file());
    let outcome = open::<E>(NAME_CASE, engine.name_mismatch_connect_options(tls)).await?;
    expect(
        NAME_CASE,
        tls_failure(&outcome) == Some(TlsFailure::NameMismatch),
        || format!("a name the certificate does not carry gave {}", describe(&outcome)),
    )
}

/// TLS case 4.
pub async fn require_connects_without_ca<E: TlsConformanceEngine>(engine: E) -> Result<(), ConformanceFailure> {
    let tls = TlsConfig {
        mode: TlsMode::Require,
        ca_file: None,
        client_identity: None,
        server_name: None,
    };
    connects::<E>(REQUIRE_CASE, engine.connect_options(tls)).await
}

/// TLS case 5.
pub async fn disable_against_tls_only_server_is_refused<E: TlsConformanceEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let expected = engine.plaintext_rejection_category();
    let outcome = open::<E>(DISABLE_CASE, engine.connect_options(TlsConfig::disabled())).await?;
    let refused = matches!(&outcome, Err(error) if error.category() == expected);
    expect(DISABLE_CASE, refused, || {
        format!("a plaintext connect gave {}, not {expected:?}", describe(&outcome))
    })
}

/// TLS case 6: the certificate principal gets in with its certificate
/// and is refused without it.
pub async fn client_identity_is_required_by_the_server<E: ClientIdentityEngine>(
    engine: E,
) -> Result<(), ConformanceFailure> {
    let with_identity = TlsConfig {
        client_identity: Some(engine.client_identity()),
        ..verified(&engine, engine.ca_file())
    };
    connects::<E>(IDENTITY_CASE, engine.certificate_connect_options(with_identity)).await?;

    let without = verified(&engine, engine.ca_file());
    let outcome = open::<E>(IDENTITY_CASE, engine.certificate_connect_options(without)).await?;
    let refused = matches!(
        &outcome,
        Err(error) if matches!(error.category(), ErrorCategory::Authentication | ErrorCategory::Tls)
    );
    expect(IDENTITY_CASE, refused, || {
        format!(
            "the certificate principal without its certificate gave {}",
            describe(&outcome)
        )
    })
}

/// The suite's `client_identity` flag agrees with the driver's TLS
/// capabilities, and the driver has TLS at all.
pub fn tls_suite_flags_match_driver_capabilities<E: TlsConformanceEngine>(
    client_identity: bool,
) -> Result<(), ConformanceFailure> {
    let declared = E::driver().capabilities().tls.map(|tls| tls.client_identity);
    expect(FLAGS_CASE, declared == Some(client_identity), || {
        format!("the suite says client_identity {client_identity}, the driver's TLS capabilities say {declared:?}")
    })
}
