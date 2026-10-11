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
}
