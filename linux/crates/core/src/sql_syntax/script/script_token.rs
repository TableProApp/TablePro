use std::ops::Range;

use crate::sql_syntax::script::ScriptTokenKind;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ScriptToken {
    pub kind: ScriptTokenKind,
    pub range: Range<usize>,
}
