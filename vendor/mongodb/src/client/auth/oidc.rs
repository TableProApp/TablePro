//! Contains the functionality for [`OIDC`](https://openid.net/developers/how-connect-works/) authorization and authentication.
use serde::Deserialize;
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;
use typed_builder::TypedBuilder;

use crate::{
    bson::{doc, rawdoc, spec::BinarySubtype, Binary, Document},
    bson_compat::cstr,
    client::options::{ServerAddress, ServerApi},
    cmap::{Command, Connection},
    error::{Error, Result},
    BoxFuture,
};

use super::{
    sasl::{SaslContinue, SaslResponse, SaslStart},
    AuthMechanism,
    Credential,
    MONGODB_OIDC_STR,
};

pub(crate) const TOKEN_RESOURCE_PROP_STR: &str = "TOKEN_RESOURCE";
pub(crate) const ENVIRONMENT_PROP_STR: &str = "ENVIRONMENT";
pub(crate) const ALLOWED_HOSTS_PROP_STR: &str = "ALLOWED_HOSTS";
const VALID_PROPERTIES: &[&str] = &[
    TOKEN_RESOURCE_PROP_STR,
    ENVIRONMENT_PROP_STR,
    ALLOWED_HOSTS_PROP_STR,
];

pub(crate) const AZURE_ENVIRONMENT_VALUE_STR: &str = "azure";
pub(crate) const GCP_ENVIRONMENT_VALUE_STR: &str = "gcp";
const K8S_ENVIRONMENT_VALUE_STR: &str = "k8s";
#[cfg(test)]
const TEST_ENVIRONMENT_VALUE_STR: &str = "test";
const VALID_ENVIRONMENTS: &[&str] = &[
    AZURE_ENVIRONMENT_VALUE_STR,
    GCP_ENVIRONMENT_VALUE_STR,
    K8S_ENVIRONMENT_VALUE_STR,
    #[cfg(test)]
    TEST_ENVIRONMENT_VALUE_STR,
];

const HUMAN_CALLBACK_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const MACHINE_CALLBACK_TIMEOUT: Duration = Duration::from_secs(60);
const MACHINE_INVALIDATE_SLEEP_TIMEOUT: Duration = Duration::from_millis(100);
const API_VERSION: u32 = 1;
const DEFAULT_ALLOWED_HOSTS: &[&str] = &[
    "*.mongodb.net",
    "*.mongodb-qa.net",
    "*.mongodb-dev.net",
    "*.mongodbgov.net",
    "localhost",
    "127.0.0.1",
    "::1",
    "*.mongo.com",
];

/// The callback to use for OIDC authentication.
#[derive(Clone)]
#[non_exhaustive]
pub struct Callback {
    inner: Arc<Mutex<Option<CallbackInner>>>,
    is_user_provided: bool,
}

impl Default for Callback {
    fn default() -> Self {
        Self::new()
    }
}

impl Callback {
    pub(crate) fn is_user_provided(&self) -> bool {
        self.is_user_provided
    }

    #[cfg(test)]
    pub(crate) async fn set_access_token(&self, access_token: Option<String>) {
        self.inner.lock().await.as_mut().unwrap().cache.access_token = access_token;
    }

    #[cfg(test)]
    pub(crate) async fn set_refresh_token(&self, refresh_token: Option<String>) {
        self.inner
            .lock()
            .await
            .as_mut()
            .unwrap()
            .cache
            .refresh_token = refresh_token;
    }

