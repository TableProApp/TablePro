pub fn is_current(scheduled: u64, current: u64) -> bool {
    scheduled == current
}

pub fn replace_in_flight(
    current: &std::cell::RefCell<tokio_util::sync::CancellationToken>,
) -> tokio_util::sync::CancellationToken {
    current.borrow().cancel();
    let next = tokio_util::sync::CancellationToken::new();
    *current.borrow_mut() = next.clone();
    next
}

#[derive(Debug, Default)]
pub struct LatestApplied {
    issued: std::cell::Cell<u64>,
    applied: std::cell::Cell<u64>,
}

impl LatestApplied {
    pub fn begin(&self) -> u64 {
        let ticket = self.issued.get() + 1;
        self.issued.set(ticket);
        ticket
    }

    pub fn accept(&self, ticket: u64) -> bool {
        if ticket < self.applied.get() {
            return false;
        }
        self.applied.set(ticket);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cancelled_generation_must_not_apply() {
        assert!(!is_current(1, 2));
        assert!(!is_current(0, 1));
    }

    #[test]
    fn replacing_the_in_flight_token_cancels_the_previous_one_only() {
        let slot = std::cell::RefCell::new(tokio_util::sync::CancellationToken::new());
        let first = slot.borrow().clone();
        let second = replace_in_flight(&slot);
        assert!(first.is_cancelled());
        assert!(!second.is_cancelled());
        let third = replace_in_flight(&slot);
        assert!(second.is_cancelled());
        assert!(!third.is_cancelled());
    }

    #[test]
    fn a_matching_generation_applies() {
        assert!(is_current(0, 0));
        assert!(is_current(3, 3));
    }

    #[test]
    fn tickets_grow_with_every_request() {
        let order = LatestApplied::default();
        assert_eq!(order.begin(), 1);
        assert_eq!(order.begin(), 2);
        assert_eq!(order.begin(), 3);
    }

    #[test]
    fn a_slow_older_request_cannot_overwrite_a_newer_result() {
        let order = LatestApplied::default();
        let older = order.begin();
        let newer = order.begin();
        assert!(order.accept(newer));
        assert!(!order.accept(older));
    }

    #[test]
    fn results_arriving_in_request_order_all_apply() {
        let order = LatestApplied::default();
        let first = order.begin();
        let second = order.begin();
        assert!(order.accept(first));
        assert!(order.accept(second));
    }

    #[test]
    fn a_dropped_older_request_does_not_block_the_newer_one() {
        let order = LatestApplied::default();
        let _lost = order.begin();
        let kept = order.begin();
        assert!(order.accept(kept));
    }

    #[test]
    fn a_repeated_result_for_the_same_request_still_applies() {
        let order = LatestApplied::default();
        let ticket = order.begin();
        assert!(order.accept(ticket));
        assert!(order.accept(ticket));
    }
}
