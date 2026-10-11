//! Contains the types needed to specify the auth configuration for a
//! [`Client`](struct.Client.html).

#[cfg(feature = "aws-auth")]
pub(crate) mod aws;
#[cfg(feature = "gssapi-auth")]
mod gssapi;
pub mod oidc;
mod plain;
mod sasl;
mod scram;
#[cfg(test)]
mod test;
mod x509;

use std::{borrow::Cow, fmt::Debug, str::FromStr};

use crate::{base64, bson::RawDocumentBuf, bson_compat::cstr, options::ClientOptions};
use derive_where::derive_where;
use hmac::{digest::KeyInit, Mac};
use rand::Rng;
use serde::{Deserialize, Serialize};
use typed_builder::TypedBuilder;

use self::scram::ScramVersion;
#[cfg(feature = "gssapi-auth")]
use crate::options::ResolverConfig;
use crate::{
    bson::Document,
    client::options::ServerApi,
    cmap::{Command, Connection, StreamDescription},
    error::{Error, ErrorKind, Result},
};

const SCRAM_SHA_1_STR: &str = "SCRAM-SHA-1";
const SCRAM_SHA_256_STR: &str = "SCRAM-SHA-256";
const MONGODB_CR_STR: &str = "MONGODB-CR";
const GSSAPI_STR: &str = "GSSAPI";
const MONGODB_AWS_STR: &str = "MONGODB-AWS";
const MONGODB_X509_STR: &str = "MONGODB-X509";
const PLAIN_STR: &str = "PLAIN";
const MONGODB_OIDC_STR: &str = "MONGODB-OIDC";

/// The authentication mechanisms supported by MongoDB.
///
/// Note: not all of these mechanisms are currently supported by the driver.
#[derive(Clone, Deserialize, Serialize, PartialEq, Debug)]
#[non_exhaustive]
pub enum AuthMechanism {
    /// MongoDB Challenge Response nonce and MD5 based authentication system. It is currently
    /// deprecated and will never be supported by this driver.
    MongoDbCr,

    /// The SCRAM-SHA-1 mechanism as defined in [RFC 5802](http://tools.ietf.org/html/rfc5802).
    ///
    /// See the [MongoDB documentation](https://www.mongodb.com/docs/manual/core/security-scram/) for more information.
    ScramSha1,

    /// The SCRAM-SHA-256 mechanism which extends [RFC 5802](http://tools.ietf.org/html/rfc5802) and is formally defined in [RFC 7677](https://tools.ietf.org/html/rfc7677).
    ///
    /// See the [MongoDB documentation](https://www.mongodb.com/docs/manual/core/security-scram/) for more information.
    ScramSha256,

    /// The MONGODB-X509 mechanism based on the usage of X.509 certificates to validate a client
    /// where the distinguished subject name of the client certificate acts as the username.
    ///
    /// See the [MongoDB documentation](https://www.mongodb.com/docs/manual/core/security-x.509/) for more information.
    MongoDbX509,

    /// Kerberos authentication mechanism as defined in [RFC 4752](http://tools.ietf.org/html/rfc4752).
    ///
    /// See the [MongoDB documentation](https://www.mongodb.com/docs/manual/core/kerberos/) for more information.
    #[cfg(feature = "gssapi-auth")]
    Gssapi,

    /// The SASL PLAIN mechanism, as defined in [RFC 4616](), is used in MongoDB to perform LDAP
    /// authentication and cannot be used for any other type of authentication.
    /// Since the credentials are stored outside of MongoDB, the "$external" database must be used
    /// for authentication.
    ///
    /// See the [MongoDB documentation](https://www.mongodb.com/docs/manual/core/security-ldap/#ldap-proxy-authentication) for more information on LDAP authentication.
    Plain,