    pub(crate) fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(None)),
            is_user_provided: false,
        }
    }

    fn new_function<F>(func: F, kind: CallbackKind) -> Function
    where
        F: Fn(CallbackContext) -> BoxFuture<'static, Result<IdpServerResponse>>
            + Send
            + Sync
            + 'static,
    {
        Function {
            inner: Box::new(FunctionInner { f: Box::new(func) }),
            kind,
        }
    }

    /// Create a new human token request function for OIDC.
    /// The return type is purposefully opaque to users and should only be created using this
    /// function or Callback::machine.
    pub fn human<F>(function: F) -> Callback
    where
        F: Fn(CallbackContext) -> BoxFuture<'static, Result<IdpServerResponse>>
            + Send
            + Sync
            + 'static,
    {
        Self::create_callback(function, CallbackKind::Human)
    }

    /// Create a new machine token request function for OIDC.
    /// The return type is purposefully opaque to users and should only be created using this
    /// function or Callback::human.
    pub fn machine<F>(function: F) -> Callback
    where
        F: Fn(CallbackContext) -> BoxFuture<'static, Result<IdpServerResponse>>
            + Send
            + Sync
            + 'static,
    {
        Self::create_callback(function, CallbackKind::Machine)
    }

    fn create_callback<F>(function: F, kind: CallbackKind) -> Callback
    where
        F: Fn(CallbackContext) -> BoxFuture<'static, Result<IdpServerResponse>>
            + Send
            + Sync
            + 'static,
    {
        Callback {
            inner: Arc::new(Mutex::new(Some(CallbackInner {
                function: Self::new_function(function, kind),
                cache: Cache::new(),
            }))),
            is_user_provided: true,
        }
    }

    /// Create azure callback.
    #[cfg(feature = "azure-oidc")]
    fn azure_callback(client_id: Option<&str>, resource: &str) -> Result<Function> {
        use futures_util::FutureExt;

        let mut url = reqwest::Url::parse(
            "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01",
        )
        .map_err(|e| Error::internal(format!("invalid azure url: {e}")))?;
        url.query_pairs_mut().append_pair("resource", resource);
        if let Some(client_id) = client_id {
            url.query_pairs_mut().append_pair("client_id", client_id);
        }

        Ok(Self::new_function(
            move |_| {
                let url = url.clone();
                async move {
                    let url = url.clone();
                    let response = crate::runtime::HttpClient::default()
                        .get(url)
                        .headers(&[("Metadata", "true"), ("Accept", "application/json")])
                        .send::<Document>()
                        .await
                        .map_err(|e| {
                            Error::authentication_error(
                                MONGODB_OIDC_STR,
                                &format!("Failed to get access token from Azure IDMS: {e}"),
                            )
                        });
                    let response = response?;
                    let access_token = response
                        .get_str("access_token")
                        .map_err(|e| {
                            Error::authentication_error(
                                MONGODB_OIDC_STR,
                                &format!("Failed to get access token from Azure IDMS: {e}"),
                            )
                        })?
                        .to_string();
                    let expires_in = response
                        .get_str("expires_in")
                        .map_err(|e| {
                            Error::authentication_error(
                                MONGODB_OIDC_STR,
                                &format!("Failed to get expires_in from Azure IDMS: {e}"),
                            )
                        })?
                        .parse::<u64>()
                        .map_err(|e| {
                            Error::authentication_error(
                                MONGODB_OIDC_STR,
                                &format!("Failed to parse expires_in from Azure IDMS as u64: {e}"),
                            )
                        })?;
                    let expires = Some(Instant::now() + Duration::from_secs(expires_in));
                    Ok(IdpServerResponse {
                        access_token,
                        expires,
                        refresh_token: None,
                    })
                }
                .boxed()
            },
            CallbackKind::Machine,
        ))
    }

    /// Create gcp callback.
    #[cfg(feature = "gcp-oidc")]
    fn gcp_callback(resource: &str) -> Result<Function> {
        use futures_util::FutureExt;

        let mut url = reqwest::Url::parse(
            "http://metadata/computeMetadata/v1/instance/service-accounts/default/identity",
        )
        .map_err(|e| Error::internal(format!("invalid gcp url: {e}")))?;
        url.query_pairs_mut().append_pair("audience", resource);

        Ok(Self::new_function(
            move |_| {
                let url = url.clone();
                async move {
                    let url = url.clone();
                    let response = crate::runtime::HttpClient::default()
                        .get(url)
                        .headers(&[("Metadata-Flavor", "Google")])
                        .send_and_get_string()
                        .await
                        .map_err(|e| {
                            Error::authentication_error(
                                MONGODB_OIDC_STR,
                                &format!("Failed to get access token from GCP IDMS: {e}"),
                            )
                        });
                    let access_token = response?;
                    Ok(IdpServerResponse {
                        access_token,
                        expires: None,
                        refresh_token: None,
                    })
                }
                .boxed()
            },
            CallbackKind::Machine,
        ))
    }

    fn k8s_callback() -> Function {
        Self::new_function(
            move |_| {
                use futures_util::FutureExt;
                async move {
                    let path = std::env::var("AZURE_FEDERATED_TOKEN_FILE")
                        .or_else(|_| std::env::var("AWS_WEB_IDENTITY_TOKEN_FILE"))
                        .unwrap_or_else(|_| {
                            "/var/run/secrets/kubernetes.io/serviceaccount/token".to_string()
                        });
                    let access_token = tokio::fs::read_to_string(path).await?;
                    Ok(IdpServerResponse {
                        access_token,
                        expires: None,
                        refresh_token: None,
                    })
                }
                .boxed()
            },
            CallbackKind::Machine,
        )
    }
}

