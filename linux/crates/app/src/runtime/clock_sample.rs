use std::time::Duration;

/// Both clocks read at one moment. Monotonic time stops while the
/// machine is suspended and boot time does not, so the gap between them
/// grows by exactly the time spent asleep.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ClockSample {
    pub boottime: Duration,
    pub monotonic: Duration,
}
