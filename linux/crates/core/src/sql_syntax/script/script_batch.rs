use std::num::NonZeroU32;
use std::ops::Range;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ScriptBatch {
    pub range: Range<usize>,
    pub repeat: NonZeroU32,
    pub statements: Range<usize>,
}