/// The OIDC state containing the cache of necessary OIDC info as well as the function
#[derive(Debug)]
struct CallbackInner {
    function: Function,
    cache: Cache,
}

/// Callback provides an interface for creating human and machine functions that return
/// access tokens for use in human and machine OIDC flows.
#[non_exhaustive]
struct Function {
    inner: Box<FunctionInner>,
    kind: CallbackKind,
}

#[non_exhaustive]
#[derive(Clone, Copy, Debug)]
enum CallbackKind {
    Human,
    Machine,
}

use std::fmt::Debug;

impl std::fmt::Debug for Function {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct(format!("Callback: {:?}", self.kind).as_str())
            .finish()
    }
}

struct FunctionInner {
    f: Box<dyn Fn(CallbackContext) -> BoxFuture<'static, Result<IdpServerResponse>> + Send + Sync>,
}

#[derive(Debug, Clone)]
pub(crate) struct Cache {
    idp_server_info: Option<IdpServerInfo>,
    refresh_token: Option<String>,
    access_token: Option<String>,
    token_gen_id: u32,
    last_call_time: Instant,
}

impl Cache {
    fn new() -> Self {
        Self {
            idp_server_info: None,
            refresh_token: None,
            access_token: None,
            token_gen_id: 0,
            last_call_time: Instant::now(),
        }
    }

    async fn update(
        &mut self,
        response: &IdpServerResponse,
        idp_server_info: Option<IdpServerInfo>,
    ) {
        if idp_server_info.is_some() {
            self.idp_server_info = idp_server_info;
        }
        self.access_token = Some(response.access_token.clone());
        self.refresh_token.clone_from(&response.refresh_token);
        self.last_call_time = Instant::now();
        self.token_gen_id += 1;
    }

    async fn propagate_token_gen_id(&mut self, conn: &Connection) {
        let mut token_gen_id = conn.oidc_token_gen_id.lock().await;
        if *token_gen_id < self.token_gen_id {
            *token_gen_id = self.token_gen_id;
        }
    }

    async fn invalidate(&mut self, conn: &Connection, force: bool) {
        let mut token_gen_id = conn.oidc_token_gen_id.lock().await;
        // It should be impossible for token_gen_id to be > cache.token_gen_id, but we check just in
        // case
        if force || *token_gen_id >= self.token_gen_id {
            self.access_token = None;
            *token_gen_id = 0;
        }
    }
}