    /// MONGODB-AWS authenticates using AWS IAM credentials (an access key ID and a secret access
    /// key), temporary AWS IAM credentials obtained from an AWS Security Token Service (STS)
    /// Assume Role request, or temporary AWS IAM credentials assigned to an EC2 instance or ECS
    /// task.
    ///
    /// The driver uses the [AWS SDK](https://github.com/awslabs/aws-sdk-rust) to retrieve AWS
    /// credentials. If you have a shared AWS credentials or config file, then those credentials
    /// will be used by default if AWS authentication environment variables are not set. To
    /// override this behavior, set `AWS_SHARED_CREDENTIALS_FILE=""` in your shell or set the
    /// equivalent environment variable value in your script or application. Alternatively, you
    /// can create an AWS profile specifically for your MongoDB credentials and set the
    /// `AWS_PROFILE` environment variable to that profile name.
    #[cfg(feature = "aws-auth")]
    MongoDbAws,

    /// MONGODB-OIDC authenticates using [OpenID Connect](https://openid.net/developers/specs/) access tokens.
    #[serde(alias = "MONGODB-OIDC")]
    MongoDbOidc,
}

impl AuthMechanism {
    fn from_scram_version(scram: &ScramVersion) -> Self {
        match scram {
            ScramVersion::Sha1 => Self::ScramSha1,
            ScramVersion::Sha256 => Self::ScramSha256,
        }
    }

    pub(crate) fn from_stream_description(description: &StreamDescription) -> AuthMechanism {
        let scram_sha_256_found = description
            .sasl_supported_mechs
            .as_ref()
            .map(|ms| ms.iter().any(|m| m == AuthMechanism::ScramSha256.as_str()))
            .unwrap_or(false);

        if scram_sha_256_found {
            AuthMechanism::ScramSha256
        } else {
            AuthMechanism::ScramSha1
        }
    }

    /// Determines if the provided credentials have the required information to perform
    /// authentication.
    pub fn validate_credential(&self, credential: &Credential) -> Result<()> {
        match self {
            AuthMechanism::ScramSha1 | AuthMechanism::ScramSha256 => {
                if credential.username.is_none() {
                    return Err(ErrorKind::InvalidArgument {
                        message: "No username provided for SCRAM authentication".to_string(),
                    }
                    .into());
                };
                Ok(())
            }
            AuthMechanism::MongoDbX509 => {
                if credential.password.is_some() {
                    return Err(ErrorKind::InvalidArgument {
                        message: "A password cannot be specified with MONGODB-X509".to_string(),
                    }
                    .into());
                }

                if credential.source.as_deref().unwrap_or("$external") != "$external" {
                    return Err(ErrorKind::InvalidArgument {
                        message: "only $external may be specified as an auth source for \
                                  MONGODB-X509"
                            .to_string(),
                    }
                    .into());
                }

                Ok(())
            }
            #[cfg(feature = "gssapi-auth")]
            AuthMechanism::Gssapi => {
                if credential.username.is_none() {
                    return Err(ErrorKind::InvalidArgument {
                        message: "No username provided for GSSAPI authentication".to_string(),
                    }
                    .into());
                }

                if credential.source.as_deref().unwrap_or("$external") != "$external" {
                    return Err(ErrorKind::InvalidArgument {
                        message: "only $external may be specified as an auth source for GSSAPI"
                            .to_string(),
                    }
                    .into());
                }

                Ok(())
            }
            AuthMechanism::Plain => {
                if credential.username.is_none() {
                    return Err(ErrorKind::InvalidArgument {
                        message: "No username provided for PLAIN authentication".to_string(),
                    }
                    .into());
                }

                if credential.username.as_deref() == Some("") {
                    return Err(ErrorKind::InvalidArgument {
                        message: "Username for PLAIN authentication must be non-empty".to_string(),
                    }
                    .into());
                }

                if credential.password.is_none() {
                    return Err(ErrorKind::InvalidArgument {
                        message: "No password provided for PLAIN authentication".to_string(),
                    }
                    .into());
                }

                Ok(())
            }
            #[cfg(feature = "aws-auth")]
            AuthMechanism::MongoDbAws => {
                if credential.username.is_some() || credential.password.is_some() {
                    crate::log_warning!(
                        "URI credentials for MONGODB-AWS are deprecated and will be removed in \
                         4.0."
                    );
                }
                if credential
                    .mechanism_properties
                    .as_ref()
                    .is_some_and(|mp| mp.contains_key(aws::AWS_SESSION_TOKEN))
                {
                    crate::log_warning!(
                        "Auth mechanism {:?} for MONGODB-AWS is deprecated and will be removed in \
                         4.0.",
                        aws::AWS_SESSION_TOKEN
                    );
                }
                if credential.username.is_some() && credential.password.is_none() {
                    return Err(ErrorKind::InvalidArgument {
                        message: "Username cannot be provided without password for MONGODB-AWS \
                                  authentication"
                            .to_string(),
                    }
                    .into());
                }

                Ok(())
            }
            AuthMechanism::MongoDbOidc => oidc::validate_credential(credential),
            _ => Ok(()),
        }
    }

