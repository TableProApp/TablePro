use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use tablepro_core::{LivenessPolicy, NetworkEndpoint, TimeoutPhase, TransportError};
use tokio::net::TcpStream;
use tokio::task::JoinSet;
use tokio::time::Instant;

use crate::socket_options::apply_socket_options;

// RFC 8305, section 5: the recommended Connection Attempt Delay.
const CONNECTION_ATTEMPT_DELAY: Duration = Duration::from_millis(250);

#[derive(Debug)]
pub(crate) enum AttemptFailure {
    Refused,
    TimedOut,
    Other(io::Error),
}

impl AttemptFailure {
    fn from_io(error: io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::ConnectionRefused => Self::Refused,
            _ => Self::Other(error),
        }
    }
}

// Happy Eyeballs (RFC 8305): attempts start a delay apart, or at once after a failure, under one deadline.
pub(crate) async fn dial_addresses(
    addresses: Vec<SocketAddr>,
    endpoint: &NetworkEndpoint,
    liveness: &LivenessPolicy,
    deadline: Instant,
) -> Result<TcpStream, TransportError> {
    let mut waiting = interleave_families(addresses).into_iter();
    let mut attempts = JoinSet::new();
    let mut failures = Vec::with_capacity(waiting.len());
    let mut next_start = Instant::now();
    loop {
        if Instant::now() >= next_start
            && let Some(address) = waiting.next()
        {
            attempts.spawn(TcpStream::connect(address));
            next_start = Instant::now() + CONNECTION_ATTEMPT_DELAY;
        }
        if attempts.is_empty() {
            break;
        }
        let staggering = !waiting.as_slice().is_empty();
        tokio::select! {
            biased;
            Some(joined) = attempts.join_next() => match joined {
                Ok(Ok(stream)) => {
                    apply_socket_options(&stream, liveness).map_err(|error| TransportError::Unreachable {
                        endpoint: endpoint.clone(),
                        detail: error.to_string(),
                    })?;
                    return Ok(stream);
                }
                Ok(Err(error)) => {
                    failures.push(AttemptFailure::from_io(error));
                    next_start = Instant::now();
                }
                Err(stopped) => {
                    failures.push(AttemptFailure::Other(stopped.into()));
                    next_start = Instant::now();
                }
            },
            () = tokio::time::sleep_until(deadline) => {
                failures.extend(std::iter::repeat_with(|| AttemptFailure::TimedOut).take(attempts.len()));
                break;
            }
            () = tokio::time::sleep_until(next_start), if staggering => {}
        }
    }
    Err(aggregate_failures(endpoint, failures))
}

