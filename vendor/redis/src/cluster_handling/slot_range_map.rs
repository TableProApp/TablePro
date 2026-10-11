use std::collections::BTreeMap;

/// A generic map from non-overlapping `(start, end)` slot ranges to values,
/// backed by a [`BTreeMap`] keyed on range end for O(log n) point lookup.
#[derive(Debug, Clone)]
pub(crate) struct SlotRangeMap<V> {
    inner: BTreeMap<u16, (u16, V)>, // end → (start, value)
}

impl<V> SlotRangeMap<V> {
    pub fn new() -> Self {
        Self {
            inner: BTreeMap::new(),
        }
    }

    /// Insert a value for the slot range `[start, end]` (inclusive).
    pub fn insert(&mut self, start: u16, end: u16, value: V) {
        self.inner.insert(end, (start, value));
    }

    /// Look up the value whose range contains `slot`, if any.
    pub fn get(&self, slot: u16) -> Option<&V> {
        self.inner
            .range(slot..)
            .next()
            .and_then(|(_, (start, v))| (slot >= *start).then_some(v))
    }

    /// Iterate over all values (one per range entry, in slot order).
    pub fn values(&self) -> impl Iterator<Item = &V> {
        self.inner.values().map(|(_, v)| v)
    }

    /// Iterate over `(start, end, &value)` triples in slot order.
    pub fn iter(&self) -> impl Iterator<Item = (u16, u16, &V)> {
        self.inner.iter().map(|(&end, (start, v))| (*start, end, v))
    }

    #[cfg(feature = "cluster-async")]
    pub fn clear(&mut self) {
        self.inner.clear();
    }
}

impl<V> Default for SlotRangeMap<V> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn point_lookup_within_range() {
        let mut m = SlotRangeMap::new();
        m.insert(100, 200, "a");
        m.insert(300, 400, "b");

        assert_eq!(m.get(100), Some(&"a"));
        assert_eq!(m.get(150), Some(&"a"));
        assert_eq!(m.get(200), Some(&"a"));
        assert_eq!(m.get(300), Some(&"b"));
        assert_eq!(m.get(350), Some(&"b"));
        assert_eq!(m.get(400), Some(&"b"));
    }

    #[test]
    fn point_lookup_in_gaps_returns_none() {
        let mut m = SlotRangeMap::new();
        m.insert(100, 200, "a");
        m.insert(300, 400, "b");

        assert_eq!(m.get(99), None);
        assert_eq!(m.get(250), None);
        assert_eq!(m.get(401), None);
    }

    #[test]
    fn iter_yields_ranges_in_order() {
        let mut m = SlotRangeMap::new();
        m.insert(300, 400, "b");
        m.insert(100, 200, "a");

        let entries: Vec<_> = m.iter().collect();
        assert_eq!(entries, vec![(100, 200, &"a"), (300, 400, &"b")]);
    }
}
