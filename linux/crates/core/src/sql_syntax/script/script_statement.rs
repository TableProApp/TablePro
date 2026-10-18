use std::ops::Range;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ScriptStatement {
    pub range: Range<usize>,
    pub extent: Range<usize>,
}

impl ScriptStatement {
    pub fn text<'a>(&self, source: &'a str) -> &'a str {
        source.get(self.range.clone()).unwrap_or_default()
    }
}
