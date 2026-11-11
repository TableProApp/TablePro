// The uid owning each end of a loopback connection, from /proc/net/tcp,
// and /proc/net/tcp6 for a v4-mapped IPv6 socket such as Java's.

use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PeerOwner {
    Same,
    Other,
    Unknown,
}

// A socket in TIME_WAIT keeps its addresses but is listed with uid 0.
const TIME_WAIT: &str = "06";

#[cfg(target_os = "linux")]
const TABLES: [&str; 2] = ["/proc/net/tcp", "/proc/net/tcp6"];

// Blocking: reads the kernel's tables.
#[cfg(target_os = "linux")]
pub(crate) fn owner_of(server: SocketAddrV4, peer: SocketAddrV4) -> PeerOwner {
    let tables: Vec<String> = TABLES
        .iter()
        .filter_map(|path| std::fs::read_to_string(path).ok())
        .collect();
    let tables: Vec<&str> = tables.iter().map(String::as_str).collect();
    owner(&tables, server, peer)
}

// The server's own end gives the uid to compare, mapped through the same
// user namespace as the peer's, as inside the Flatpak.
pub(crate) fn owner(tables: &[&str], server: SocketAddrV4, peer: SocketAddrV4) -> PeerOwner {
    let mut ours = None;
    let mut theirs = None;
    for socket in tables.iter().flat_map(|table| table.lines()).filter_map(Socket::parse) {
        if socket.state == TIME_WAIT {
            continue;
        }
        if socket.local == server && socket.remote == peer {
            ours = Some(socket.uid);
        } else if socket.local == peer && socket.remote == server {
            theirs = Some(socket.uid);
        }
    }
    match (ours, theirs) {
        (Some(ours), Some(theirs)) if ours == theirs => PeerOwner::Same,
        (Some(_), Some(_)) => PeerOwner::Other,
        _ => PeerOwner::Unknown,
    }
}

struct Socket<'a> {
    local: SocketAddrV4,
    remote: SocketAddrV4,
    state: &'a str,
    uid: u32,
}

impl<'a> Socket<'a> {
    // `sl local_address rem_address st tx:rx tr:when retrnsmt uid ...`;
    // the header line and IPv6 sockets with no IPv4 address give None.
    fn parse(line: &'a str) -> Option<Self> {
        let fields: Vec<&str> = line.split_whitespace().collect();
        Some(Self {
            local: address(fields.get(1)?)?,
            remote: address(fields.get(2)?)?,
            state: fields.get(3)?,
            uid: fields.get(7)?.parse().ok()?,
        })
    }
}

// The kernel prints each 32-bit word of the address as the number its
// bytes make in the host's order, and the port as a plain number.
fn address(text: &str) -> Option<SocketAddrV4> {
    let (host, port) = text.split_once(':')?;
    let port = u16::from_str_radix(port, 16).ok()?;
    let ip = match host.len() {
        8 => Ipv4Addr::from(word(host)?),
        32 => {
            let mut bytes = [0u8; 16];
            for (index, chunk) in bytes.as_chunks_mut::<4>().0.iter_mut().enumerate() {
                *chunk = word(host.get(index * 8..index * 8 + 8)?)?;
            }
            Ipv6Addr::from(bytes).to_ipv4_mapped()?
        }
        _ => return None,
    };
    Some(SocketAddrV4::new(ip, port))
}

