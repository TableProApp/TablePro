use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LivenessPolicy {
    pub connect_timeout: Duration,
    pub login_timeout: Duration,
    pub tcp_keepalive_idle: Duration,
    pub tcp_keepalive_interval: Duration,
    pub tcp_keepalive_retries: u32,
    pub tcp_user_timeout: Duration,
    pub probe_timeout: Duration,
    pub pool_wait: Duration,
    pub cancel_grace: Duration,
    pub ssh_handshake_timeout: Duration,
    pub ssh_channel_open_timeout: Duration,
    pub ssh_keepalive_interval: Duration,
    pub ssh_keepalive_max: u32,
    pub close_timeout: Duration,
}

impl LivenessPolicy {
    pub const DESKTOP: Self = Self {
        connect_timeout: Duration::from_secs(10),
        login_timeout: Duration::from_secs(15),
        tcp_keepalive_idle: Duration::from_secs(30),
        tcp_keepalive_interval: Duration::from_secs(10),
        tcp_keepalive_retries: 3,
        tcp_user_timeout: Duration::from_secs(45),
        probe_timeout: Duration::from_secs(5),
        pool_wait: Duration::from_secs(5),
        cancel_grace: Duration::from_secs(5),
        ssh_handshake_timeout: Duration::from_secs(20),
        ssh_channel_open_timeout: Duration::from_secs(10),
        ssh_keepalive_interval: Duration::from_secs(15),
        ssh_keepalive_max: 3,
        close_timeout: Duration::from_secs(10),
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktop_values_match_contract() {
        let policy = LivenessPolicy::DESKTOP;
        let seconds = [
            policy.connect_timeout,
            policy.login_timeout,
            policy.tcp_keepalive_idle,
            policy.tcp_keepalive_interval,
            policy.tcp_user_timeout,
            policy.probe_timeout,
            policy.pool_wait,
            policy.cancel_grace,
            policy.ssh_handshake_timeout,
            policy.ssh_channel_open_timeout,
            policy.ssh_keepalive_interval,
            policy.close_timeout,
        ]
        .map(|duration| duration.as_secs());
        assert_eq!(seconds, [10, 15, 30, 10, 45, 5, 5, 5, 20, 10, 15, 10]);
        assert_eq!(policy.tcp_keepalive_retries, 3);
        assert_eq!(policy.ssh_keepalive_max, 3);
    }
}
