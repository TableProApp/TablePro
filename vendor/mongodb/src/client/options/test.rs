use std::time::Duration;

use crate::bson::UuidRepresentation;
use pretty_assertions::assert_eq;
use serde::Deserialize;
use std::sync::LazyLock;

use crate::{
    bson::{Bson, Document},
    bson_util::get_int,
    client::options::{ClientOptions, ConnectionString, ServerAddress},
    error::ErrorKind,
    options::Tls,
    test::spec::deserialize_spec_tests,
    Client,
};

static SKIPPED_TESTS: LazyLock<Vec<&'static str>> = LazyLock::new(|| {
    let mut skipped_tests = vec![
        // TODO RUST-1309: unskip this test
        "tlsInsecure is parsed correctly",
        // The driver does not support maxPoolSize=0
        "maxPoolSize=0 does not error",
        #[cfg(not(feature = "cert-key-password"))]
        "Valid tlsCertificateKeyFilePassword is parsed correctly",
        // The driver does not support OCSP (see RUST-361)
        "tlsDisableCertificateRevocationCheck can be set to true",
        "tlsDisableCertificateRevocationCheck can be set to false",
        "tlsDisableOCSPEndpointCheck can be set to true",
        "tlsDisableOCSPEndpointCheck can be set to false",
        // TODO RUST-582: unskip these tests
        "Valid connection and timeout options are parsed correctly",
        "timeoutMS=0",
    ];

    // TODO RUST-1896: unskip this test when openssl-tls is enabled
    // if cfg!(not(feature = "openssl-tls"))
    skipped_tests.push("tlsAllowInvalidHostnames is parsed correctly");
    // }

    if cfg!(not(feature = "zlib-compression")) {
        skipped_tests.push("Valid compression options are parsed correctly");
        skipped_tests.push("Non-numeric zlibCompressionLevel causes a warning");
        skipped_tests.push("Too low zlibCompressionLevel causes a warning");
        skipped_tests.push("Too high zlibCompressionLevel causes a warning");
    }

    if cfg!(not(all(
        feature = "zlib-compression",
        feature = "snappy-compression"
    ))) {
        skipped_tests.push("Multiple compressors are parsed correctly");
    }

    skipped_tests
});

