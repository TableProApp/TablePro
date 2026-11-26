use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Which copy of a store a file is, and how far its writes have gone (core ADR 0054, The engine).
///
/// The sync state keeps both beside its bases. Another generation means the file was restored,
/// replaced or copied in; a lower sequence means it went back in time. Either one puts the store's
/// kinds into refill. A write by any process that runs this code keeps the generation and raises the
/// sequence, so another app's change stays an edit; a hand edit keeps both.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StoreIdentity {
    pub generation: Uuid,
    pub sequence: u64,
}

impl StoreIdentity {
    pub fn fresh() -> Self {
        Self {
            generation: Uuid::new_v4(),
            sequence: 0,
        }
    }

    #[must_use]
    pub fn advanced(self) -> Self {
        Self {
            sequence: self.sequence.saturating_add(1),
            ..self
        }
    }

    /// The identity a write gives a file that had `before`: a file without one starts a generation.
    pub(crate) fn after_write(before: Option<Self>) -> Self {
        before.unwrap_or_else(Self::fresh).advanced()
    }

    /// What `self` says about a store the sync state last saw as `seen`.
    pub fn compared_with(self, seen: Self) -> StoreContinuity {
        if self.generation != seen.generation {
            StoreContinuity::NewGeneration
        } else if self.sequence < seen.sequence {
            StoreContinuity::WentBack
        } else {
            StoreContinuity::Continues
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreContinuity {
    /// The same file, with the writes seen and maybe more.
    Continues,
    /// Restored, replaced or copied in.
    NewGeneration,
    /// An older copy of the same file, as a Time Machine restore leaves.
    WentBack,
}

impl StoreContinuity {
    pub fn needs_refill(self) -> bool {
        !matches!(self, Self::Continues)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_write_keeps_the_generation_and_raises_the_sequence() {
        let first = StoreIdentity::after_write(None);
        let second = StoreIdentity::after_write(Some(first));

        assert_eq!(first.sequence, 1);
        assert_eq!(second.generation, first.generation);
        assert_eq!(second.sequence, 2);
        assert_eq!(second.compared_with(first), StoreContinuity::Continues);
    }

    #[test]
    fn an_older_copy_or_another_generation_needs_a_refill() {
        let seen = StoreIdentity::after_write(Some(StoreIdentity::after_write(None)));
        let older = StoreIdentity {
            sequence: seen.sequence - 1,
            ..seen
        };
        let other = StoreIdentity::after_write(None);

        assert_eq!(older.compared_with(seen), StoreContinuity::WentBack);
        assert_eq!(other.compared_with(seen), StoreContinuity::NewGeneration);
        assert!(older.compared_with(seen).needs_refill());
        assert!(other.compared_with(seen).needs_refill());
        assert!(!seen.compared_with(seen).needs_refill());
    }
}
