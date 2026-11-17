// Who owns the other end of a loopback TCP connection, from the socket table proc(5) describes as /proc/net/tcp.

use std::net::{Ipv4Addr, SocketAddrV4};

const LISTEN: &str = "0A";

struct Row<'a> {
    from: SocketAddrV4,
    to: SocketAddrV4,
    state: &'a str,
    uid: u32,
    inode: u64,
}

// Each row is from its socket's side, so the peer's has the peer as its local address and `local` as its remote.
pub(super) fn owner(table: &str, peer: SocketAddrV4, local: SocketAddrV4) -> Option<u32> {
    let rows = || table.lines().skip(1).filter_map(Row::parse);
    let connection = rows().find(|row| row.from == peer && row.to == local)?;
    if connection.inode != 0 {
        return Some(connection.uid);
    }
    // No process holds it, as while it waits to be accepted: the listener's. Before 6.17 it is listed as root's.
    rows()
        .find(|row| row.state == LISTEN && row.from == peer)
        .map(|listener| listener.uid)
}

impl<'a> Row<'a> {
    // `sl local_address rem_address st tx_queue:rx_queue tr:tm->when retrnsmt uid timeout inode ...`
    fn parse(line: &'a str) -> Option<Self> {
        let mut fields = line.split_ascii_whitespace();
        let _slot = fields.next()?;
        let from = parse_address(fields.next()?)?;
        let to = parse_address(fields.next()?)?;
        let state = fields.next()?;
        let uid = fields.nth(3)?.parse().ok()?;
        let inode = fields.nth(1)?.parse().ok()?;
        Some(Self {
            from,
            to,
            state,
            uid,
            inode,
        })
    }
}

// `0100007F:1F90`: the address as the kernel's 32-bit value in host byte order, then the port, both in hex.
fn parse_address(field: &str) -> Option<SocketAddrV4> {
    let (address, port) = field.split_once(':')?;
    let address = u32::from_str_radix(address, 16).ok()?;
    let port = u16::from_str_radix(port, 16).ok()?;
    Some(SocketAddrV4::new(Ipv4Addr::from(address.to_ne_bytes()), port))
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

        assert_eq!(owner(&table, loopback(50_000), loopback(8080)), Some(1234));
        assert_eq!(owner(&table, loopback(50_001), loopback(8080)), None);
    }

    // As kernel 6.8 lists them for uid 2001 before the server accepts: the server's end is root's, with no inode.
    #[test]
    fn a_connection_waiting_to_be_accepted_belongs_to_its_listener() {
        let hex = |address: SocketAddrV4| {
            format!(
                "{:08X}:{:04X}",
                u32::from_ne_bytes(address.ip().octets()),
                address.port()
            )
        };
        let row = |from: &str, to: &str, state: &str, uid: u32, inode: u64| {
            format!("   0: {from} {to} {state} 00000000:00000000 00:00000000 00000000 {uid:>5}        0 {inode}\n")
        };
        let (server, client) = (loopback(0x8EA7), loopback(0xBC88));
        let (server_hex, client_hex) = (hex(server), hex(client));
        let connection = row(&client_hex, &server_hex, "01", 2001, 540) + &row(&server_hex, &client_hex, "01", 0, 0);
        let listener = |uid| row(&server_hex, "00000000:0000", "0A", uid, 539);
        let table = |listener: &str| format!("  sl  local_address rem_address   st\n{listener}{connection}");

        assert_eq!(owner(&table(&listener(2001)), server, client), Some(2001));
        assert_eq!(owner(&table(&listener(1234)), server, client), Some(1234));
        assert_eq!(owner(&table(""), server, client), None);
    }
}
