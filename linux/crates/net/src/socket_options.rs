use std::io;

use socket2::{SockRef, TcpKeepalive};
use tablepro_core::LivenessPolicy;
use tokio::net::TcpStream;

pub(crate) fn apply_socket_options(stream: &TcpStream, liveness: &LivenessPolicy) -> io::Result<()> {
    stream.set_nodelay(true)?;
    let socket = SockRef::from(stream);
    let keepalive = TcpKeepalive::new()
        .with_time(liveness.tcp_keepalive_idle)
        .with_interval(liveness.tcp_keepalive_interval)
        .with_retries(liveness.tcp_keepalive_retries);
    socket.set_tcp_keepalive(&keepalive)?;
    socket.set_tcp_user_timeout(Some(liveness.tcp_user_timeout))
}

#[cfg(test)]
mod tests {
    use socket2::SockRef;

    use super::*;

    #[tokio::test]
    async fn socket_options_read_back() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let stream = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
        let liveness = LivenessPolicy::DESKTOP;

        apply_socket_options(&stream, &liveness).unwrap();

        let socket = SockRef::from(&stream);
        assert!(stream.nodelay().unwrap());
        assert!(socket.keepalive().unwrap());
        assert_eq!(socket.tcp_keepalive_time().unwrap(), liveness.tcp_keepalive_idle);
        assert_eq!(
            socket.tcp_keepalive_interval().unwrap(),
            liveness.tcp_keepalive_interval
        );
        assert_eq!(socket.tcp_keepalive_retries().unwrap(), liveness.tcp_keepalive_retries);
        assert_eq!(socket.tcp_user_timeout().unwrap(), Some(liveness.tcp_user_timeout));
    }
}