#[derive(Debug, Deserialize)]
struct TestFile {
    pub tests: Vec<TestCase>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TestCase {
    description: String,
    uri: String,
    valid: bool,
    warning: Option<bool>,
    hosts: Option<Vec<ServerAddress>>,
    auth: Option<TestAuth>,
    options: Option<Document>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TestAuth {
    username: Option<String>,
    password: Option<String>,
    db: Option<String>,
}

impl TestAuth {
    fn assert_matches_client_options(&self, options: &ClientOptions, description: &str) {
        let credential = options.credential.as_ref();
        assert_eq!(
            self.username.as_ref(),
            credential.and_then(|c| c.username.as_ref()),
            "{}",
            description
        );
        assert_eq!(
            self.password.as_ref(),
            credential.and_then(|c| c.password.as_ref()),
            "{}",
            description
        );
        assert_eq!(
            self.db.as_ref(),
            options.default_database.as_ref(),
            "{}",
            description
        );
    }
}

async fn run_tests(path: &[&str], skipped_files: &[&str]) {
    let test_files = deserialize_spec_tests::<TestFile>(path, Some(skipped_files))
        .into_iter()
        .map(|(test_file, _)| test_file);

    for test_file in test_files {
        for test_case in test_file.tests {
            if SKIPPED_TESTS.contains(&test_case.description.as_str()) {
                continue;
            }

            let client_options_result = ClientOptions::parse(&test_case.uri).await;

            // The driver does not log warnings for unsupported or incorrect connection string
            // values, so expect an error when warning is set to true.
            if test_case.valid && test_case.warning != Some(true) {
                let client_options = client_options_result.expect(&test_case.description);

                if let Some(ref expected_hosts) = test_case.hosts {
                    assert_eq!(
                        &client_options.hosts, expected_hosts,
                        "{}",
                        test_case.description
                    );
                }

                let mut actual_options = crate::bson_compat::serialize_to_document(&client_options)
                    .expect(&test_case.description);

                if let Some(mode) = actual_options.remove("mode") {
                    actual_options.insert("readPreference", mode);
                }

                if let Some(tags) = actual_options.remove("tagSets") {
                    actual_options.insert("readPreferenceTags", tags);
                }

                #[cfg(any(
                    feature = "zstd-compression",
                    feature = "zlib-compression",
                    feature = "snappy-compression"
                ))]
                if let Some(ref compressors) = client_options.compressors {
                    use crate::options::Compressor;

                    actual_options.insert(
                        "compressors",
                        compressors
                            .iter()
                            .map(Compressor::name)
                            .collect::<Vec<&str>>(),
                    );

                    #[cfg(feature = "zlib-compression")]
                    if let Some(zlib_compression_level) = compressors
                        .iter()
                        .filter_map(|compressor| match compressor {
                            Compressor::Zlib { level } => *level,
                            _ => None,
                        })
                        .next()
                    {
                        actual_options.insert("zlibcompressionlevel", zlib_compression_level);
                    }
                }

                if let Some(ref expected_options) = test_case.options {
                    for (expected_key, expected_value) in expected_options {
                        if expected_value == &Bson::Null {
                            continue;
                        }

                        let (_, actual_value) = actual_options
                            .iter()
                            .find(|(actual_key, _)| actual_key.eq_ignore_ascii_case(expected_key))
                            .unwrap_or_else(|| {
                                panic!(
                                    "{}: parsed options missing {} key",
                                    test_case.description, expected_key
                                )
                            });

                        if let Some(expected_number) = get_int(expected_value) {
                            let actual_number = get_int(actual_value).unwrap_or_else(|| {
                                panic!(
                                    "{}: {expected_key} should be a numeric value but got \
                                     {actual_value}",
                                    test_case.description
                                )
                            });
                            assert_eq!(actual_number, expected_number, "{}", test_case.description);
                        } else {
                            assert_eq!(actual_value, expected_value, "{}", test_case.description);
                        }
                    }
                }

                if let Some(test_auth) = test_case.auth {
                    test_auth
                        .assert_matches_client_options(&client_options, &test_case.description);
                }
            } else {
                let error = client_options_result.expect_err(&test_case.description);
                assert!(
                    matches!(*error.kind, ErrorKind::InvalidArgument { .. }),
                    "{}",
                    &test_case.description
                );
            }
        }
    }
}

#[tokio::test]
async fn run_uri_options_spec_tests() {
    let mut skipped_files = vec!["single-threaded-options.json"];
    if cfg!(not(feature = "socks5-proxy")) {
        skipped_files.push("proxy-options.json");
    }
    if cfg!(not(feature = "gssapi-auth")) {
        skipped_files.push("auth-options.json");
    }
    run_tests(&["uri-options"], &skipped_files).await;
}

#[tokio::test]
async fn run_connection_string_spec_tests() {
    let mut skipped_files = Vec::new();
    if cfg!(not(feature = "gssapi-auth")) {
        skipped_files.push("valid-auth.json");
    }
    if cfg!(not(unix)) {
        skipped_files.push("valid-unix_socket-absolute.json");
        skipped_files.push("valid-unix_socket-relative.json");
        // All the tests in this file use unix domain sockets
        skipped_files.push("valid-db-with-dotted-name.json");
    }

    run_tests(&["connection-string"], &skipped_files).await;
}

#[tokio::test]
async fn uuid_representations() {
    let mut uuid_repr = parse_uri_with_uuid_representation("csharpLegacy")
        .await
        .expect("expected `csharpLegacy` to be a valid argument for `uuidRepresentation`");
    assert_eq!(UuidRepresentation::CSharpLegacy, uuid_repr);

    uuid_repr = parse_uri_with_uuid_representation("javaLegacy")
        .await
        .expect("expected `javaLegacy` to be a valid argument for `uuidRepresentation`");
    assert_eq!(UuidRepresentation::JavaLegacy, uuid_repr);

    uuid_repr = parse_uri_with_uuid_representation("pythonLegacy")
        .await
        .expect("expected `pythonLegacy` to be a valid argument for `uuidRepresentation`");
    assert_eq!(UuidRepresentation::PythonLegacy, uuid_repr);

    let uuid_err = parse_uri_with_uuid_representation("unknownLegacy")
        .await
        .expect_err("expect `unknownLegacy` to be an invalid argument for `uuidRepresentation`");
    assert_eq!(
        "connection string `uuidRepresentation` option can be one of `csharpLegacy`, \
         `javaLegacy`, or `pythonLegacy`. Received invalid `unknownLegacy`"
            .to_string(),
        uuid_err
    );
}