// RFC 8305, section 4: alternating families, a dead one costs one delay rather than one per address.
fn interleave_families(addresses: Vec<SocketAddr>) -> Vec<SocketAddr> {
    let Some(first_is_v6) = addresses.first().map(SocketAddr::is_ipv6) else {
        return addresses;
    };
    let (preferred, other): (Vec<_>, Vec<_>) = addresses
        .into_iter()
        .partition(|address| address.is_ipv6() == first_is_v6);
    let mut preferred = preferred.into_iter();
    let mut other = other.into_iter();
    let mut ordered = Vec::with_capacity(preferred.len() + other.len());
    loop {
        let (next_preferred, next_other) = (preferred.next(), other.next());
        if next_preferred.is_none() && next_other.is_none() {
            return ordered;
        }
        ordered.extend(next_preferred);
        ordered.extend(next_other);
    }
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

    use socket2::{Domain, Socket, Type};

    use super::*;

    fn quick_liveness() -> LivenessPolicy {
        LivenessPolicy {
            connect_timeout: Duration::from_millis(250),
            ..LivenessPolicy::DESKTOP
        }
    }

    // Long enough for several attempt delays.
    fn racing_liveness() -> LivenessPolicy {
        LivenessPolicy {
            connect_timeout: Duration::from_secs(3),
            ..LivenessPolicy::DESKTOP
        }
    }

    fn deadline(liveness: &LivenessPolicy) -> Instant {
        Instant::now() + liveness.connect_timeout
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
        let liveness = quick_liveness();

        let stream = dial_addresses(vec![dropped, live_address], &endpoint, &liveness, deadline(&liveness))
            .await
            .unwrap();
        assert_eq!(stream.peer_addr().unwrap(), live_address);
    }

    #[tokio::test]
    async fn black_holed_first_address_connects_inside_one_connect_timeout() {
        let (_full, full_address, _fillers) = full_backlog_listener();
        let live = StdListener::bind("127.0.0.1:0").unwrap();
        let live_address = live.local_addr().unwrap();
        let endpoint = NetworkEndpoint::new("127.0.0.1", live_address.port()).unwrap();
        let liveness = racing_liveness();

        // The bound the SQL Server, ClickHouse and Redis drivers put around `Transport::open`.
        let dialled = tokio::time::timeout(
            liveness.connect_timeout,
            dial_addresses(
                vec![full_address, live_address],
                &endpoint,
                &liveness,
                deadline(&liveness),
            ),
        )
        .await;

        let stream = dialled.expect("the second address within the connect timeout").unwrap();
        assert_eq!(stream.peer_addr().unwrap(), live_address);
    }

    #[tokio::test]
    async fn every_address_black_holed_is_connect_timeout_at_the_deadline() {
        let (_first, first_address, _first_fillers) = full_backlog_listener();
        let (_second, second_address, _second_fillers) = full_backlog_listener();
        let endpoint = NetworkEndpoint::new("127.0.0.1", first_address.port()).unwrap();
        let liveness = LivenessPolicy {
            connect_timeout: Duration::from_millis(600),
            ..LivenessPolicy::DESKTOP
        };
        let started = Instant::now();

        let dialled = dial_addresses(
            vec![first_address, second_address],
            &endpoint,
            &liveness,
            deadline(&liveness),
        )
        .await;

        assert!(matches!(
            dialled,
            Err(TransportError::Timeout {
                phase: TimeoutPhase::Connect
            })
        ));
        assert!(started.elapsed() < liveness.connect_timeout * 2);
    }

    #[tokio::test]
    async fn full_backlog_listener_alone_is_connect_timeout() {
        let (_full, full_address, _fillers) = full_backlog_listener();
        let endpoint = NetworkEndpoint::new("127.0.0.1", full_address.port()).unwrap();
        let liveness = quick_liveness();
        assert!(matches!(
            dial_addresses(vec![full_address], &endpoint, &liveness, deadline(&liveness)).await,
            Err(TransportError::Timeout {
                phase: TimeoutPhase::Connect
            })
        ));
    }

    #[tokio::test]
    async fn every_address_refused_is_refused() {
        let first = StdListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let second = StdListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let endpoint = NetworkEndpoint::new("127.0.0.1", first.port()).unwrap();
        let liveness = racing_liveness();

        assert_eq!(
            dial_addresses(vec![first, second], &endpoint, &liveness, deadline(&liveness))
                .await
                .err(),
            Some(TransportError::Refused {
                endpoint: endpoint.clone()
            })
        );
    }

    #[test]
    fn interleave_families_alternates_from_the_first_family() {
        let v6 = |last: u16| SocketAddr::from(([0x2001, 0xdb8, 0, 0, 0, 0, 0, last], 5432));
        let v4 = |last: u8| SocketAddr::from(([192, 0, 2, last], 5432));

        assert_eq!(
            interleave_families(vec![v6(1), v6(2), v6(3), v4(1), v4(2)]),
            vec![v6(1), v4(1), v6(2), v4(2), v6(3)]
        );
        assert_eq!(
            interleave_families(vec![v4(1), v4(2), v6(1)]),
            vec![v4(1), v6(1), v4(2)]
        );
        assert_eq!(interleave_families(vec![v4(1), v4(2)]), vec![v4(1), v4(2)]);
        assert!(interleave_families(Vec::new()).is_empty());
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