    /// Returns this `AuthMechanism` as a string.
    pub fn as_str(&self) -> &'static str {
        match self {
            AuthMechanism::ScramSha1 => SCRAM_SHA_1_STR,
            AuthMechanism::ScramSha256 => SCRAM_SHA_256_STR,
            AuthMechanism::MongoDbCr => MONGODB_CR_STR,
            AuthMechanism::MongoDbX509 => MONGODB_X509_STR,
            #[cfg(feature = "gssapi-auth")]
            AuthMechanism::Gssapi => GSSAPI_STR,
            AuthMechanism::Plain => PLAIN_STR,
            #[cfg(feature = "aws-auth")]
            AuthMechanism::MongoDbAws => MONGODB_AWS_STR,
            AuthMechanism::MongoDbOidc => MONGODB_OIDC_STR,
        }
    }

    /// Get the default authSource for a given mechanism depending on the database provided in the
    /// connection string.
    pub(crate) fn default_source<'a>(&'a self, uri_db: Option<&'a str>) -> &'a str {
        match self {
            AuthMechanism::ScramSha1 | AuthMechanism::ScramSha256 | AuthMechanism::MongoDbCr => {
                uri_db.unwrap_or("admin")
            }
            AuthMechanism::MongoDbX509 => "$external",
            AuthMechanism::Plain => uri_db.unwrap_or("$external"),
            AuthMechanism::MongoDbOidc => "$external",
            #[cfg(feature = "aws-auth")]
            AuthMechanism::MongoDbAws => "$external",
            #[cfg(feature = "gssapi-auth")]
            AuthMechanism::Gssapi => "$external",
        }
    }

    /// Constructs the first message to be sent to the server as part of the authentication
    /// handshake, which can be used for speculative authentication.
    pub(crate) async fn build_speculative_client_first(
        &self,
        credential: &Credential,
    ) -> Result<Option<ClientFirst>> {
        match self {
            Self::ScramSha1 => {
                let client_first = ScramVersion::Sha1.build_speculative_client_first(credential)?;

                Ok(Some(ClientFirst::Scram(ScramVersion::Sha1, client_first)))
            }
            Self::ScramSha256 => {
                let client_first =
                    ScramVersion::Sha256.build_speculative_client_first(credential)?;

                Ok(Some(ClientFirst::Scram(ScramVersion::Sha256, client_first)))
            }
            Self::MongoDbX509 => Ok(Some(ClientFirst::X509(Box::new(
                x509::build_speculative_client_first(credential)?,
            )))),
            #[cfg(feature = "gssapi-auth")]
            AuthMechanism::Gssapi => Ok(None),
            Self::Plain => Ok(None),
            Self::MongoDbOidc => Ok(oidc::build_speculative_client_first(credential)
                .await
                .map(|comm| ClientFirst::Oidc(Box::new(comm)))),
            #[cfg(feature = "aws-auth")]
            AuthMechanism::MongoDbAws => Ok(None),
            AuthMechanism::MongoDbCr => Err(ErrorKind::Authentication {
                message: "MONGODB-CR is deprecated and not supported by this driver. Use SCRAM \
                          for password-based authentication instead"
                    .into(),
            }
            .into()),
        }
    }

    pub(crate) async fn authenticate_stream(
        &self,
        stream: &mut Connection,
        credential: &Credential,
        opts: &AuthOptions,
    ) -> Result<()> {
        self.validate_credential(credential)?;

        let server_api = opts.server_api.as_ref();
        match self {
            AuthMechanism::ScramSha1 => {
                ScramVersion::Sha1
                    .authenticate_stream(stream, credential, server_api, None)
                    .await
            }
            AuthMechanism::ScramSha256 => {
                ScramVersion::Sha256
                    .authenticate_stream(stream, credential, server_api, None)
                    .await
            }
            AuthMechanism::MongoDbX509 => {
                x509::authenticate_stream(stream, credential, server_api, None).await
            }
            #[cfg(feature = "gssapi-auth")]
            AuthMechanism::Gssapi => {
                gssapi::authenticate_stream(
                    stream,
                    credential,
                    server_api,
                    opts.resolver_config.as_ref(),
                )
                .await
            }
            AuthMechanism::Plain => {
                plain::authenticate_stream(stream, credential, server_api).await
            }
            #[cfg(feature = "aws-auth")]
            AuthMechanism::MongoDbAws => {
                aws::authenticate_stream(stream, credential, server_api).await
            }
            AuthMechanism::MongoDbCr => Err(ErrorKind::Authentication {
                message: "MONGODB-CR is deprecated and not supported by this driver. Use SCRAM \
                          for password-based authentication instead"
                    .into(),
            }
            .into()),
            AuthMechanism::MongoDbOidc => {
                oidc::authenticate_stream(stream, credential, server_api, None).await
            }
        }
    }

    pub(crate) async fn reauthenticate_stream(
        &self,
        stream: &mut Connection,
        credential: &Credential,
        server_api: Option<&ServerApi>,
    ) -> Result<()> {
        self.validate_credential(credential)?;

        match self {
            AuthMechanism::ScramSha1
            | AuthMechanism::ScramSha256
            | AuthMechanism::MongoDbX509
            | AuthMechanism::Plain
            | AuthMechanism::MongoDbCr => Err(ErrorKind::Authentication {
                message: format!(
                    "Reauthentication for authentication mechanism {self:?} is not supported."
                ),
            }
            .into()),
            #[cfg(feature = "gssapi-auth")]
            AuthMechanism::Gssapi => Err(ErrorKind::Authentication {
                message: format!(
                    "Reauthentication for authentication mechanism {self:?} is not supported."
                ),
            }
            .into()),
            #[cfg(feature = "aws-auth")]
            AuthMechanism::MongoDbAws => Err(ErrorKind::Authentication {
                message: format!(
                    "Reauthentication for authentication mechanism {self:?} is not supported."
                ),
            }
            .into()),
            AuthMechanism::MongoDbOidc => {
                oidc::reauthenticate_stream(stream, credential, server_api).await
            }
        }
    }
}

