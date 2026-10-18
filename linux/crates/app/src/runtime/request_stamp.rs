/// Which request a reply answers. Each one issued is newer than every
/// one before it, so a reply to an older request can be told apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RequestStamp(u64);

impl RequestStamp {
    pub(super) fn new(value: u64) -> Self {
        Self(value)
    }
}
