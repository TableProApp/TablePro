//! The server's own socket file. MySQL counts a socket as secure and
//! expects caching_sha2_password's password in the clear there, which
//! sqlx sends only inside TLS, so the first login after a start is the
//! one that proves the driver asks for TLS on a socket.

use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;

use tablepro_core::{NetworkEndpoint, TlsConfig, Value, WorkspaceSettings};
use tablepro_net::LocalSocketTransport;
use tablepro_test_fixtures::{MysqlFixture, MysqlOptions};
use tablepro_test_support::conformance::test_liveness;

use crate::support::{FLAVOURS, connect_with, options_over, password, scalar};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn the_first_root_login_after_a_start_goes_through_the_socket() {
    for flavour in FLAVOURS {
        // Docker Desktop on macOS does not carry a Unix socket from a container to the host.
        let base = std::env::var_os("CARGO_TARGET_TMPDIR").unwrap_or_else(|| std::env::temp_dir().into_os_string());
        let dir = tempfile::Builder::new()
            .prefix("my")
            .tempdir_in(base)
            .expect("a socket folder");
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o777)).expect("an open folder");
        let fixture = MysqlFixture::start_with(MysqlOptions::new(flavour).with_socket_dir(dir.path()), None)
            .await
            .expect("a MySQL container");
        let socket = dir.path().join("mysqld.sock");
        let liveness = test_liveness();
        let transport = Arc::new(LocalSocketTransport::new(
            socket.clone(),
            NetworkEndpoint::new(socket.display().to_string(), 3306).expect("a socket host"),
            &liveness,
        ));

        let connection = connect_with(options_over(
            transport,
            password(&fixture.root_credentials()),
            fixture.database(),
            TlsConfig::disabled(),
            WorkspaceSettings::workspace(false),
            liveness,
        ))
        .await;

        assert_eq!(
            scalar(
                connection.as_ref(),
                "SELECT @@hostname IS NOT NULL AND USER() LIKE '%@localhost'"
            )
            .await,
            Value::Int(1),
            "{flavour:?} did not log in over its socket"
        );
    }
}