impl FromStr for AuthMechanism {
    type Err = Error;

    fn from_str(str: &str) -> Result<Self> {
        match str {
            SCRAM_SHA_1_STR => Ok(AuthMechanism::ScramSha1),
            SCRAM_SHA_256_STR => Ok(AuthMechanism::ScramSha256),
            MONGODB_CR_STR => Ok(AuthMechanism::MongoDbCr),
            MONGODB_X509_STR => Ok(AuthMechanism::MongoDbX509),
            #[cfg(feature = "gssapi-auth")]
            GSSAPI_STR => Ok(AuthMechanism::Gssapi),
            #[cfg(not(feature = "gssapi-auth"))]
            GSSAPI_STR => Err(ErrorKind::InvalidArgument {
                message: "GSSAPI auth is only supported with the gssapi-auth feature flag".into(),
            }
            .into()),
            PLAIN_STR => Ok(AuthMechanism::Plain),
            MONGODB_OIDC_STR => Ok(AuthMechanism::MongoDbOidc),
            #[cfg(feature = "aws-auth")]
            MONGODB_AWS_STR => Ok(AuthMechanism::MongoDbAws),
            #[cfg(not(feature = "aws-auth"))]
            MONGODB_AWS_STR => Err(ErrorKind::InvalidArgument {
                message: "MONGODB-AWS auth is only supported with the aws-auth feature flag and \
                          the tokio runtime"
                    .into(),
            }
            .into()),

            _ => Err(ErrorKind::InvalidArgument {
                message: format!("invalid mechanism string: {str}"),
            }
            .into()),
        }
    }
}

