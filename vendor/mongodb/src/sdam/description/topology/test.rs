mod event;
mod rtt;
mod sdam;

use std::time::Duration;

pub use event::TestSdamEvent;

use crate::bson_util::round_clamp;

pub(crate) fn f64_ms_as_duration(f: f64) -> Duration {
    Duration::from_micros(round_clamp(f * 1000.0))
}
