//! Who owns the other end of a loopback TCP connection, read from the
//! kernel's socket table as proc(5) describes `/proc/net/tcp`.

use std::io;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};

const TCP_TABLE: &str = "/proc/net/tcp";

/// The uid that owns the socket at `peer` connected to `local`, or
/// `None` when the table has no such row, as for a socket closed since.
pub(crate) fn loopback_peer_uid(peer: SocketAddrV4, local: SocketAddrV4) -> io::Result<Option<u32>> {
    let table = std::fs::read_to_string(TCP_TABLE)?;
    Ok(owner_in(&table, peer, local))
}

/// The table lists each socket from its own side, so the peer's row has
/// the peer as its local address and `local` as its remote one.
fn owner_in(table: &str, peer: SocketAddrV4, local: SocketAddrV4) -> Option<u32> {
    table.lines().skip(1).find_map(|line| {
        let mut fields = line.split_ascii_whitespace();
        let _slot = fields.next()?;
        let from = parse_address(fields.next()?)?;
        let to = parse_address(fields.next()?)?;
        if from != peer || to != local {
            return None;
        }
        let uid = fields.nth(4)?;
        uid.parse().ok()
    })
}

/// `0100007F:1F90`: the address as the kernel's 32-bit value in host
/// byte order, then the port, both in hex.
fn parse_address(field: &str) -> Option<SocketAddrV4> {
    let (address, port) = field.split_once(':')?;
    let address = u32::from_str_radix(address, 16).ok()?;
    let port = u16::from_str_radix(port, 16).ok()?;
    Some(SocketAddrV4::new(Ipv4Addr::from(address.to_ne_bytes()), port))
}

/// The process's own uid.
pub(crate) fn own_uid() -> u32 {
    rustix::process::getuid().as_raw()
}

/// Both ends as IPv4 loopback addresses, which is all the relay listens on.
pub(crate) fn as_v4(address: SocketAddr) -> Option<SocketAddrV4> {
    match address {
        SocketAddr::V4(address) => Some(address),
        SocketAddr::V6(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loopback(port: u16) -> SocketAddrV4 {
        SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)
    }

    #[test]
    fn the_peers_row_names_its_owner() {
        let local_hex = format!("{:08X}", u32::from_ne_bytes(Ipv4Addr::LOCALHOST.octets()));
        let table = format!(
            "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n\
             \x20  0: {local_hex}:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 11\n\
             \x20  1: {local_hex}:C350 {local_hex}:1F90 01 00000000:00000000 00:00000000 00000000  1234        0 12\n\
             \x20  2: {local_hex}:1F90 {local_hex}:C350 01 00000000:00000000 00:00000000 00000000  1000        0 13\n"
        );

        assert_eq!(owner_in(&table, loopback(50_000), loopback(8080)), Some(1234));
        assert_eq!(owner_in(&table, loopback(50_001), loopback(8080)), None);
    }

    #[test]
    fn a_connection_this_process_opens_is_its_own() {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let client = std::net::TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (_server, peer) = listener.accept().unwrap();

        let owner = loopback_peer_uid(as_v4(peer).unwrap(), as_v4(listener.local_addr().unwrap()).unwrap()).unwrap();

        assert_eq!(owner, Some(own_uid()));
        drop(client);
    }
}
