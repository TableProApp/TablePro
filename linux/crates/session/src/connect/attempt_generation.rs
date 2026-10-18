/// Which connect attempt a result belongs to.
///
/// Separate from `LinkGeneration`: that counts established
/// connections, this counts tries, including the ones that never
/// connected.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct AttemptGeneration(u64);

impl AttemptGeneration {
    pub const FIRST: Self = Self(0);

    pub fn new(value: u64) -> Self {
        Self(value)
    }

    pub fn next(self) -> Self {
        Self(self.0.saturating_add(1))
    }

    pub fn get(self) -> u64 {
        self.0
    }
}
