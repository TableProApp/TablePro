use aws_config::BehaviorVersion;
use aws_credential_types::{provider::ProvideCredentials, Credentials};
use aws_sigv4::{
    http_request::{sign, SignableBody, SignableRequest, SigningSettings},
    sign::v4::SigningParams,
};
use chrono::{offset::Utc, DateTime};
use http::Request;
use serde::Deserialize;

use crate::{
    base64,
    bson::{doc, spec::BinarySubtype, Binary, Bson, Document},
    client::{
        auth::{
            self,
            sasl::{SaslContinue, SaslResponse, SaslStart},
            AuthMechanism,
            Credential,
        },
        options::ServerApi,
    },
    cmap::Connection,
    error::{Error, Result},
};

const MECH_NAME: &str = "MONGODB-AWS";

/// Performs MONGODB-AWS authentication for a given stream.
pub(super) async fn authenticate_stream(
    conn: &mut Connection,
    credential: &Credential,
    server_api: Option<&ServerApi>,
) -> Result<()> {
    let source = match credential.source.as_deref() {
        Some("$external") | None => "$external",
        Some(..) => {
            return Err(Error::authentication_error(
                MECH_NAME,
                "auth source must be $external",
            ))
        }
    };

    let nonce = auth::generate_nonce_bytes();

    let client_first_payload = doc! {
        "r": Binary { subtype: BinarySubtype::Generic, bytes: nonce.clone().to_vec() },
        // `110` is ASCII for the character `n`, which is required by the spec to indicate that
        // channel binding is not supported.
        "p": 110i32,
    };
    let mut client_first_payload_bytes = vec![];
    client_first_payload.to_writer(&mut client_first_payload_bytes)?;

    let sasl_start = SaslStart::new(
        source.into(),
        AuthMechanism::MongoDbAws,
        client_first_payload_bytes,
        server_api.cloned(),
    );
    let client_first = sasl_start.into_command()?;

    let server_first_response = conn.send_message(client_first).await?;

    let server_first = ServerFirst::parse(server_first_response.auth_response_body(MECH_NAME)?)?;
    server_first.validate(&nonce)?;

    let credentials = get_aws_credentials(credential).await?;
    let date = Utc::now();
    let client_second_payload = compute_aws_sigv4_payload(
        credentials,
        date,
        &server_first.sts_host,
        &server_first.server_nonce,
    )?;

    let mut client_second_payload_bytes = vec![];
    client_second_payload.to_writer(&mut client_second_payload_bytes)?;

    let sasl_continue = SaslContinue::new(
        source.into(),
        server_first.conversation_id.clone(),
        client_second_payload_bytes,
        server_api.cloned(),
    );

    let client_second = sasl_continue.into_command();

    let server_second_response = conn.send_message(client_second).await?;
    let server_second = SaslResponse::parse(
        MECH_NAME,
        server_second_response.auth_response_body(MECH_NAME)?,
    )?;

    if server_second.conversation_id != server_first.conversation_id {
        return Err(Error::invalid_authentication_response(MECH_NAME));
    }

    if !server_second.done {
        return Err(Error::invalid_authentication_response(MECH_NAME));
    }

    Ok(())
}

pub(super) const AWS_SESSION_TOKEN: &str = "AWS_SESSION_TOKEN";

// Find credentials using MongoDB URI or AWS SDK
pub(crate) async fn get_aws_credentials(credential: &Credential) -> Result<Credentials> {
    if let Some(provider) = &credential.aws_credential_provider {
        // If a custom credential provider is given, always use that first
        provider
            .provide_credentials()
            .await
            .map_err(|e| Error::authentication_error(MECH_NAME, &format!("{e}")))
    } else if let Some(creds) = get_aws_credentials_from_uri(credential) {
        // Look for credentials in the MongoDB URI
        Ok(creds)
    } else {
        // If credentials are not provided in the URI, use the AWS SDK to load
        let config = aws_config::load_defaults(BehaviorVersion::latest()).await;
        let creds = config
            .credentials_provider()
            .ok_or_else(|| {
                Error::authentication_error(MECH_NAME, "no credential provider configured")
            })?
            .provide_credentials()
            .await
            .map_err(|e| {
                Error::authentication_error(MECH_NAME, &format!("failed to get creds: {e}"))
            })?;
        Ok(creds)
    }
}

pub(crate) fn get_aws_credentials_from_uri(credential: &Credential) -> Option<Credentials> {
    let (Some(access_key), Some(secret_key)) = (&credential.username, &credential.password) else {
        return None;
    };
    Some(Credentials::new(
        access_key.clone(),
        secret_key.clone(),
        credential
            .mechanism_properties
            .as_ref()
            .and_then(|mp| mp.get_str(AWS_SESSION_TOKEN).ok())
            .map(str::to_owned),
        None,
        "MongoDB URI",
    ))
}

