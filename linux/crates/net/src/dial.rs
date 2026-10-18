use std::io;
use std::net::SocketAddr;

use tablepro_core::{LivenessPolicy, NetworkEndpoint, TimeoutPhase, TransportError};
use tokio::net::TcpStream;

use crate::socket_options::apply_socket_options;

#[derive(Debug)]
pub(crate) enum AttemptFailure {
    Refused,
    TimedOut,
    Other(io::Error),
}

pub(crate) async fn dial_addresses(
    addresses: Vec<SocketAddr>,
    endpoint: &NetworkEndpoint,
    liveness: &LivenessPolicy,
) -> Result<TcpStream, TransportError> {
    let mut failures = Vec::with_capacity(addresses.len());
    for address in addresses {
        match tokio::time::timeout(liveness.connect_timeout, TcpStream::connect(address)).await {
            Ok(Ok(stream)) => {
                apply_socket_options(&stream, liveness).map_err(|error| TransportError::Unreachable {
                    endpoint: endpoint.clone(),
                    detail: error.to_string(),
                })?;
                return Ok(stream);
            }
            Ok(Err(error)) if error.kind() == io::ErrorKind::ConnectionRefused => {
                failures.push(AttemptFailure::Refused)
            }
            Ok(Err(error)) => failures.push(AttemptFailure::Other(error)),
            Err(_) => failures.push(AttemptFailure::TimedOut),
        }
    }
    Err(aggregate_failures(endpoint, failures))
}

pub(crate) fn aggregate_failures(endpoint: &NetworkEndpoint, failures: Vec<AttemptFailure>) -> TransportError {
    let every = |predicate: fn(&AttemptFailure) -> bool| !failures.is_empty() && failures.iter().all(predicate);
    if every(|failure| matches!(failure, AttemptFailure::Refused)) {
        return TransportError::Refused {
            endpoint: endpoint.clone(),
        };
    }
    if every(|failure| matches!(failure, AttemptFailure::TimedOut)) {
        return TransportError::Timeout {
            phase: TimeoutPhase::Connect,
        };
    }
    let detail = match failures.into_iter().last() {
        Some(AttemptFailure::Other(error)) => error.to_string(),
        Some(AttemptFailure::Refused) => "connection refused".to_owned(),
        Some(AttemptFailure::TimedOut) => "connection attempt timed out".to_owned(),
        None => "the name resolved to no addresses".to_owned(),
    };
    TransportError::Unreachable {
        endpoint: endpoint.clone(),
        detail,
    }
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener as StdListener;
    use std::time::Duration;

    use socket2::{Domain, Socket, Type};

    use super::*;

    fn quick_liveness() -> LivenessPolicy {
        LivenessPolicy {
            connect_timeout: Duration::from_millis(250),
            ..LivenessPolicy::DESKTOP
        }
    }

    fn full_backlog_listener() -> (Socket, SocketAddr, Vec<std::net::TcpStream>) {
        let socket = Socket::new(Domain::IPV4, Type::STREAM, None).unwrap();
        socket.bind(&SocketAddr::from(([127, 0, 0, 1], 0)).into()).unwrap();
        socket.listen(0).unwrap();
        let address = socket.local_addr().unwrap().as_socket().unwrap();
        let fillers = (0..4)
            .filter_map(|_| std::net::TcpStream::connect_timeout(&address, Duration::from_millis(200)).ok())
            .collect();
        (socket, address, fillers)
    }

    #[tokio::test]
    async fn dropped_port_then_live_listener_connects_second() {
        let dropped = StdListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let live = StdListener::bind("127.0.0.1:0").unwrap();
        let live_address = live.local_addr().unwrap();
        let endpoint = NetworkEndpoint::new("127.0.0.1", live_address.port()).unwrap();

        let stream = dial_addresses(vec![dropped, live_address], &endpoint, &quick_liveness())
            .await
            .unwrap();
        assert_eq!(stream.peer_addr().unwrap(), live_address);
    }

    #[tokio::test]
    async fn full_backlog_listener_then_live_listener_connects_second() {
        let (_full, full_address, _fillers) = full_backlog_listener();
        let live = StdListener::bind("127.0.0.1:0").unwrap();
        let live_address = live.local_addr().unwrap();
        let endpoint = NetworkEndpoint::new("127.0.0.1", live_address.port()).unwrap();

        let stream = dial_addresses(vec![full_address, live_address], &endpoint, &quick_liveness())
            .await
            .unwrap();
        assert_eq!(stream.peer_addr().unwrap(), live_address);
    }

    #[tokio::test]
    async fn full_backlog_listener_alone_is_connect_timeout() {
        let (_full, full_address, _fillers) = full_backlog_listener();
        let endpoint = NetworkEndpoint::new("127.0.0.1", full_address.port()).unwrap();
        assert!(matches!(
            dial_addresses(vec![full_address], &endpoint, &quick_liveness()).await,
            Err(TransportError::Timeout {
                phase: TimeoutPhase::Connect
            })
        ));
    }

    fn endpoint() -> NetworkEndpoint {
        NetworkEndpoint::new("db.example.com", 5432).unwrap()
    }

    #[test]
    fn aggregate_failures_all_refused_is_refused() {
        let error = aggregate_failures(&endpoint(), vec![AttemptFailure::Refused, AttemptFailure::Refused]);
        assert_eq!(error, TransportError::Refused { endpoint: endpoint() });
    }

    #[test]
    fn aggregate_failures_all_timed_out_is_connect_timeout() {
        let error = aggregate_failures(&endpoint(), vec![AttemptFailure::TimedOut, AttemptFailure::TimedOut]);
        assert_eq!(
            error,
            TransportError::Timeout {
                phase: TimeoutPhase::Connect
            }
        );
    }

    #[test]
    fn aggregate_failures_mixed_is_unreachable_with_last_error() {
        let failures = vec![
            AttemptFailure::Refused,
            AttemptFailure::TimedOut,
            AttemptFailure::Other(io::Error::new(io::ErrorKind::HostUnreachable, "no route to host")),
        ];
        assert_eq!(
            aggregate_failures(&endpoint(), failures),
            TransportError::Unreachable {
                endpoint: endpoint(),
                detail: "no route to host".to_owned(),
            }
        );
        assert!(matches!(
            aggregate_failures(&endpoint(), Vec::new()),
            TransportError::Unreachable { .. }
        ));
    }
}
