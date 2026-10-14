use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use crate::runtime::{ClockSample, ClockSource};

/// Clocks the test moves by hand.
#[derive(Clone, Default)]
pub(crate) struct FakeClocks(Rc<Cell<ClockSample>>);

impl FakeClocks {
    pub(crate) fn advance(&self, boottime: u64, monotonic: u64) {
        let now = self.0.get();
        self.0.set(ClockSample {
            boottime: now.boottime + Duration::from_secs(boottime),
            monotonic: now.monotonic + Duration::from_secs(monotonic),
        });
    }
}

impl ClockSource for FakeClocks {
    fn sample(&self) -> ClockSample {
        self.0.get()
    }
}
