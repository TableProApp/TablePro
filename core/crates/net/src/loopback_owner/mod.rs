use std::io;
use std::net::{SocketAddr, SocketAddrV4};

#[cfg(any(target_os = "linux", test))]
mod proc_net_tcp;
#[cfg(any(windows, test))]
mod tcp_table;

// Ours is this user's on Linux and this process's on Windows, the owner each socket table records. Blocks.
pub fn loopback_peer_is_ours(peer: SocketAddr, local: SocketAddr) -> io::Result<bool> {
    let (SocketAddr::V4(peer), SocketAddr::V4(local)) = (peer, local) else {
        return Ok(false);
    };
    owned_here(peer, local)
}

#[cfg(target_os = "linux")]
fn owned_here(peer: SocketAddrV4, local: SocketAddrV4) -> io::Result<bool> {
    let table = std::fs::read_to_string("/proc/net/tcp")?;
    Ok(proc_net_tcp::owner(&table, peer, local) == Some(rustix::process::getuid().as_raw()))
}

#[cfg(windows)]
fn owned_here(peer: SocketAddrV4, local: SocketAddrV4) -> io::Result<bool> {
    let table = tcp_table::connections()?;
    Ok(tcp_table::owner(&table, peer, local) == Some(std::process::id()))
}

#[cfg(not(any(target_os = "linux", windows)))]
fn owned_here(_peer: SocketAddrV4, _local: SocketAddrV4) -> io::Result<bool> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "only Linux and Windows name the owner of a loopback connection",
    ))
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::*;

    #[cfg(any(target_os = "linux", windows))]
    #[test]
    fn a_connection_this_process_opens_is_its_own() {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let client = std::net::TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (_server, peer) = listener.accept().unwrap();

        assert!(loopback_peer_is_ours(peer, listener.local_addr().unwrap()).unwrap());
        drop(client);
    }

    #[cfg(not(any(target_os = "linux", windows)))]
    #[test]
    fn other_systems_name_no_owner() {
        let peer = SocketAddr::from((Ipv4Addr::LOCALHOST, 50_000));
        let local = SocketAddr::from((Ipv4Addr::LOCALHOST, 8080));

        let error = loopback_peer_is_ours(peer, local).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::Unsupported);
    }

    #[test]
    fn an_ipv6_peer_is_never_ours() {
        let peer = SocketAddr::from((std::net::Ipv6Addr::LOCALHOST, 50_000));
        let local = SocketAddr::from((Ipv4Addr::LOCALHOST, 8080));

        assert!(!loopback_peer_is_ours(peer, local).unwrap());
    }
}