#[derive(Clone, Debug, Default)]
// Auxiliary information needed by authentication mechanisms.
pub(crate) struct AuthOptions {
    server_api: Option<ServerApi>,
    #[cfg(feature = "gssapi-auth")]
    resolver_config: Option<ResolverConfig>,
}

impl From<&ClientOptions> for AuthOptions {
    fn from(opts: &ClientOptions) -> Self {
        Self {
            server_api: opts.server_api.clone(),
            #[cfg(feature = "gssapi-auth")]
            resolver_config: opts.resolver_config.clone(),
        }
    }
}

/// A struct containing authentication information.
///
/// Some fields (mechanism and source) may be omitted and will either be negotiated or assigned a
/// default value, depending on the values of other fields in the credential.
#[derive(Clone, Default, Deserialize, TypedBuilder)]
#[derive_where(PartialEq)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct Credential {
    /// The username to authenticate with. This applies to all mechanisms but may be omitted when
    /// authenticating via MONGODB-X509.
    pub username: Option<String>,

    /// The database used to authenticate. This applies to all mechanisms and defaults to "admin"
    /// in SCRAM authentication mechanisms, "$external" for GSSAPI and MONGODB-X509, and the
    /// database name or "$external" for PLAIN.
    pub source: Option<String>,

    /// The password to authenticate with. This does not apply to all mechanisms.
    pub password: Option<String>,

    /// Which authentication mechanism to use. If not provided, one will be negotiated with the
    /// server.
    pub mechanism: Option<AuthMechanism>,

    /// Additional properties for the given mechanism.
    ///
    /// If any value in the properties contains a comma, this field must be set directly on
    /// [`ClientOptions`](crate::options::ClientOptions) and cannot be parsed from a connection
    /// string.
    pub mechanism_properties: Option<Document>,

    /// The token callback for OIDC authentication.
    /// ```
    /// use mongodb::{error::Error, Client, options::{ClientOptions, oidc::{Callback, CallbackContext, IdpServerResponse}}};
    /// use std::time::{Duration, Instant};
    /// use futures::future::FutureExt;
    /// async fn do_human_flow(c: CallbackContext) -> Result<(String, Option<Instant>, Option<String>), Error> {
    ///   // Do the human flow here see: https://auth0.com/docs/authenticate/login/oidc-conformant-authentication/oidc-adoption-auth-code-flow
    ///   Ok(("some_access_token".to_string(), Some(Instant::now() + Duration::from_secs(60 * 60 * 12)), Some("some_refresh_token".to_string())))
    /// }
    ///
    /// async fn setup_client() -> Result<Client, Error> {
    ///     let mut opts =
    ///     ClientOptions::parse("mongodb://localhost:27017,localhost:27018/admin?authSource=admin&authMechanism=MONGODB-OIDC").await?;
    ///     opts.credential.as_mut().unwrap().oidc_callback =
    ///         Callback::human(move |c: CallbackContext| {
    ///         async move {
    ///             let (access_token, expires, refresh_token) = do_human_flow(c).await?;
    ///             Ok(IdpServerResponse::builder().access_token(access_token).expires(expires).refresh_token(refresh_token).build())
    ///         }.boxed()
    ///     });
    ///     Client::with_options(opts)
    /// }
    /// ```
    #[serde(skip)]
    #[derive_where(skip)]
    #[builder(default)]
    pub oidc_callback: oidc::Callback,

    /// A custom AWS credential provider.
    #[cfg(feature = "aws-auth")]
    #[serde(skip)]
    #[derive_where(skip)]
    #[builder(default)]
    pub aws_credential_provider: Option<aws_credential_types::provider::SharedCredentialsProvider>,
}

impl Credential {
    pub(crate) fn resolved_source(&self) -> &str {
        self.mechanism
            .as_ref()
            .map(|m| m.default_source(None))
            .unwrap_or("admin")
    }

    /// If the mechanism is missing, append the appropriate mechanism negotiation key-value-pair to
    /// the provided hello or legacy hello command document.
    pub(crate) fn append_needed_mechanism_negotiation(&self, command: &mut RawDocumentBuf) {
        if let (Some(username), None) = (self.username.as_ref(), self.mechanism.as_ref()) {
            command.append(
                cstr!("saslSupportedMechs"),
                format!("{}.{}", self.resolved_source(), username),
            );
        }
    }

