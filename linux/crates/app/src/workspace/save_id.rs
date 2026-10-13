/// One save from the moment it starts to the moment it settles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SaveId(u64);

impl SaveId {
    pub(super) fn new(value: u64) -> Self {
        Self(value)
    }
}