async fn parse_uri_with_uuid_representation(
    uuid_repr: &str,
) -> std::result::Result<UuidRepresentation, String> {
    match ConnectionString::parse(format!(
        "mongodb://localhost:27017/?uuidRepresentation={uuid_repr}"
    ))
    .map_err(|e| e.message().unwrap())
    {
        Ok(cs) => Ok(cs.uuid_representation.unwrap()),
        Err(e) => Err(e),
    }
}

#[test]
fn parse_unknown_options() {
    fn parse_uri(option: &str, suggestion: Option<&str>) {
        match ConnectionString::parse(format!("mongodb://host:27017/?{option}=test"))
            .map_err(|e| *e.kind)
        {
            Ok(_) => panic!("expected error for option {option}"),
            Err(ErrorKind::InvalidArgument { message, .. }) => {
                match suggestion {
                    Some(s) => assert!(message.contains(s)),
                    None => assert!(!message.contains("similar")),
                };
            }
            Err(e) => panic!("expected InvalidArgument, but got {e:?}"),
        }
    }

    parse_uri("invalidoption", None);
    parse_uri("x", None);
    parse_uri("max", None);
    parse_uri("tlstimeout", None);
    parse_uri("waitqueuetimeout", Some("waitqueuetimeoutms"));
    parse_uri("retry_reads", Some("retryreads"));
    parse_uri("poolsize", Some("maxpoolsize"));
    parse_uri("maxstalenessms", Some("maxstalenessseconds"));
}

#[tokio::test]
async fn parse_with_no_default_database() {
    let uri = "mongodb://localhost/";

    assert_eq!(
        ClientOptions::parse(uri).await.unwrap(),
        ClientOptions {
            hosts: vec![ServerAddress::Tcp {
                host: "localhost".to_string(),
                port: None
            }],
            original_uri: Some(uri.into()),
            default_database: None,
            ..Default::default()
        }
    );
}

#[tokio::test]
async fn options_debug_omits_uri() {
    let uri = "mongodb://username:password@localhost/";
    let options = ClientOptions::parse(uri).await.unwrap();

    let debug_output = format!("{options:?}");
    assert!(!debug_output.contains("username"));
    assert!(!debug_output.contains("password"));
    assert!(!debug_output.contains("uri"));
}

#[tokio::test]
async fn options_enforce_min_heartbeat_frequency() {
    let options = ClientOptions::builder()
        .hosts(vec![ServerAddress::parse("a:123").unwrap()])
        .heartbeat_freq(Duration::from_millis(10))
        .build();

    Client::with_options(options).unwrap_err();
}

#[test]
fn invalid_ipv6() {
    // invalid hostname for ipv6
    let address = "[localhost]:27017";
    let error = ServerAddress::parse(address).unwrap_err();
    let message = error.message().unwrap();
    assert!(message.contains("invalid IPv6 address syntax"), "{message}");

    // invalid character after hostname
    let address = "[::1]a";
    let error = ServerAddress::parse(address).unwrap_err();
    let message = error.message().unwrap();
    assert!(
        message.contains("the hostname can only be followed by a port"),
        "{message}"
    );

    // missing bracket
    let address = "[::1:27017";
    let error = ServerAddress::parse(address).unwrap_err();
    let message = error.message().unwrap();
    assert!(message.contains("missing closing ']'"), "{message}");

    // extraneous bracket
    let address = "[::1]:27017]";
    let error = ServerAddress::parse(address).unwrap_err();
    let message = error.message().unwrap();
    assert!(message.contains("the port must be an integer"), "{message}");
}

