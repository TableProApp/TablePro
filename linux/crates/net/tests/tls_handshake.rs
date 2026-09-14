use std::error::Error;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;

use hyper_rustls::HttpsConnectorBuilder;
use hyper_util::client::legacy::connect::HttpConnector;
use rcgen::{BasicConstraints, CertificateParams, IsCa, Issuer, KeyPair};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName};
use rustls::server::{ClientHello, ResolvesServerCert};
use rustls::sign::CertifiedKey;
use rustls::{RootCertStore, ServerConfig};
use tablepro_core::{CertificateFileProblem, ClientIdentity, ConfigError, TlsConfig, TlsFailure, TlsMode};
use tablepro_net::tls::{
    TlsSetupError, build_client_config, check_pem_files, classify, client_identity_pem, mysql_ca_bundle_pem,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::{TlsAcceptor, TlsConnector};

type TestResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

struct Pki {
    dir: tempfile::TempDir,
    ca_file: PathBuf,
    ca_der: CertificateDer<'static>,
    server_chain: Vec<CertificateDer<'static>>,
    server_key: PrivateKeyDer<'static>,
}

fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::aws_lc_rs::default_provider())
}

fn private_key(key: &KeyPair) -> PrivateKeyDer<'static> {
    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()))
}

fn pki(server_name: &str) -> TestResult<Pki> {
    let ca_key = KeyPair::generate()?;
    let mut ca_params = CertificateParams::new(Vec::<String>::new())?;
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca_cert = ca_params.self_signed(&ca_key)?;
    let issuer = Issuer::new(ca_params, ca_key);

    let server_key = KeyPair::generate()?;
    let server_cert = CertificateParams::new(vec![server_name.to_owned()])?.signed_by(&server_key, &issuer)?;

    let dir = tempfile::tempdir()?;
    let ca_file = dir.path().join("ca.pem");
    std::fs::write(&ca_file, ca_cert.pem())?;
    Ok(Pki {
        dir,
        ca_file,
        ca_der: ca_cert.der().clone(),
        server_chain: vec![server_cert.der().clone()],
        server_key: private_key(&server_key),
    })
}

fn server_config(chain: Vec<CertificateDer<'static>>, key: PrivateKeyDer<'static>) -> TestResult<Arc<ServerConfig>> {
    Ok(Arc::new(
        ServerConfig::builder_with_provider(provider())
            .with_protocol_versions(rustls::DEFAULT_VERSIONS)?
            .with_no_client_auth()
            .with_single_cert(chain, key)?,
    ))
}

async fn serve_once(config: Arc<ServerConfig>) -> TestResult<SocketAddr> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let address = listener.local_addr()?;
    let acceptor = TlsAcceptor::from(config);
    tokio::spawn(async move {
        if let Ok((stream, _)) = listener.accept().await
            && let Ok(mut tls) = acceptor.accept(stream).await
        {
            let _ = tls.write_all(b"ok").await;
            let _ = tls.shutdown().await;
        }
    });
    Ok(address)
}

async fn handshake(
    tls: &TlsConfig,
    server: Arc<ServerConfig>,
    name: &str,
) -> TestResult<Result<Vec<u8>, std::io::Error>> {
    let address = serve_once(server).await?;
    let client = build_client_config(tls)?.ok_or("TLS is disabled")?;
    let connector = TlsConnector::from(client);
    let stream = TcpStream::connect(address).await?;
    let server_name = ServerName::try_from(name.to_owned())?;
    Ok(async {
        let mut tls = connector.connect(server_name, stream).await?;
        let mut received = Vec::new();
        tls.read_to_end(&mut received).await?;
        Ok(received)
    }
    .await)
}

fn verify_full(ca_file: Option<&Path>) -> TlsConfig {
    TlsConfig {
        ca_file: ca_file.map(Path::to_owned),
        ..TlsConfig::verify_full()
    }
}

#[derive(Debug)]
struct MismatchedKey(Arc<CertifiedKey>);