/// IdpServerInfo contains the information necessary to locate and authorize with an OIDC server.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
#[derive(TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct IdpServerInfo {
    /// issuer is the address of the IdP server.
    pub issuer: String,
    /// client_id is the client id for the application, which must be passed to the IdP in order to
    /// perform authorization.
    pub client_id: Option<String>,
    /// request_scopes are the scopes requested by the application, see [`Oauth Scope`](https://oauth.net/2/scope/)
    pub request_scopes: Option<Vec<String>>,
}

/// CallbackContext contains the information necessary to perform the human or machine flow
/// in a function. The driver passes ownership of this struct to the Callback function.
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
#[derive(Clone, Debug, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct CallbackContext {
    /// The time in the future when the function should return an error if it
    /// it has not completed.
    pub timeout: Option<Instant>,
    /// The version of the function API that the driver is using.
    pub version: u32,
    /// The refresh token that the driver has stored in the cache, which may not
    /// exist.
    pub refresh_token: Option<String>,
    /// The information necessary to locate and authorize with an OIDC server.
    pub idp_info: Option<IdpServerInfo>,
}

/// The return type of the OIDC authentication function. It contains the access token
/// with optional expiration time and refresh token.
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
#[derive(Clone, Debug, TypedBuilder)]
#[builder(field_defaults(default, setter(into)))]
#[non_exhaustive]
pub struct IdpServerResponse {
    #[builder(!default)]
    /// The token that the driver will use to authenticate with the server.
    pub access_token: String,
    /// The time when the access token expires.
    pub expires: Option<Instant>,
    /// The token that the driver will use to refresh the access token when the
    /// access_token expires.
    pub refresh_token: Option<String>,
}

fn make_spec_auth_command(
    source: String,
    payload: Vec<u8>,
    server_api: Option<&ServerApi>,
) -> Command {
    let body = rawdoc! {
        "saslStart": 1,
        "mechanism": MONGODB_OIDC_STR,
        "payload": Binary { subtype: BinarySubtype::Generic, bytes: payload },
        "db": "$external",
    };

    let mut command = Command::new_raw("saslStart", source, body);
    if let Some(server_api) = server_api {
        command.set_server_api(server_api);
    }
    command
}

pub(crate) async fn build_speculative_client_first(credential: &Credential) -> Option<Command> {
    self::build_client_first(credential, None).await
}

/// Constructs the first client message in the OIDC handshake for speculative authentication
pub(crate) async fn build_client_first(
    credential: &Credential,
    server_api: Option<&ServerApi>,
) -> Option<Command> {
    if let Some(ref access_token) = credential
        .oidc_callback
        .inner
        .lock()
        .await
        .as_ref()?
        .cache
        .access_token
    {
        let start_doc = rawdoc! {
            "jwt": access_token.clone()
        };
        let source = credential
            .source
            .clone()
            .unwrap_or_else(|| "$external".to_string());
        return Some(make_spec_auth_command(
            source,
            start_doc.as_bytes().to_vec(),
            server_api,
        ));
    }
    None
}

pub(crate) async fn reauthenticate_stream(
    conn: &mut Connection,
    credential: &Credential,
    server_api: Option<&ServerApi>,
) -> Result<()> {
    credential
        .oidc_callback
        .inner
        .lock()
        .await
        .as_mut()
        .unwrap()
        .cache
        .invalidate(conn, true)
        .await;
    authenticate_stream(conn, credential, server_api, None).await
}