pub fn compute_aws_sigv4_payload(
    creds: Credentials,
    date: DateTime<Utc>,
    host: &str,
    server_nonce: &[u8],
) -> Result<Document> {
    let region = if host == "sts.amazonaws.com" {
        "us-east-1"
    } else {
        let parts: Vec<_> = host.split('.').collect();
        parts.get(1).copied().unwrap_or("us-east-1")
    };

    let url = format!("https://{host}");
    let date_str = date.format("%Y%m%dT%H%M%SZ").to_string();
    let body_str = "Action=GetCallerIdentity&Version=2011-06-15";
    let body_bytes = body_str.as_bytes();
    let nonce_b64 = base64::encode(server_nonce);

    // Create the HTTP request
    let mut builder = Request::builder()
        .method("POST")
        .uri(&url)
        .header("host", host)
        .header("content-type", "application/x-www-form-urlencoded")
        .header("content-length", body_bytes.len())
        .header("x-amz-date", &date_str)
        .header("x-mongodb-gs2-cb-flag", "n")
        .header("x-mongodb-server-nonce", &nonce_b64);

    if let Some(token) = creds.session_token() {
        builder = builder.header("x-amz-security-token", token);
    }

    let mut request = builder.body(body_str.to_string()).map_err(|e| {
        Error::authentication_error(MECH_NAME, &format!("Failed to build request: {e}"))
    })?;

    let service = "sts";
    let identity = creds.into();

    // Set up signing parameters
    let signing_settings = SigningSettings::default();
    let signing_params = SigningParams::builder()
        .identity(&identity)
        .region(region)
        .name(service)
        .time(date.into())
        .settings(signing_settings)
        .build()
        .map_err(|e| {
            Error::authentication_error(MECH_NAME, &format!("Failed to build signing params: {e}"))
        })?
        .into();
    let headers: Result<Vec<_>> = request
        .headers()
        .iter()
        .map(|(k, v)| {
            let v = v.to_str().map_err(|_| {
                Error::authentication_error(
                    MECH_NAME,
                    "Failed to convert header value to valid UTF-8",
                )
            })?;
            Ok((k.as_str(), v))
        })
        .collect();

    let signable_request = SignableRequest::new(
        request.method().as_str(),
        request.uri().to_string(),
        headers?.into_iter(),
        SignableBody::Bytes(request.body().as_bytes()),
    )
    .map_err(|e| {
        Error::authentication_error(MECH_NAME, &format!("Failed to create SignableRequest: {e}"))
    })?;

    let (signing_instructions, _signature) = sign(signable_request, &signing_params)
        .map_err(|e| Error::authentication_error(MECH_NAME, &format!("Signing failed: {e}")))?
        .into_parts();
    signing_instructions.apply_to_request_http1x(&mut request);

    let headers = request.headers();
    let authorization_header = headers
        .get("authorization")
        .ok_or_else(|| Error::authentication_error(MECH_NAME, "Missing authorization header"))?
        .to_str()
        .map_err(|e| {
            Error::authentication_error(MECH_NAME, &format!("Invalid header value: {e}"))
        })?;

    let token_header = headers
        .get("x-amz-security-token")
        .map(|v| {
            v.to_str().map_err(|e| {
                Error::authentication_error(MECH_NAME, &format!("Invalid token header: {e}"))
            })
        })
        .transpose()?;

    let mut payload = doc! {
        "a": authorization_header,
        "d": date_str,
    };

    if let Some(token) = token_header {
        payload.insert("t", token);
    }

    Ok(payload)
}

/// The response from the server to the `saslStart` command in a MONGODB-AWS authentication attempt.
struct ServerFirst {
    conversation_id: Bson,
    server_nonce: Vec<u8>,
    sts_host: String,
    done: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ServerFirstPayload {
    #[serde(rename = "s", with = "serde_bytes")]
    server_nonce: Vec<u8>,

    #[serde(rename = "h")]
    sts_host: String,
}

impl ServerFirst {
    /// Parses the response of the `saslStart` command.
    fn parse(response: Document) -> Result<Self> {
        let SaslResponse {
            conversation_id,
            payload,
            done,
        } = SaslResponse::parse(MECH_NAME, response)?;

        let ServerFirstPayload {
            server_nonce,
            sts_host,
        } = crate::bson_compat::deserialize_from_slice(payload.as_slice())
            .map_err(|_| Error::invalid_authentication_response(MECH_NAME))?;

        Ok(Self {
            conversation_id,
            server_nonce,
            sts_host,
            done,
        })
    }

    /// Ensures that the server sent a valid response to the `saslStart` command.
    fn validate(&self, nonce: &[u8]) -> Result<()> {
        if self.done {
            Err(Error::authentication_error(
                MECH_NAME,
                "handshake terminated early",
            ))
        } else if !self.server_nonce.starts_with(nonce) {
            Err(Error::authentication_error(MECH_NAME, "mismatched nonce"))
        } else if self.server_nonce.len() != 64 {
            Err(Error::authentication_error(
                MECH_NAME,
                "incorrect length server nonce",
            ))
        } else if self.sts_host.is_empty() {
            Err(Error::authentication_error(
                MECH_NAME,
                "sts host must be non-empty",
            ))
        } else if self.sts_host.len() > 255 {
            Err(Error::authentication_error(
                MECH_NAME,
                "sts host cannot be more than 255 bytes",
            ))
        } else if self.sts_host.split('.').any(|s| s.is_empty()) {
            Err(Error::authentication_error(
                MECH_NAME,
                "sts host cannot contain empty labels",
            ))
        } else {
            Ok(())
        }
    }
}
