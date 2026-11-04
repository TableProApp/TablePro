use std::num::NonZeroU64;

/// How many rows one run keeps.
///
/// Zero is not a limit, it is a run that can return nothing, so it
/// cannot be built.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RowLimit(NonZeroU64);

impl RowLimit {
    /// What the editor uses unless the user says otherwise: enough to
    /// scroll through, small enough that a stray `SELECT *` on a large
    /// table does not fill memory.
    pub const EDITOR_DEFAULT: Self = Self(NonZeroU64::new(10_000).expect("10,000 is not zero"));

    /// The most every engine takes, for a run that must reach its end:
    /// PostgreSQL reads the count of its FETCH, the limit plus one, as a
    /// 32-bit integer.
    pub const LARGEST: Self = Self(NonZeroU64::new(i32::MAX as u64 - 1).expect("the largest limit is not zero"));

    pub fn new(rows: u64) -> Option<Self> {
        NonZeroU64::new(rows).map(Self)
    }

    pub fn get(self) -> u64 {
        self.0.get()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_limit_of_no_rows_cannot_be_built() {
        assert_eq!(RowLimit::new(0), None);
        assert_eq!(RowLimit::new(1).map(RowLimit::get), Some(1));
    }

    #[test]
    fn the_largest_limit_plus_one_still_fits_a_32_bit_count() {
        let count = RowLimit::LARGEST.get().saturating_add(1);

        assert!(i32::try_from(count).is_ok(), "{count}");
        assert!(RowLimit::LARGEST > RowLimit::EDITOR_DEFAULT);
    }

    #[test]
    fn the_editor_default_is_ten_thousand_rows() {
        assert_eq!(RowLimit::EDITOR_DEFAULT.get(), 10_000);
    }
}