fn get_automatic_provider_callback(credential: &Credential) -> Result<CallbackInner> {
    let Some(ref mechanism_properties) = credential.mechanism_properties else {
        return Err(auth_error(
            "no callback or mechanism properties provided for OIDC authentication",
        ));
    };

    let environment = mechanism_properties.get_str(ENVIRONMENT_PROP_STR).ok();
    #[cfg(any(feature = "azure-oidc", feature = "gcp-oidc"))]
    let token_resource = mechanism_properties
        .get_str(TOKEN_RESOURCE_PROP_STR)
        .map_err(|_| {
            auth_error(format!(
                "the {TOKEN_RESOURCE_PROP_STR} authentication mechanism property must be set"
            ))
        });

    let function = match environment {
        #[cfg(feature = "azure-oidc")]
        Some(AZURE_ENVIRONMENT_VALUE_STR) => {
            let client_id = credential.username.as_deref();
            Callback::azure_callback(client_id, token_resource?)?
        }
        #[cfg(not(feature = "azure-oidc"))]
        Some(AZURE_ENVIRONMENT_VALUE_STR) => {
            return Err(auth_error(
                "the `azure-oidc` feature flag must be enabled for Azure OIDC authentication",
            ));
        }
        #[cfg(feature = "gcp-oidc")]
        Some(GCP_ENVIRONMENT_VALUE_STR) => Callback::gcp_callback(token_resource?)?,
        #[cfg(not(feature = "gcp-oidc"))]
        Some(GCP_ENVIRONMENT_VALUE_STR) => {
            return Err(auth_error(
                "the `gcp-oidc` feature flag must be enabled for GCP OIDC authentication",
            ));
        }
        Some(K8S_ENVIRONMENT_VALUE_STR) => Callback::k8s_callback(),
        Some(other) => {
            return Err(auth_error(format!(
                "unsupported value for authentication mechanism property {ENVIRONMENT_PROP_STR}: \
                 {other}"
            )));
        }
        None => {
            return Err(auth_error(
                "no callback or environment configured for OIDC authentication",
            ));
        }
    };

    Ok(CallbackInner {
        function,
        cache: Cache::new(),
    })
}

pub(crate) async fn authenticate_stream(
    conn: &mut Connection,
    credential: &Credential,
    server_api: Option<&ServerApi>,
    server_first: impl Into<Option<Document>>,
) -> Result<()> {
    // We need to hold the lock for the entire function so that multiple functions
    // are not called during an authentication race, and so that token_gen_id on the Connection
    // always matches that in the Credential Cache.
    let mut callback_guard = credential.oidc_callback.inner.lock().await;

    let CallbackInner {
        cache,
        function: Function { inner, kind },
    } = match callback_guard.as_mut() {
        Some(callback) => callback,
        None => {
            let callback = get_automatic_provider_callback(credential)?;
            callback_guard.insert(callback)
        }
    };
    cache.propagate_token_gen_id(conn).await;

    if server_first.into().is_some() {
        // speculative authentication succeeded, no need to authenticate again
        // update the Connection gen_id to be that of the cred_cache
        cache.propagate_token_gen_id(conn).await;
        return Ok(());
    }
    let source = credential.source.as_deref().unwrap_or("$external");

    match kind {
        CallbackKind::Machine => {
            authenticate_machine(source, conn, credential, cache, server_api, inner.as_ref()).await
        }
        CallbackKind::Human => {
            authenticate_human(source, conn, credential, cache, server_api, inner.as_ref()).await
        }
    }
}

// send_sasl_start_command creates and sends a sasl_start command handling either
// one step or two step sasl based on whether or not the access token is Some.
async fn send_sasl_start_command(
    source: &str,
    conn: &mut Connection,
    credential: &Credential,
    server_api: Option<&ServerApi>,
    access_token: Option<String>,
) -> Result<SaslResponse> {
    let mut start_doc = rawdoc! {};
    if let Some(access_token) = access_token {
        start_doc.append(cstr!("jwt"), access_token);
    } else if let Some(username) = credential.username.as_deref() {
        start_doc.append(cstr!("n"), username);
    }
    let sasl_start = SaslStart::new(
        source.to_string(),
        AuthMechanism::MongoDbOidc,
        start_doc.into_bytes(),
        server_api.cloned(),
    )
    .into_command()?;
    send_sasl_command(conn, sasl_start).await
}

