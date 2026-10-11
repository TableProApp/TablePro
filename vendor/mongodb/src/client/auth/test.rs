use std::sync::LazyLock;

use crate::{cmap::StreamDescription, options::AuthMechanism};

use super::sasl::SaslStart;

static MECHS: LazyLock<[String; 2]> = LazyLock::new(|| {
    [
        AuthMechanism::ScramSha1.as_str().to_string(),
        AuthMechanism::ScramSha256.as_str().to_string(),
    ]
});

#[test]
fn negotiate_both_scram() {
    let description_both = StreamDescription {
        sasl_supported_mechs: Some(MECHS.to_vec()),
        ..Default::default()
    };
    assert_eq!(
        AuthMechanism::from_stream_description(&description_both),
        AuthMechanism::ScramSha256
    );
}

#[test]
fn negotiate_sha1_only() {
    let description_sha1 = StreamDescription {
        sasl_supported_mechs: Some(MECHS[0..=0].to_vec()),
        ..Default::default()
    };
    assert_eq!(
        AuthMechanism::from_stream_description(&description_sha1),
        AuthMechanism::ScramSha1
    );
}

#[test]
fn negotiate_sha256_only() {
    let description_sha256 = StreamDescription {
        sasl_supported_mechs: Some(MECHS[1..=1].to_vec()),
        ..Default::default()
    };
    assert_eq!(
        AuthMechanism::from_stream_description(&description_sha256),
        AuthMechanism::ScramSha256
    );
}

#[test]
fn negotiate_none() {
    let description_none: StreamDescription = Default::default();
    assert_eq!(
        AuthMechanism::from_stream_description(&description_none),
        AuthMechanism::ScramSha1
    );
}

#[test]
fn negotiate_mangled() {
    let description_mangled = StreamDescription {
        sasl_supported_mechs: Some(["NOT A MECHANISM".to_string(), "OTHER".to_string()].to_vec()),
        ..Default::default()
    };
    assert_eq!(
        AuthMechanism::from_stream_description(&description_mangled),
        AuthMechanism::ScramSha1
    );
}

fn scram_sasl_first_options(mechanism: AuthMechanism) {
    let sasl_first = SaslStart::new(String::new(), mechanism, Vec::new(), None);
    let command = sasl_first.into_command().unwrap();
    let options = match command.body.get_document("options") {
        Ok(options) => options,
        Err(_) => panic!("SaslStart should contain options document"),
    };
    match options.get_bool("skipEmptyExchange") {
        Ok(skip_empty_exchange) => assert!(
            skip_empty_exchange,
            "skipEmptyExchange should be true for SCRAM authentication"
        ),
        Err(_) => panic!("SaslStart options should contain skipEmptyExchange"),
    }
}

#[test]
fn sasl_first_options_specified() {
    scram_sasl_first_options(AuthMechanism::ScramSha1);
    scram_sasl_first_options(AuthMechanism::ScramSha256);
}

#[test]
fn sasl_first_options_not_specified() {
    let sasl_first = SaslStart::new(String::new(), AuthMechanism::MongoDbX509, Vec::new(), None);
    let command = sasl_first.into_command().unwrap();
    assert!(
        command.body.get_document("options").is_err(),
        "SaslStart should not contain options document for X.509 authentication"
    );
}
