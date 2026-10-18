use std::time::Duration;

use tablepro_core::LivenessPolicy;

/// The desktop policy with the bounds a case waits on cut short, so a
/// suite fails in seconds rather than minutes. The connect and login
/// timeouts stay at the desktop values, because a container under load
/// can be slow to accept and that is not what these cases test.
pub fn test_liveness() -> LivenessPolicy {
    LivenessPolicy {
        probe_timeout: Duration::from_secs(2),
        pool_wait: Duration::from_secs(1),
        cancel_grace: Duration::from_secs(1),
        ..LivenessPolicy::DESKTOP
    }
}
