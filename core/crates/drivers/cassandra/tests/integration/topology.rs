//! A node of a two-node cluster, reached through its own port while the
//! cluster names the other node at an address on the containers'
//! network: every call stays on the node the transport reaches, as it
//! has to through an SSH tunnel.

use tablepro_core::{Connection, Value};
use tablepro_test_fixtures::{CassandraFixture, TestNetwork};
use uuid::Uuid;

use crate::support::{CassandraServer, ScyllaServer, Server, connect, rows, scalar};

async fn host_id(fixture: &CassandraFixture) -> Uuid {
    let output = fixture
        .cql("SELECT host_id FROM system.local")
        .await
        .expect("the node's host id")
        .stdout_text();
    output
        .split_whitespace()
        .find_map(|word| Uuid::parse_str(word).ok())
        .expect("a host id in cqlsh's answer")
}

/// Every answer comes from `expected`, and the cluster it answers for
/// has one other node.
async fn stays_on(connection: &dyn Connection, expected: Uuid) {
    for _ in 0..20 {
        let answered = scalar(connection, "SELECT host_id FROM system.local").await;
        assert_eq!(answered, Value::Uuid(expected));
    }
    let peers = rows(connection, "SELECT peer FROM system.peers").await;
    assert_eq!(peers.len(), 1, "{peers:?}");
}

async fn each_node_keeps_the_session_it_was_reached_through<S: Server>() {
    let network = TestNetwork::new();
    let seed = CassandraFixture::start_in(S::FLAVOUR, &network)
        .await
        .expect("the first node");
    let peer = CassandraFixture::join(&seed, &network).await.expect("the second node");
    let (seed_host, peer_host) = (host_id(&seed).await, host_id(&peer).await);
    assert_ne!(seed_host, peer_host);

    let through_seed = connect(&seed, false).await;
    stays_on(through_seed.as_ref(), seed_host).await;
    let through_peer = connect(&peer, false).await;
    stays_on(through_peer.as_ref(), peer_host).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_sessions_stay_on_the_node_they_reached() {
    each_node_keeps_the_session_it_was_reached_through::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_sessions_stay_on_the_node_they_reached() {
    each_node_keeps_the_session_it_was_reached_through::<ScyllaServer>().await;
}
