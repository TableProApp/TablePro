#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScriptTokenKind {
    Whitespace,
    LineComment,
    BlockComment,
    StringLiteral,
    QuotedIdentifier,
    DollarQuoted,
    Word,
    Number,
    Semicolon,
    OpenParen,
    CloseParen,
    Punct,
    Directive,
    /// The `/*!50100` that opens a MySQL executable comment, or the `*/`
    /// that closes it. What stands between the two is code.
    ExecutableMarker,
    Unterminated,
}

impl ScriptTokenKind {
    pub fn is_trivia(self) -> bool {
        matches!(self, Self::Whitespace | Self::LineComment | Self::BlockComment)
    }
}