fn word(digits: &str) -> Option<[u8; 4]> {
    if !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    u32::from_str_radix(digits, 16).ok().map(u32::to_ne_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEADER: &str =
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode";

    fn server() -> SocketAddrV4 {
        SocketAddrV4::new(Ipv4Addr::LOCALHOST, 23508)
    }

    fn peer() -> SocketAddrV4 {
        SocketAddrV4::new(Ipv4Addr::LOCALHOST, 53924)
    }

    fn hex_word(bytes: [u8; 4]) -> String {
        format!("{:08X}", u32::from_ne_bytes(bytes))
    }

    fn v4(address: SocketAddrV4) -> String {
        format!("{}:{:04X}", hex_word(address.ip().octets()), address.port())
    }

    fn mapped(address: SocketAddrV4) -> String {
        format!(
            "{}{}{}{}:{:04X}",
            hex_word([0; 4]),
            hex_word([0; 4]),
            hex_word([0, 0, 0xff, 0xff]),
            hex_word(address.ip().octets()),
            address.port()
        )
    }

    fn line(local: &str, remote: &str, state: &str, uid: u32) -> String {
        format!(
            "   3: {local} {remote} {state} 00000000:00000000 00:00000000 00000000  {uid}        0 48211 1 \
0000000000000000 20 4 30 10 -1"
        )
    }

    fn table(lines: &[String]) -> String {
        std::iter::once(HEADER.to_owned())
            .chain(lines.iter().cloned())
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn a_peer_of_the_same_account_is_the_same_owner() {
        let tcp = table(&[
            line(&v4(server()), "00000000:0000", "0A", 1000),
            line(&v4(server()), &v4(peer()), "01", 1000),
            line(&v4(peer()), &v4(server()), "01", 1000),
        ]);

        assert_eq!(owner(&[&tcp], server(), peer()), PeerOwner::Same);
    }

    #[test]
    fn a_peer_of_another_account_is_another_owner() {
        let tcp = table(&[
            line(&v4(server()), &v4(peer()), "01", 1000),
            line(&v4(peer()), &v4(server()), "01", 1001),
        ]);

        assert_eq!(owner(&[&tcp], server(), peer()), PeerOwner::Other);
    }

    #[test]
    fn a_peer_missing_from_the_tables_is_unknown() {
        let tcp = table(&[line(&v4(server()), &v4(peer()), "01", 1000)]);
        let only_time_wait = table(&[
            line(&v4(server()), &v4(peer()), "01", 1000),
            line(&v4(peer()), &v4(server()), TIME_WAIT, 0),
        ]);

        assert_eq!(owner(&[&tcp], server(), peer()), PeerOwner::Unknown);
        assert_eq!(owner(&[&only_time_wait], server(), peer()), PeerOwner::Unknown);
        assert_eq!(owner(&[], server(), peer()), PeerOwner::Unknown);
        assert_eq!(owner(&["garbage\n1: x y"], server(), peer()), PeerOwner::Unknown);
    }

    #[test]
    fn a_peer_on_an_ipv6_socket_is_found_through_its_mapped_address() {
        let tcp = table(&[line(&v4(server()), &v4(peer()), "01", 1000)]);
        let tcp6 = table(&[line(&mapped(peer()), &mapped(server()), "01", 1000)]);
        let other6 = table(&[line(&mapped(peer()), &mapped(server()), "01", 65534)]);

        assert_eq!(owner(&[&tcp, &tcp6], server(), peer()), PeerOwner::Same);
        assert_eq!(owner(&[&tcp, &other6], server(), peer()), PeerOwner::Other);
    }

    #[cfg(target_endian = "little")]
    #[test]
    fn a_line_as_the_kernel_prints_it_is_read() {
        let socket = Socket::parse(
            "   0: 0100007F:5BD4 0100007F:D2A4 01 00000000:00000000 00:00000000 00000000  1000        0 9",
        )
        .expect("a socket");

        assert_eq!(socket.local, server());
        assert_eq!(socket.remote, peer());
        assert_eq!(socket.uid, 1000);
        assert!(Socket::parse(HEADER).is_none());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_connection_from_this_process_is_the_same_owner() {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("a listener");
        let client = std::net::TcpStream::connect(listener.local_addr().expect("an address")).expect("a connection");
        let (accepted, _) = listener.accept().expect("the connection");
        let (std::net::SocketAddr::V4(server), std::net::SocketAddr::V4(peer)) = (
            accepted.local_addr().expect("an address"),
            accepted.peer_addr().expect("an address"),
        ) else {
            panic!("an IPv4 connection");
        };

        assert_eq!(owner_of(server, peer), PeerOwner::Same);
        drop(client);
    }
}
