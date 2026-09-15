/// Which change in the grid a write step came from.
///
/// A save is a list of statements, and when one fails the user has to
/// be told which row it was. This is how a step points back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChangeOrigin {
    Insert(usize),
    Update(usize),
    Delete(usize),
}
