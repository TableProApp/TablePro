#![allow(clippy::cast_possible_truncation)]
#![allow(clippy::cast_possible_wrap)]

#[cfg(feature = "dns-resolver")]
#[path = "test/atlas_connectivity.rs"]
mod atlas_connectivity_skip_ci; // requires Atlas URI environment variables set
mod atlas_search;
#[cfg(feature = "dns-resolver")]
#[path = "test/atlas_sfp.rs"]
mod atlas_sfp_skip_ci; // requires SFP environment variables set
mod auth;
mod bson_util;
mod bulk_write;
mod change_stream;
mod client;
mod coll;
#[cfg(any(
    feature = "zstd-compression",
    feature = "zlib-compression",
    feature = "snappy-compression"
))]
mod compression;
#[cfg(feature = "in-use-encryption")]
#[path = "test/csfle.rs"]
pub(crate) mod csfle_skip_local; // see modules for requirements
mod cursor;
mod db;
mod documentation_examples;
mod error;
#[path = "test/happy_eyeballs.rs"]
mod happy_eyeballs_skip_ci; // requires happy eyeballs server
mod index_management;
mod lambda_examples;
pub(crate) mod spec;
mod timeseries;
pub(crate) mod util;

#[cfg(feature = "in-use-encryption")]
pub(crate) use self::csfle_skip_local as csfle;
pub(crate) use self::{
    spec::{run_spec_test, Serverless, Topology},
    util::{
        assert_matches,
        eq_matches,
        file_level_log,
        log_uncaptured,
        Event,
        EventClient,
        MatchErrExt,
        Matchable,
        TestClient,
    },
};

use futures::FutureExt;
use home::home_dir;
use std::sync::LazyLock;
use tokio::sync::OnceCell;

#[cfg(feature = "tracing-unstable")]
use self::util::TracingHandler;
use crate::{
    bson::{doc, Document},
    client::{
        auth::Credential,
        options::{ServerApi, ServerApiVersion},
    },
    hello::HelloCommandResponse,
    options::{
        oidc::{Callback, IdpServerResponse},
        AuthMechanism,
        ClientOptions,
        ServerAddress,
    },
    test::spec::oidc::get_access_token_test_user_1,
    Client,
};
use std::{fs::read_to_string, str::FromStr};

pub(crate) async fn get_client_options() -> &'static ClientOptions {
    static CLIENT_OPTIONS: OnceCell<ClientOptions> = OnceCell::const_new();
    CLIENT_OPTIONS
        .get_or_init(|| async {
            let mut options = ClientOptions::parse(&*DEFAULT_URI).await.unwrap();
            update_options_for_testing(&mut options);
            options
        })
        .await
}
pub(crate) async fn auth_enabled() -> bool {
    get_client_options().await.credential.is_some()
}

struct TestClientMetadata {
    server_version: semver::Version,
    hello_response: HelloCommandResponse,
    server_parameters: Document,
}
async fn get_test_client_metadata() -> &'static TestClientMetadata {
    static TEST_CLIENT_METADATA: OnceCell<TestClientMetadata> = OnceCell::const_new();
    TEST_CLIENT_METADATA
        .get_or_init(|| async {
            let mut client_options = get_client_options().await.clone();
            // OIDC admin credentials are required to call getParameter when running with OIDC
            // authentication.
            if let (Ok(username), Ok(password)) = (
                std::env::var("OIDC_ADMIN_USER"),
                std::env::var("OIDC_ADMIN_PWD"),
            ) {
                let credential = Credential::builder()
                    .username(username)
                    .password(password)
                    .build();
                client_options.credential = Some(credential);
            }
            let client = Client::for_test().options(client_options).await;

            let build_info = client
                .database("test")
                .run_command(doc! { "buildInfo": 1 })
                .await
                .unwrap();
            let mut server_version =
                semver::Version::parse(build_info.get_str("version").unwrap()).unwrap();
            // ignore whether the version is a prerelease
            server_version.pre = semver::Prerelease::EMPTY;

            let hello_response = client.hello().await.unwrap();

            let server_parameters = client
                .database("admin")
                .run_command(doc! { "getParameter": "*" })
                .await
                .unwrap();

            TestClientMetadata {
                server_version,
                hello_response,
                server_parameters,
            }
        })
        .await
}

