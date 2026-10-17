//! A system trust store with no certificate authority in it. The case
//! has a binary of its own because it points the whole process's trust
//! store at an empty file.

use tablepro_core::TlsConfig;
use tablepro_net::tls::{TlsSetupError, build_client_config};

#[test]
fn an_empty_trust_store_is_not_a_client_certificate_problem() {
    let dir = tempfile::tempdir().unwrap();
    let empty = dir.path().join("empty.pem");
    std::fs::write(&empty, "").unwrap();
    // SAFETY: the only test in this binary, so no other thread reads the
    // environment while it changes.
    unsafe {
        std::env::set_var("SSL_CERT_FILE", &empty);
        std::env::remove_var("SSL_CERT_DIR");
    }

    let outcome = build_client_config(&TlsConfig::verify_full());

    assert!(matches!(outcome, Err(TlsSetupError::Setup(_))), "{outcome:?}");
}