    /// Attempts to authenticate a stream according to this credential, returning an error
    /// result on failure. A mechanism may be negotiated if one is not provided as part of the
    /// credential.
    pub(crate) async fn authenticate_stream(
        &self,
        conn: &mut Connection,
        first_round: Option<FirstRound>,
        opts: &AuthOptions,
    ) -> Result<()> {
        let stream_description = conn.stream_description()?;

        // Verify server can authenticate.
        if !stream_description.initial_server_type.can_auth() {
            return Ok(());
        };

        // If speculative authentication returned a response, then short-circuit the authentication
        // logic and use the first round from the handshake.
        if let Some(first_round) = first_round {
            let server_api = opts.server_api.as_ref();
            return match first_round {
                FirstRound::Scram(version, first_round) => {
                    version
                        .authenticate_stream(conn, self, server_api, first_round)
                        .await
                }
                FirstRound::X509(server_first) => {
                    x509::authenticate_stream(conn, self, server_api, server_first).await
                }
                FirstRound::Oidc(server_first) => {
                    oidc::authenticate_stream(conn, self, server_api, server_first).await
                }
            };
        }

        let mechanism = match self.mechanism {
            None => Cow::Owned(AuthMechanism::from_stream_description(stream_description)),
            Some(ref m) => Cow::Borrowed(m),
        };
        // Authenticate according to the chosen mechanism.
        mechanism.authenticate_stream(conn, self, opts).await
    }

    pub(crate) fn serialize<S>(
        credential: &Option<Credential>,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::Serialize;

        #[derive(serde::Serialize)]
        struct CredentialHelper<'a> {
            authsource: Option<&'a String>,
            authmechanism: Option<&'a str>,
            authmechanismproperties: Option<&'a Document>,
        }

        let state = credential.as_ref().map(|c| CredentialHelper {
            authsource: c.source.as_ref(),
            authmechanism: c.mechanism.as_ref().map(|s| s.as_str()),
            authmechanismproperties: c.mechanism_properties.as_ref(),
        });
        state.serialize(serializer)
    }
}

impl Debug for Credential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Credential")
            .field(&"REDACTED".to_string())
            .finish()
    }
}

/// Contains the first client message sent as part of the authentication handshake.
#[derive(Debug)]
pub(crate) enum ClientFirst {
    Scram(ScramVersion, scram::ClientFirst),
    X509(Box<Command>),
    Oidc(Box<Command>),
}

impl ClientFirst {
    pub(crate) fn to_document(&self) -> Result<RawDocumentBuf> {
        Ok(match self {
            Self::Scram(version, client_first) => client_first.to_command(version)?.body,
            Self::X509(command) => command.body.clone(),
            Self::Oidc(command) => command.body.clone(),
        })
    }

    pub(crate) fn into_first_round(self, server_first: Document) -> FirstRound {
        match self {
            Self::Scram(version, client_first) => FirstRound::Scram(
                version,
                scram::FirstRound {
                    client_first,
                    server_first,
                },
            ),
            Self::X509(..) => FirstRound::X509(server_first),
            Self::Oidc(..) => FirstRound::Oidc(server_first),
        }
    }
}

/// Contains the complete first round of the authentication handshake, including the client message
/// and the server response.
#[derive(Debug)]
pub(crate) enum FirstRound {
    Scram(ScramVersion, scram::FirstRound),
    X509(Document),
    Oidc(Document),
}

pub(crate) fn generate_nonce_bytes() -> [u8; 32] {
    rand::rng().random()
}

pub(crate) fn generate_nonce() -> String {
    let result = generate_nonce_bytes();
    base64::encode(result)
}

fn mac<M: Mac + KeyInit>(
    key: &[u8],
    input: &[u8],
    auth_mechanism: &str,
) -> Result<impl AsRef<[u8]>> {
    let mut mac = <M as KeyInit>::new_from_slice(key)
        .map_err(|_| Error::unknown_authentication_error(auth_mechanism))?;
    mac.update(input);
    Ok(mac.finalize().into_bytes())
}
