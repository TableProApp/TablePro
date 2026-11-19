use std::io;
use std::net::{SocketAddr, SocketAddrV4};

#[cfg(any(target_os = "linux", test))]
mod proc_net_tcp;
#[cfg(any(windows, test))]
mod tcp_table;
#[cfg(windows)]
mod token_user;

// Ours is this user's on Linux and this process's on Windows, the owner each socket table records. Blocks.
pub fn loopback_peer_is_ours(peer: SocketAddr, local: SocketAddr) -> io::Result<bool> {
    let (SocketAddr::V4(peer), SocketAddr::V4(local)) = (peer, local) else {
        return Ok(false);
    };
    owned_here(peer, local)
}

// Run by this user, whatever the process: Linux's socket uid, or the Windows owning process's token user. Blocks.
pub fn loopback_peer_is_this_user(peer: SocketAddr, local: SocketAddr) -> io::Result<bool> {
    let (SocketAddr::V4(peer), SocketAddr::V4(local)) = (peer, local) else {
        return Ok(false);
    };
    this_users(peer, local)
}

// A process this user may not open, as another user's, is not this user's. Blocks.
#[cfg(windows)]
pub fn process_runs_as_this_user(pid: u32) -> io::Result<bool> {
    token_user::runs_as_this_user(pid)
}

// The process at the other end of a loopback connection, by GetExtendedTcpTable; None when no row names it. Blocks.
#[cfg(windows)]
pub fn loopback_peer_process(peer: SocketAddr, local: SocketAddr) -> io::Result<Option<u32>> {
    let (SocketAddr::V4(peer), SocketAddr::V4(local)) = (peer, local) else {
        return Ok(None);
    };
    Ok(tcp_table::owner(&tcp_table::connections()?, peer, local))
}

#[cfg(target_os = "linux")]
fn this_users(peer: SocketAddrV4, local: SocketAddrV4) -> io::Result<bool> {
    owned_here(peer, local)
}

#[cfg(windows)]
fn this_users(peer: SocketAddrV4, local: SocketAddrV4) -> io::Result<bool> {
    match loopback_peer_process(SocketAddr::V4(peer), SocketAddr::V4(local))? {
        Some(pid) => token_user::runs_as_this_user(pid),
        None => Ok(false),
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
fn this_users(peer: SocketAddrV4, local: SocketAddrV4) -> io::Result<bool> {
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

    // The command line's question: the server's end, before the server accepts it.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_connection_waiting_to_be_accepted_is_its_own() {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let client = std::net::TcpStream::connect(listener.local_addr().unwrap()).unwrap();

        assert!(loopback_peer_is_ours(client.peer_addr().unwrap(), client.local_addr().unwrap()).unwrap());
    }

    // The client's end, as a server checks it, and the server's before it accepts, as the command line checks it.
    #[cfg(any(target_os = "linux", windows))]
    #[test]
    fn both_ends_of_a_connection_this_process_opens_are_this_users() {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let client = std::net::TcpStream::connect(listener.local_addr().unwrap()).unwrap();

        assert!(loopback_peer_is_this_user(client.peer_addr().unwrap(), client.local_addr().unwrap()).unwrap());
        let (_server, peer) = listener.accept().unwrap();
        assert!(loopback_peer_is_this_user(peer, listener.local_addr().unwrap()).unwrap());
        drop(client);
    }

    // The command line's question on Windows: which process listens, before it accepts.
    #[cfg(windows)]
    #[test]
    fn the_listening_end_names_this_process_before_it_accepts() {
        let listener = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let client = std::net::TcpStream::connect(listener.local_addr().unwrap()).unwrap();

        let owner = loopback_peer_process(client.peer_addr().unwrap(), client.local_addr().unwrap()).unwrap();

        assert_eq!(owner, Some(std::process::id()));
        drop(client);
    }

    #[cfg(any(target_os = "linux", windows))]
    #[test]
    fn a_peer_no_table_lists_is_not_this_users() {
        let peer = SocketAddr::from((Ipv4Addr::LOCALHOST, 9));
        let local = SocketAddr::from((Ipv4Addr::LOCALHOST, 7));

        assert!(!loopback_peer_is_this_user(peer, local).unwrap());
    }

    #[cfg(not(any(target_os = "linux", windows)))]
    #[test]
    fn other_systems_name_no_owner() {
        let peer = SocketAddr::from((Ipv4Addr::LOCALHOST, 50_000));
        let local = SocketAddr::from((Ipv4Addr::LOCALHOST, 8080));

        let error = loopback_peer_is_ours(peer, local).unwrap_err();
        let user = loopback_peer_is_this_user(peer, local).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::Unsupported);
        assert_eq!(user.kind(), io::ErrorKind::Unsupported);
    }

    #[test]
    fn an_ipv6_peer_is_never_ours() {
        let peer = SocketAddr::from((std::net::Ipv6Addr::LOCALHOST, 50_000));
        let local = SocketAddr::from((Ipv4Addr::LOCALHOST, 8080));

        assert!(!loopback_peer_is_ours(peer, local).unwrap());
        assert!(!loopback_peer_is_this_user(peer, local).unwrap());
    }
}