#[cfg(not(unix))]
#[test]
fn unix_domain_socket_not_allowed() {
    let address = "address.sock";
    let error = ServerAddress::parse(address).unwrap_err();
    let message = error.message().unwrap();
    assert!(
        message.contains("not supported on this platform"),
        "{message}"
    );
}

#[cfg(feature = "cert-key-password")]
#[tokio::test]
async fn tls_cert_key_password_connect() {
    use std::path::PathBuf;

    use crate::bson::doc;

    use crate::{
        options::TlsOptions,
        test::{get_client_options, log_uncaptured},
    };

    use super::Tls;

    let mut options = get_client_options().await.clone();
    if !matches!(options.tls, Some(Tls::Enabled(_))) {
        log_uncaptured("Skipping tls_cert_key_password_connect: tls not enabled");
        return;
    }
    let mut certpath = PathBuf::from(std::env::var("DRIVERS_TOOLS").unwrap());
    certpath.push(".evergreen/x509gen");
    options.tls = Some(Tls::Enabled(
        TlsOptions::builder()
            .ca_file_path(certpath.join("ca.pem"))
            .cert_key_file_path(certpath.join("client-pkcs8-encrypted.pem"))
            .tls_certificate_key_file_password(b"password".to_vec())
            .build(),
    ));
    let client = Client::with_options(options).unwrap();
    client
        .database("test")
        .run_command(doc! {"ping": 1})
        .await
        .unwrap();
}

#[tokio::test]
async fn tls_insecure() {
    let uri = "mongodb://localhost:27017?tls=true&tlsInsecure=true";
    let options = ClientOptions::parse(uri).await.unwrap();
    let Some(Tls::Enabled(tls_options)) = options.tls else {
        panic!("expected tls options to be set");
    };
    assert_eq!(tls_options.allow_invalid_certificates, Some(true));
    #[cfg(feature = "openssl-tls")]
    assert_eq!(tls_options.allow_invalid_hostnames, Some(true));

    let uri = "mongodb://localhost:27017?tls=true&tlsInsecure=false";
    let options = ClientOptions::parse(uri).await.unwrap();
    let Some(Tls::Enabled(tls_options)) = options.tls else {
        panic!("expected tls options to be set");
    };
    assert_eq!(tls_options.allow_invalid_certificates, Some(false));
    #[cfg(feature = "openssl-tls")]
    assert_eq!(tls_options.allow_invalid_hostnames, Some(false));

    let uri = "mongodb://localhost:27017?tls=false&tlsInsecure=true";
    let error = ClientOptions::parse(uri).await.unwrap_err();
    assert!(error.message().unwrap().contains("TLS is disabled"));

    let uri = "mongodb://localhost:27017?tlsInsecure=true&tls=false";
    let error = ClientOptions::parse(uri).await.unwrap_err();
    assert!(error
        .message()
        .unwrap()
        .contains("other TLS options are set"));

    let uri = "mongodb://localhost:27017?tlsInsecure=true&tlsAllowInvalidCertificates=true";
    let error = ClientOptions::parse(uri).await.unwrap_err();
    assert!(error.message().unwrap().contains("cannot set both"));

    let uri = "mongodb://localhost:27017?tlsInsecure=true&tlsAllowInvalidCertificates=false";
    let error = ClientOptions::parse(uri).await.unwrap_err();
    assert!(error.message().unwrap().contains("cannot set both"));

    // TODO RUST-1896: uncomment these tests
    // #[cfg(feature = "openssl-tls")]
    // {
    //     let uri = "mongodb://localhost:27017?tlsInsecure=true&tlsAllowInvalidHostnames=true";
    //     let error = ClientOptions::parse(uri).await.unwrap_err();
    //     assert!(error.message().unwrap().contains("cannot set both"));

    //     let uri = "mongodb://localhost:27017?tlsInsecure=true&tlsAllowInvalidHostnames=false";
    //     let error = ClientOptions::parse(uri).await.unwrap_err();
    //     assert!(error.message().unwrap().contains("cannot set both"));
    // }
}
