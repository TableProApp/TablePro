use std::collections::BTreeSet;

/// The kinds of request whose last accepted reply was a failure, which
/// a view asks again for once the connection comes back.
#[derive(Debug, Clone)]
pub struct FailedRequests<K: Ord> {
    kinds: BTreeSet<K>,
}

impl<K: Ord + Copy> FailedRequests<K> {
    pub fn new() -> Self {
        Self { kinds: BTreeSet::new() }
    }

    /// Note how the request's last reply went.
    pub fn record<T, E>(&mut self, kind: K, outcome: &Result<T, E>) {
        match outcome {
            Ok(_) => self.kinds.remove(&kind),
            Err(_) => self.kinds.insert(kind),
        };
    }

    pub fn contains(&self, kind: K) -> bool {
        self.kinds.contains(&kind)
    }

    pub fn is_empty(&self) -> bool {
        self.kinds.is_empty()
    }

    /// Every failed kind, in order, leaving none behind. The caller asks
    /// for each again, and the replies record what happens next.
    pub fn take(&mut self) -> Vec<K> {
        std::mem::take(&mut self.kinds).into_iter().collect()
    }
}

impl<K: Ord + Copy> Default for FailedRequests<K> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failure_is_kept_until_the_kind_succeeds() {
        let mut failed = FailedRequests::new();

        failed.record(2, &Err::<(), ()>(()));
        failed.record(1, &Err::<(), ()>(()));
        assert!(failed.contains(2));
        failed.record(2, &Ok::<(), ()>(()));

        assert!(!failed.contains(2));
        assert_eq!(failed.take(), [1]);
        assert!(failed.is_empty());
    }
}