impl ResolvesServerCert for MismatchedKey {
    fn resolve(&self, _client_hello: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        Some(Arc::clone(&self.0))
    }
}

#[tokio::test]
async fn verify_full_with_extra_root_connects() {
    let pki = pki("db.internal").unwrap();
    let server = server_config(pki.server_chain, pki.server_key).unwrap();
    let received = handshake(&verify_full(Some(&pki.ca_file)), server, "db.internal")
        .await
        .unwrap();
    assert_eq!(received.unwrap(), b"ok");
}

#[tokio::test]
async fn name_mismatch_classified() {
    let pki = pki("db.internal").unwrap();
    let server = server_config(pki.server_chain, pki.server_key).unwrap();
    let error = handshake(&verify_full(Some(&pki.ca_file)), server, "other.internal")
        .await
        .unwrap()
        .unwrap_err();
    assert_eq!(
        classify(&error).map(|(failure, _)| failure),
        Some(TlsFailure::NameMismatch)
    );
}

#[tokio::test]
async fn unknown_issuer_classified_through_io_error() {
    let pki = pki("db.internal").unwrap();
    let server = server_config(pki.server_chain, pki.server_key).unwrap();
    let error = handshake(&verify_full(None), server, "db.internal")
        .await
        .unwrap()
        .unwrap_err();
    assert_eq!(
        classify(&error).map(|(failure, _)| failure),
        Some(TlsFailure::UnknownIssuer)
    );
}

#[test]
fn empty_ca_file_is_no_certificates() {
    let dir = tempfile::tempdir().unwrap();
    let ca_file = dir.path().join("empty.pem");
    std::fs::write(&ca_file, b"").unwrap();
    assert_eq!(
        check_pem_files(&verify_full(Some(&ca_file))),
        Err(ConfigError::CaFile {
            path: ca_file,
            problem: CertificateFileProblem::NoCertificates,
        })
    );
}

#[test]
fn malformed_ca_file_is_invalid_certificate() {
    let dir = tempfile::tempdir().unwrap();
    let ca_file = dir.path().join("junk.pem");
    std::fs::write(
        &ca_file,
        "-----BEGIN CERTIFICATE-----\naGVsbG8gd29ybGQ=\n-----END CERTIFICATE-----\n",
    )
    .unwrap();
    assert!(matches!(
        check_pem_files(&verify_full(Some(&ca_file))),
        Err(ConfigError::CaFile {
            problem: CertificateFileProblem::InvalidCertificate { .. },
            ..
        })
    ));
}

#[tokio::test]
async fn require_accepts_self_signed() {
    let key = KeyPair::generate().unwrap();
    let certificate = CertificateParams::new(vec!["db.internal".to_owned()])
        .unwrap()
        .self_signed(&key)
        .unwrap();
    let server = server_config(vec![certificate.der().clone()], private_key(&key)).unwrap();
    let require = TlsConfig {
        mode: TlsMode::Require,
        ..TlsConfig::disabled()
    };
    let received = handshake(&require, server, "db.internal").await.unwrap();
    assert_eq!(received.unwrap(), b"ok");
}

#[tokio::test]
async fn require_rejects_forged_handshake_signature() {
    let pki = pki("db.internal").unwrap();
    let wrong_key =
        rustls::crypto::aws_lc_rs::sign::any_supported_type(&private_key(&KeyPair::generate().unwrap())).unwrap();
    let forged = CertifiedKey::new(pki.server_chain, wrong_key);
    let server = Arc::new(
        ServerConfig::builder_with_provider(provider())
            .with_protocol_versions(rustls::DEFAULT_VERSIONS)
            .unwrap()
            .with_no_client_auth()
            .with_cert_resolver(Arc::new(MismatchedKey(Arc::new(forged)))),
    );
    let require = TlsConfig {
        mode: TlsMode::Require,
        ..TlsConfig::disabled()
    };
    assert!(handshake(&require, server, "db.internal").await.unwrap().is_err());
}

