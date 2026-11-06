//! The server's own socket: a folder named as the host, the file named
//! after the port, and a login the server takes without a password.

use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_core::{Credentials, NetworkEndpoint, TlsConfig, Value, WorkspaceSettings};
use tablepro_net::LocalSocketTransport;
use tablepro_test_fixtures::PostgresFixture;
use tablepro_test_support::conformance::test_liveness;

use crate::support::{connect_with, options_over, scalar};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_socket_folder_reaches_the_server_with_the_login_it_trusts() {
    // Docker Desktop on macOS does not carry a Unix socket from a container to the host.
    let base = std::env::var_os("CARGO_TARGET_TMPDIR").unwrap_or_else(|| std::env::temp_dir().into_os_string());
    let dir = tempfile::Builder::new()
        .prefix("pg")
        .tempdir_in(base)
        .expect("a socket folder");
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o777)).expect("an open folder");
    let fixture = PostgresFixture::start_with_socket_dir(dir.path())
        .await
        .expect("a PostgreSQL container");
    let liveness = test_liveness();
    let folder = dir.path().display().to_string();
    let transport = Arc::new(LocalSocketTransport::new(
        dir.path().join(".s.PGSQL.5432"),
        NetworkEndpoint::new(&folder, 5432).expect("a socket host"),
        &liveness,
    ));
    let login = Credentials::Password {
        username: fixture.password_credentials().username,
        password: SecretString::from(String::new()),
    };

    let connection = connect_with(options_over(
        transport,
        login,
        fixture.database(),
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(false),
        liveness,
    ))
    .await;

    assert_eq!(
        scalar(connection.as_ref(), "SELECT inet_server_addr() IS NULL").await,
        Value::Bool(true),
        "the login went over TCP"
    );
}