// this is shared functionality between the human and machine flow. In the machine flow, the idp
// info will always be None, but the code is the same so we reuse it.
async fn do_single_step_function(
    source: &str,
    conn: &mut Connection,
    cred_cache: &mut Cache,
    credential: &Credential,
    server_api: Option<&ServerApi>,
    function: &FunctionInner,
    timeout: Duration,
) -> Result<()> {
    let idp_response = {
        let cb_context = CallbackContext {
            timeout: Some(Instant::now() + timeout),
            version: API_VERSION,
            refresh_token: None,
            idp_info: cred_cache.idp_server_info.clone(),
        };
        (function.f)(cb_context).await?
    };
    let response = send_sasl_start_command(
        source,
        conn,
        credential,
        server_api,
        Some(idp_response.access_token.clone()),
    )
    .await?;
    if response.done {
        let server_info = cred_cache.idp_server_info.clone();
        cred_cache.update(&idp_response, server_info).await;
        return Ok(());
    }
    Err(invalid_auth_response())
}

// This is currently only used in the human flow, but is abstracted to make the algorithm more
// clear. The timeout is still passed in, so that the human flow can control the timeout in one
// place.
async fn do_two_step_function(
    source: &str,
    conn: &mut Connection,
    cred_cache: &mut Cache,
    credential: &Credential,
    server_api: Option<&ServerApi>,
    function: &FunctionInner,
    timeout: Duration,
) -> Result<()> {
    // Here we do not have the idpinfo, so we need to do the two step sasl conversation.
    let response = send_sasl_start_command(source, conn, credential, server_api, None).await?;
    if response.done {
        return Err(invalid_auth_response());
    }

    let server_info: IdpServerInfo = crate::bson_compat::deserialize_from_slice(&response.payload)
        .map_err(|_| invalid_auth_response())?;
    let idp_response = {
        let cb_context = CallbackContext {
            timeout: Some(Instant::now() + timeout),
            version: API_VERSION,
            refresh_token: None,
            idp_info: Some(server_info.clone()),
        };
        (function.f)(cb_context).await?
    };

    // Update the credential and connection caches with the access token and the credential cache
    // with the refresh token and token_gen_id
    cred_cache.update(&idp_response, Some(server_info)).await;

    let sasl_continue = SaslContinue::new(
        source.to_string(),
        response.conversation_id,
        rawdoc! { "jwt": idp_response.access_token }.into_bytes(),
        server_api.cloned(),
    )
    .into_command();
    let response = send_sasl_command(conn, sasl_continue).await?;
    if !response.done {
        return Err(invalid_auth_response());
    }

    Ok(())
}

fn get_allowed_hosts(mechanism_properties: Option<&Document>) -> Result<Vec<&str>> {
    if mechanism_properties.is_none() {
        return Ok(Vec::from(DEFAULT_ALLOWED_HOSTS));
    }
    if let Some(allowed_hosts) =
        mechanism_properties.and_then(|p| p.get_array(ALLOWED_HOSTS_PROP_STR).ok())
    {
        return allowed_hosts
            .iter()
            .map(|host| {
                host.as_str().ok_or_else(|| {
                    auth_error(format!(
                        "`{ALLOWED_HOSTS_PROP_STR}` must contain only strings"
                    ))
                })
            })
            .collect::<Result<Vec<_>>>();
    }
    Ok(Vec::from(DEFAULT_ALLOWED_HOSTS))
}

fn validate_address_with_allowed_hosts(
    mechanism_properties: Option<&Document>,
    address: &ServerAddress,
) -> Result<()> {
    #[allow(irrefutable_let_patterns)]
    let hostname = if let ServerAddress::Tcp { host, .. } = address {
        host.as_str()
    } else {
        return Err(auth_error("OIDC human flow only supports TCP addresses"));
    };
    for pattern in get_allowed_hosts(mechanism_properties)? {
        if pattern == hostname {
            return Ok(());
        }
        if pattern.starts_with("*.") && hostname.ends_with(&pattern[1..]) {
            return Ok(());
        }
    }
    Err(auth_error(
        "The Connection address is not in the allowed list of hosts",
    ))
}

