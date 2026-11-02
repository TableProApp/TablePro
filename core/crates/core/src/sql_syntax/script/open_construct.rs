#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OpenConstruct {
    StringLiteral,
    QuotedIdentifier,
    BlockComment,
    DollarQuoted,
}