// Utility functions to check server version requirements. All but server_version_matches ignore
// the server's patch version; specify a requirement string to server_version_matches for a
// patch-sensitive comparison.
#[expect(dead_code)]
pub(crate) async fn server_version_eq(major: u64, minor: u64) -> bool {
    let server_version = &get_test_client_metadata().await.server_version;
    server_version.major == major && server_version.minor == minor
}
#[expect(dead_code)]
pub(crate) async fn server_version_gt(major: u64, minor: u64) -> bool {
    let server_version = &get_test_client_metadata().await.server_version;
    server_version.major > major || server_version.major == major && server_version.minor > minor
}
pub(crate) async fn server_version_gte(major: u64, minor: u64) -> bool {
    let server_version = &get_test_client_metadata().await.server_version;
    server_version.major > major || server_version.major == major && server_version.minor >= minor
}
pub(crate) async fn server_version_lt(major: u64, minor: u64) -> bool {
    let server_version = &get_test_client_metadata().await.server_version;
    server_version.major < major || server_version.major == major && server_version.minor < minor
}
#[expect(dead_code)]
pub(crate) async fn server_version_lte(major: u64, minor: u64) -> bool {
    let server_version = &get_test_client_metadata().await.server_version;
    server_version.major < major || server_version.major == major && server_version.minor <= minor
}
pub(crate) async fn server_version_matches(requirement: &str) -> bool {
    let requirement = semver::VersionReq::parse(requirement).unwrap();
    let server_version = &get_test_client_metadata().await.server_version;
    requirement.matches(server_version)
}

pub(crate) async fn get_server_parameters() -> &'static Document {
    &get_test_client_metadata().await.server_parameters
}

pub(crate) async fn get_primary() -> Option<ServerAddress> {
    get_test_client_metadata()
        .await
        .hello_response
        .primary
        .as_ref()
        .map(|s| ServerAddress::parse(s).unwrap())
}
pub(crate) async fn get_max_write_batch_size() -> usize {
    get_test_client_metadata()
        .await
        .hello_response
        .max_write_batch_size
        .unwrap()
        .try_into()
        .unwrap()
}
pub(crate) async fn get_max_bson_object_size() -> usize {
    get_test_client_metadata()
        .await
        .hello_response
        .max_bson_object_size
        .try_into()
        .unwrap()
}
pub(crate) async fn get_max_message_size_bytes() -> usize {
    get_test_client_metadata()
        .await
        .hello_response
        .max_message_size_bytes
        .try_into()
        .unwrap()
}

pub(crate) async fn get_topology() -> &'static Topology {
    static TOPOLOGY: OnceCell<Topology> = OnceCell::const_new();
    TOPOLOGY
        .get_or_init(|| async {
            let client_options = get_client_options().await;
            if client_options.load_balanced == Some(true) {
                return Topology::LoadBalanced;
            }

            let hello_response = &get_test_client_metadata().await.hello_response;
            if hello_response.msg.as_deref() == Some("isdbgrid") {
                return Topology::Sharded;
            }
            if hello_response.set_name.is_some() {
                return Topology::ReplicaSet;
            }

            Topology::Single
        })
        .await
}
pub(crate) async fn topology_is_standalone() -> bool {
    get_topology().await == &Topology::Single
}
pub(crate) async fn topology_is_replica_set() -> bool {
    get_topology().await == &Topology::ReplicaSet
}
pub(crate) async fn topology_is_sharded() -> bool {
    get_topology().await == &Topology::Sharded
}
pub(crate) async fn topology_is_load_balanced() -> bool {
    get_topology().await == &Topology::LoadBalanced
}

pub(crate) async fn transactions_supported() -> bool {
    topology_is_replica_set().await || topology_is_sharded().await
}
pub(crate) async fn fail_command_appname_initial_handshake_supported() -> bool {
    let requirements = [">= 4.4.7, < 4.5.0", ">= 4.9.0"];
    for requirement in requirements {
        if server_version_matches(requirement).await {
            return true;
        }
    }
    false
}
pub(crate) async fn streaming_monitor_protocol_supported() -> bool {
    get_test_client_metadata()
        .await
        .hello_response
        .topology_version
        .is_some()
}

#[cfg(feature = "in-use-encryption")]
pub(crate) fn mongocrypt_version_lt(version: &str) -> bool {
    let mut actual_version = semver::Version::parse(mongocrypt::version()).unwrap();
    actual_version.pre = semver::Prerelease::EMPTY;
    let requirement = semver::VersionReq::parse(&format!("<{version}")).unwrap();
    requirement.matches(&actual_version)
}