async fn authenticate_human(
    source: &str,
    conn: &mut Connection,
    credential: &Credential,
    cred_cache: &mut Cache,
    server_api: Option<&ServerApi>,
    function: &FunctionInner,
) -> Result<()> {
    validate_address_with_allowed_hosts(credential.mechanism_properties.as_ref(), &conn.address)?;

    // We need to hold the lock for the entire function so that multiple functions
    // are not called during an authentication race.

    // If the access token is in the cache, we can use it to send the sasl start command and avoid
    // the function and sasl_continue
    if let Some(ref access_token) = cred_cache.access_token {
        let response = send_sasl_start_command(
            source,
            conn,
            credential,
            server_api,
            Some(access_token.clone()),
        )
        .await;
        if let Ok(response) = response {
            if response.done {
                return Ok(());
            }
        }
        cred_cache.invalidate(conn, false).await;
    }

    // If the cache has a refresh token, we can avoid asking for the server info.
    if let (refresh_token @ Some(_), idp_info) = (
        cred_cache.refresh_token.clone(),
        cred_cache.idp_server_info.clone(),
    ) {
        let idp_response = {
            let cb_context = CallbackContext {
                timeout: Some(Instant::now() + HUMAN_CALLBACK_TIMEOUT),
                version: API_VERSION,
                refresh_token,
                idp_info,
            };
            (function.f)(cb_context).await?
        };

        let access_token = idp_response.access_token.clone();
        let response =
            send_sasl_start_command(source, conn, credential, server_api, Some(access_token)).await;
        if let Ok(response) = response {
            if response.done {
                // Update the credential and connection caches with the access token and the
                // credential cache with the refresh token and token_gen_id
                cred_cache.update(&idp_response, None).await;
                return Ok(());
            }
            // It should really not be possible for this to occur, we would get an error, if the
            // response is not done. Just in case, we will fall through to two_step to try one
            // more time.
        } else {
            // since this is an error, we will go ahead and invalidate the caches so we do not
            // try to use them again and waste time. We should fall through so that we can
            // do the shared flow from the beginning
            cred_cache.invalidate(conn, false).await;
        }
    }

    // If the idpinfo is cached, we run the function and then do a single step sasl conversation.
    // It seems the spec does not allow idpinfo to change on invalidations.
    if cred_cache.idp_server_info.is_some() {
        return do_single_step_function(
            source,
            conn,
            cred_cache,
            credential,
            server_api,
            function,
            HUMAN_CALLBACK_TIMEOUT,
        )
        .await;
    }

    do_two_step_function(
        source,
        conn,
        cred_cache,
        credential,
        server_api,
        function,
        HUMAN_CALLBACK_TIMEOUT,
    )
    .await
}

async fn authenticate_machine(
    source: &str,
    conn: &mut Connection,
    credential: &Credential,
    cred_cache: &mut Cache,
    server_api: Option<&ServerApi>,
    function: &FunctionInner,
) -> Result<()> {
    // If the access token is in the cache, we can use it to send the sasl start command and avoid
    // the function and sasl_continue
    if let Some(ref access_token) = cred_cache.access_token {
        let response = send_sasl_start_command(
            source,
            conn,
            credential,
            server_api,
            Some(access_token.clone()),
        )
        .await;
        if let Ok(response) = response {
            if response.done {
                return Ok(());
            }
        }
        cred_cache.invalidate(conn, false).await;
        tokio::time::sleep(MACHINE_INVALIDATE_SLEEP_TIMEOUT).await;
    }

    do_single_step_function(
        source,
        conn,
        cred_cache,
        credential,
        server_api,
        function,
        MACHINE_CALLBACK_TIMEOUT,
    )
    .await
}

fn auth_error(s: impl AsRef<str>) -> Error {
    Error::authentication_error(MONGODB_OIDC_STR, s.as_ref())
}

