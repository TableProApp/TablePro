use crate::write_batch::WriteBatch;

/// The statements a save will run, each pointing back at the change it
/// came from.
///
/// `origins` is the same length as the batch's steps and in the same
/// order, and each entry is a position in `ChangeSet::changes`, so a
/// failure at step 3 names the row the user edited rather than a
/// statement number.
#[derive(Debug, Clone, PartialEq)]
pub struct SavePlan {
    pub batch: WriteBatch,
    pub origins: Vec<usize>,
}

impl SavePlan {
    /// The position in the change set behind one step.
    pub fn origin(&self, step: usize) -> Option<usize> {
        self.origins.get(step).copied()
    }
}