#[test]
fn mysql_ca_bundle_pem_round_trips_through_root_cert_store() {
    let pki = pki("db.internal").unwrap();
    let bundle = mysql_ca_bundle_pem(&verify_full(Some(&pki.ca_file))).unwrap();
    let certificates: Vec<CertificateDer<'static>> = CertificateDer::pem_slice_iter(&bundle)
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(certificates.last(), Some(&pki.ca_der));
    let mut store = RootCertStore::empty();
    let (added, ignored) = store.add_parsable_certificates(certificates);
    assert!(added >= 1);
    assert_eq!(ignored, 0);
}

#[test]
fn client_identity_pem_requires_both_files() {
    let pki = pki("client").unwrap();
    let certificate = pki.dir.path().join("client.pem");
    let key = pki.dir.path().join("client.key");
    std::fs::write(&certificate, pem_of(&pki.server_chain[0]).unwrap()).unwrap();

    let missing_key = TlsConfig {
        client_identity: Some(ClientIdentity {
            certificate: certificate.clone(),
            key: key.clone(),
        }),
        ..TlsConfig::verify_full()
    };
    assert!(matches!(
        client_identity_pem(&missing_key),
        Err(TlsSetupError::Config(ConfigError::ClientIdentityFile { path, .. })) if path == key
    ));

    let PrivateKeyDer::Pkcs8(pkcs8) = &pki.server_key else {
        panic!("rcgen keys are PKCS #8");
    };
    std::fs::write(&key, pem_label("PRIVATE KEY", pkcs8.secret_pkcs8_der()).unwrap()).unwrap();
    let identity = client_identity_pem(&missing_key).unwrap().unwrap();
    assert!(!identity.certificate.is_empty());
    assert!(!identity.key.is_empty());
}

#[test]
fn check_pem_files_reports_problem_per_file() {
    let pki = pki("client").unwrap();
    let certificate = pki.dir.path().join("client.pem");
    std::fs::write(&certificate, pem_of(&pki.server_chain[0]).unwrap()).unwrap();
    let key_without_key = pki.dir.path().join("not-a-key.pem");
    std::fs::write(&key_without_key, pem_of(&pki.server_chain[0]).unwrap()).unwrap();

    let tls = TlsConfig {
        ca_file: Some(pki.ca_file.clone()),
        client_identity: Some(ClientIdentity {
            certificate,
            key: key_without_key.clone(),
        }),
        ..TlsConfig::verify_full()
    };
    assert_eq!(
        check_pem_files(&tls),
        Err(ConfigError::ClientIdentityFile {
            path: key_without_key,
            problem: CertificateFileProblem::NoPrivateKey,
        })
    );
}

#[tokio::test]
async fn https_connector_unknown_issuer_classified() {
    let pki = pki("127.0.0.1").unwrap();
    let server = server_config(pki.server_chain, pki.server_key).unwrap();
    let address = serve_once(server).await.unwrap();
    let client = build_client_config(&verify_full(None)).unwrap().unwrap();

    let mut http = HttpConnector::new();
    http.enforce_http(false);
    let mut https = HttpsConnectorBuilder::new()
        .with_tls_config((*client).clone())
        .https_only()
        .enable_http1()
        .wrap_connector(http);
    let uri = http::Uri::from_str(&format!("https://{address}")).unwrap();
    let error = tower_service::Service::call(&mut https, uri).await.err().unwrap();
    assert_eq!(
        classify(error.as_ref()).map(|(failure, _)| failure),
        Some(TlsFailure::UnknownIssuer)
    );
}

fn pem_of(certificate: &CertificateDer<'_>) -> TestResult<String> {
    pem_label("CERTIFICATE", certificate.as_ref())
}

fn pem_label(label: &str, der: &[u8]) -> TestResult<String> {
    Ok(pem_rfc7468::encode_string(label, pem_rfc7468::LineEnding::LF, der).map_err(|error| error.to_string())?)
}