pub(crate) static DEFAULT_URI: LazyLock<String> = LazyLock::new(get_default_uri);
pub(crate) static SERVER_API: LazyLock<Option<ServerApi>> =
    LazyLock::new(|| match std::env::var("MONGODB_API_VERSION") {
        Ok(server_api_version) if !server_api_version.is_empty() => Some(ServerApi {
            version: ServerApiVersion::from_str(server_api_version.as_str()).unwrap(),
            deprecation_errors: None,
            strict: None,
        }),
        _ => None,
    });
pub(crate) static LOAD_BALANCED_SINGLE_URI: LazyLock<Option<String>> =
    LazyLock::new(|| std::env::var("SINGLE_MONGOS_LB_URI").ok());
pub(crate) static LOAD_BALANCED_MULTIPLE_URI: LazyLock<Option<String>> =
    LazyLock::new(|| std::env::var("MULTI_MONGOS_LB_URI").ok());
pub(crate) static OIDC_URI: LazyLock<Option<String>> =
    LazyLock::new(|| std::env::var("MONGODB_URI_SINGLE").ok());

// conditional definitions do not work within the lazy_static! macro, so this
// needs to be defined separately.
#[cfg(feature = "tracing-unstable")]
/// A global default tracing handler that will be installed the first time this
/// value is accessed. A global handler must be used anytime the multi-threaded
/// test runtime is in use, as non-global handlers only apply to the thread
/// they are registered in.
/// By default this handler will collect no tracing events.
/// Its minimum severity levels can be configured on a per-component basis using
/// [`TracingHandler:set_levels`]. The test lock MUST be acquired exclusively in
/// any test that will use the handler to avoid mixing events from multiple tests.
pub(crate) static DEFAULT_GLOBAL_TRACING_HANDLER: LazyLock<TracingHandler> = LazyLock::new(|| {
    let handler = TracingHandler::new();
    tracing::subscriber::set_global_default(handler.clone())
        .expect("setting global default tracing subscriber failed");
    handler
});

pub(crate) fn update_options_for_testing(options: &mut ClientOptions) {
    if options.server_api.is_none() {
        options.server_api.clone_from(&SERVER_API);
    }

    #[cfg(any(
        feature = "zstd-compression",
        feature = "zlib-compression",
        feature = "snappy-compression"
    ))]
    set_compressor(options);

    if let Some(ref mut credential) = options.credential {
        if credential.mechanism == Some(AuthMechanism::MongoDbOidc)
            && credential
                .mechanism_properties
                .as_ref()
                .map(|properties| properties.get("ENVIRONMENT").is_none())
                .unwrap_or(true)
        {
            credential.oidc_callback = Callback::machine(move |_| {
                async move {
                    Ok(IdpServerResponse::builder()
                        .access_token(get_access_token_test_user_1().await)
                        .build())
                }
                .boxed()
            });
        }
    }
}

fn get_default_uri() -> String {
    if let Some(uri) = LOAD_BALANCED_SINGLE_URI.clone() {
        if !uri.is_empty() {
            return uri;
        }
    }
    if let Some(uri) = &*OIDC_URI {
        return uri.clone();
    }
    if let Ok(uri) = std::env::var("MONGODB_URI") {
        return uri;
    }
    if let Some(mut home) = home_dir() {
        home.push(".mongodb_uri");
        if let Ok(uri) = read_to_string(home) {
            return uri;
        }
    }
    "mongodb://localhost:27017".to_string()
}

#[cfg(any(
    feature = "zstd-compression",
    feature = "zlib-compression",
    feature = "snappy-compression"
))]
fn set_compressor(options: &mut ClientOptions) {
    use crate::options::Compressor;

    #[cfg(feature = "zstd-compression")]
    {
        options.compressors = Some(vec![Compressor::Zstd { level: None }]);
    }
    #[cfg(feature = "zlib-compression")]
    {
        options.compressors = Some(vec![Compressor::Zlib { level: None }]);
    }
    #[cfg(feature = "snappy-compression")]
    {
        options.compressors = Some(vec![Compressor::Snappy]);
    }
}

pub(crate) fn get_var(var: &str) -> String {
    std::env::var(var).expect(var)
}
