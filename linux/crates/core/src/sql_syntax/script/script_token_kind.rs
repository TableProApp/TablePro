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
    Unterminated,
}

impl ScriptTokenKind {
    pub fn is_trivia(self) -> bool {
        matches!(self, Self::Whitespace | Self::LineComment | Self::BlockComment)
    }
}
