use tablepro_core::meta::RowCountEstimate;

/// Up to this many rows, a count costs little enough to run on its own.
pub(crate) const AUTO_COUNT_MAX_ROWS: u64 = 100_000;

/// What the paginator does with the server's estimate of the table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CountAction {
    UseExact(u64),
    /// Show the estimate, and offer the count.
    UseEstimate(u64),
    /// Count now: the table is small enough that it bounds the count.
    CountNow,
    /// Offer the count and run nothing until the user asks.
    OfferCount,
}

/// `estimate` is the whole table's, so under a filter it says only how
/// large a count could get: no total is shown from it, and a small table
/// is still counted.
pub(crate) fn decide(estimate: Result<RowCountEstimate, ()>, filtered: bool) -> CountAction {
    match (estimate, filtered) {
        (Ok(RowCountEstimate::Exact(rows)), false) => CountAction::UseExact(rows),
        (Ok(RowCountEstimate::Exact(rows) | RowCountEstimate::Approximate(rows)), _) if rows <= AUTO_COUNT_MAX_ROWS => {
            CountAction::CountNow
        }
        (Ok(RowCountEstimate::Approximate(rows)), false) => CountAction::UseEstimate(rows),
        (Ok(_), _) | (Err(()), _) => CountAction::OfferCount,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn count_policy_table() {
        let small = AUTO_COUNT_MAX_ROWS;
        let large = AUTO_COUNT_MAX_ROWS + 1;
        let cases = [
            (Ok(RowCountEstimate::Exact(7)), false, CountAction::UseExact(7)),
            (Ok(RowCountEstimate::Exact(large)), false, CountAction::UseExact(large)),
            (Ok(RowCountEstimate::Approximate(small)), false, CountAction::CountNow),
            (
                Ok(RowCountEstimate::Approximate(large)),
                false,
                CountAction::UseEstimate(large),
            ),
            (Ok(RowCountEstimate::Unknown), false, CountAction::OfferCount),
            (Err(()), false, CountAction::OfferCount),
            (Ok(RowCountEstimate::Exact(7)), true, CountAction::CountNow),
            (Ok(RowCountEstimate::Exact(large)), true, CountAction::OfferCount),
            (Ok(RowCountEstimate::Approximate(small)), true, CountAction::CountNow),
            (Ok(RowCountEstimate::Approximate(large)), true, CountAction::OfferCount),
            (Ok(RowCountEstimate::Unknown), true, CountAction::OfferCount),
            (Err(()), true, CountAction::OfferCount),
        ];
        for (estimate, filtered, expected) in cases {
            assert_eq!(
                decide(estimate, filtered),
                expected,
                "{estimate:?}, filtered {filtered}"
            );
        }
    }
}
