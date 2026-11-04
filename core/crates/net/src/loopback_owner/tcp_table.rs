use std::net::{Ipv4Addr, SocketAddrV4};

// MIB_TCPROW_OWNER_PID: state, local address, local port, remote address, remote port, owning pid.
const ROW_WORDS: usize = 6;

#[cfg(windows)]
const _: () = assert!(
    size_of::<windows_sys::Win32::NetworkManagement::IpHelper::MIB_TCPROW_OWNER_PID>() == ROW_WORDS * size_of::<u32>()
);

#[cfg(windows)]
const ATTEMPTS: usize = 4;

// The IPv4 connections with their owning pids, as the MIB_TCPTABLE_OWNER_PID words GetExtendedTcpTable fills.
#[cfg(windows)]
pub(super) fn connections() -> std::io::Result<Vec<u32>> {
    use std::io;

    use windows_sys::Win32::Foundation::{ERROR_INSUFFICIENT_BUFFER, FALSE, NO_ERROR};
    use windows_sys::Win32::NetworkManagement::IpHelper::{GetExtendedTcpTable, TCP_TABLE_OWNER_PID_CONNECTIONS};
    use windows_sys::Win32::Networking::WinSock::AF_INET;

    let mut bytes: u32 = 0;
    // The first call sizes the table, which can grow before the next one fills it.
    for _ in 0..ATTEMPTS {
        let mut table = vec![0_u32; usize::try_from(bytes).map_err(io::Error::other)?.div_ceil(4)];
        let buffer: *mut core::ffi::c_void = if table.is_empty() {
            std::ptr::null_mut()
        } else {
            table.as_mut_ptr().cast()
        };
        // SAFETY: `buffer` is null while `bytes` is 0, else `table`: u32-aligned like the rows, `bytes` long or more.
        let status = unsafe {
            GetExtendedTcpTable(
                buffer,
                &mut bytes,
                FALSE,
                u32::from(AF_INET),
                TCP_TABLE_OWNER_PID_CONNECTIONS,
                0,
            )
        };
        match status {
            NO_ERROR => return Ok(table),
            ERROR_INSUFFICIENT_BUFFER => {}
            error => return Err(io::Error::from_raw_os_error(error.cast_signed())),
        }
    }
    Err(io::Error::other("the TCP table kept growing while it was read"))
}

// Each row is from its socket's side, so the peer's has the peer as its local end and `local` as its remote.
pub(super) fn owner(table: &[u32], peer: SocketAddrV4, local: SocketAddrV4) -> Option<u32> {
    let (&count, rows) = table.split_first()?;
    let count = usize::try_from(count).ok()?;
    let (rows, _) = rows.as_chunks::<ROW_WORDS>();
    rows.iter()
        .take(count)
        .find_map(|&[_state, from, from_port, to, to_port, pid]| {
            (endpoint(from, from_port) == peer && endpoint(to, to_port) == local).then_some(pid)
        })
}

// Both in network byte order; only the port's low 16 bits are set, the rest may be garbage.
fn endpoint(address: u32, port: u32) -> SocketAddrV4 {
    SocketAddrV4::new(Ipv4Addr::from(address.to_ne_bytes()), u16::from_be(port as u16))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(from: u16, to: u16, pid: u32) -> [u32; ROW_WORDS] {
        let loopback = u32::from_ne_bytes(Ipv4Addr::LOCALHOST.octets());
        let port = |port: u16| u32::from(port.to_be()) | 0xBEEF_0000;
        [5, loopback, port(from), loopback, port(to), pid]
    }

    fn loopback(port: u16) -> SocketAddrV4 {
        SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)
    }

    #[test]
    fn the_peers_row_names_its_process() {
        let mut table = vec![3];
        table.extend(row(8080, 50_000, 7));
        table.extend(row(50_000, 8080, 4242));
        table.extend(row(50_002, 8080, 9));
        table.extend(row(50_003, 8080, 11));

        assert_eq!(owner(&table, loopback(50_000), loopback(8080)), Some(4242));
        assert_eq!(owner(&table, loopback(50_001), loopback(8080)), None);
        assert_eq!(
            owner(&table, loopback(50_003), loopback(8080)),
            None,
            "a row past the entry count is not read"
        );
        assert_eq!(owner(&[], loopback(50_000), loopback(8080)), None);
    }
}
