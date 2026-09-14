use rustls::{ClientConfig, RootCertStore};

#[test]
fn rustls_resolves_exactly_one_crypto_provider() {
    let config = ClientConfig::builder()
        .with_root_certificates(RootCertStore::empty())
        .with_no_client_auth();
    assert!(!config.crypto_provider().cipher_suites.is_empty());
}
