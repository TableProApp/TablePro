/// Which connection a signal or a result belongs to.
///
/// A reconnect replaces the connection and bumps this, so anything that
/// arrives late carries the generation it started under and is ignored
/// rather than applied to the connection that replaced it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct LinkGeneration(u64);

impl LinkGeneration {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_orders_after_the_one_it_came_from() {
        let first = LinkGeneration::FIRST;
        let second = first.next();

        assert!(second > first);
        assert_eq!(second.get(), 1);
    }

    #[test]
    fn next_saturates_rather_than_wrapping_back_to_a_live_generation() {
        let last = LinkGeneration::new(u64::MAX);

        assert_eq!(last.next(), last);
    }
}