fn invalid_auth_response() -> Error {
    Error::invalid_authentication_response(MONGODB_OIDC_STR)
}

async fn send_sasl_command(
    conn: &mut Connection,
    command: crate::cmap::Command,
) -> Result<SaslResponse> {
    let response = conn.send_message(command).await?;
    SaslResponse::parse(
        MONGODB_OIDC_STR,
        response.auth_response_body(MONGODB_OIDC_STR)?,
    )
}

pub(super) fn validate_credential(credential: &Credential) -> Result<()> {
    let default_document = &Document::new();
    let properties = credential
        .mechanism_properties
        .as_ref()
        .unwrap_or(default_document);
    for k in properties.keys() {
        if VALID_PROPERTIES.iter().all(|p| *p != k) {
            return Err(Error::invalid_argument(format!(
                "'{k}' is not a valid property for {MONGODB_OIDC_STR} authentication",
            )));
        }
    }
    let environment = properties.get_str(ENVIRONMENT_PROP_STR);
    if environment.is_ok() && credential.oidc_callback.is_user_provided() {
        return Err(Error::invalid_argument(format!(
            "OIDC callback cannot be set for {MONGODB_OIDC_STR} authentication, if an \
             `{ENVIRONMENT_PROP_STR}` is set"
        )));
    }
    let has_token_resource = properties.contains_key(TOKEN_RESOURCE_PROP_STR);
    match environment {
        Ok(AZURE_ENVIRONMENT_VALUE_STR) | Ok(GCP_ENVIRONMENT_VALUE_STR) => {
            if !has_token_resource {
                return Err(Error::invalid_argument(format!(
                    "`{TOKEN_RESOURCE_PROP_STR}` must be set for {MONGODB_OIDC_STR} \
                     authentication in the `{AZURE_ENVIRONMENT_VALUE_STR}` or \
                     `{GCP_ENVIRONMENT_VALUE_STR}` `{ENVIRONMENT_PROP_STR}`",
                )));
            }
        }
        _ => {
            if has_token_resource {
                return Err(Error::invalid_argument(format!(
                    "`{TOKEN_RESOURCE_PROP_STR}` must not be set for {MONGODB_OIDC_STR} \
                     authentication unless using the `{AZURE_ENVIRONMENT_VALUE_STR}` or \
                     `{GCP_ENVIRONMENT_VALUE_STR}` `{ENVIRONMENT_PROP_STR}`",
                )));
            }
        }
    }
    if credential
        .source
        .as_ref()
        .is_some_and(|source| source != "$external")
    {
        return Err(Error::invalid_argument(format!(
            "only $external may be specified as an auth source for {MONGODB_OIDC_STR}",
        )));
    }
    #[cfg(test)]
    if environment
        .as_ref()
        .is_ok_and(|ev| *ev == TEST_ENVIRONMENT_VALUE_STR)
        && credential.username.is_some()
    {
        return Err(Error::invalid_argument(format!(
            "username must not be set for {MONGODB_OIDC_STR} authentication in the \
             {TEST_ENVIRONMENT_VALUE_STR} {ENVIRONMENT_PROP_STR}",
        )));
    }
    if credential.password.is_some() {
        return Err(Error::invalid_argument(format!(
            "password must not be set for {MONGODB_OIDC_STR} authentication"
        )));
    }
    if let Ok(env) = environment {
        if VALID_ENVIRONMENTS.iter().all(|e| *e != env) {
            return Err(Error::invalid_argument(format!(
                "unsupported environment for {MONGODB_OIDC_STR} authentication: {env}",
            )));
        }
    }
    if let Some(allowed_hosts) = properties.get(ALLOWED_HOSTS_PROP_STR) {
        allowed_hosts.as_array().ok_or_else(|| {
            Error::invalid_argument(format!("`{ALLOWED_HOSTS_PROP_STR}` must be an array"))
        })?;
    }
    Ok(())
}
