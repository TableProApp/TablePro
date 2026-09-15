use super::ChangeOrigin;

/// The statements a save will run, each pointing back at the change it
/// came from.
///
/// `origins` is the same length as the batch's steps and in the same
/// order, so a failure at step 3 names the row the user edited rather
/// than a statement number.
#[derive(Debug, Clone, PartialEq)]
pub struct SavePlan<B> {
    pub batch: B,
    pub origins: Vec<ChangeOrigin>,
}

impl<B> SavePlan<B> {
    pub fn origin(&self, step: usize) -> Option<ChangeOrigin> {
        self.origins.get(step).copied()
    }
}
