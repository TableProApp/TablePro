namespace TablePro.Core.Sql;

public enum SqlTokenKind : byte
{
    Whitespace,
    LineComment,
    BlockComment,
    String,
    QuotedIdentifier,
    Number,
    Word,
    Parameter,
    Operator,
    Semicolon,
    OpenParen,
    CloseParen,
    Comma,
    Dot,
}

/// <summary>A lexed range of the source text. Offsets are in UTF-16 code units, as the editor counts them.</summary>
public readonly record struct SqlToken(SqlTokenKind Kind, int Start, int Length, bool IsUnterminated = false)
{
    public int End => Start + Length;

    public bool IsTrivia => Kind is SqlTokenKind.Whitespace or SqlTokenKind.LineComment or SqlTokenKind.BlockComment;

    public ReadOnlySpan<char> Slice(ReadOnlySpan<char> text) => text.Slice(Start, Length);
}

/// <summary>The lexical rules that differ between engines.</summary>
[Flags]
public enum SqlLexerFeatures
{
    None = 0,
    BacktickIdentifiers = 1 << 0,
    BracketIdentifiers = 1 << 1,
    DollarQuotes = 1 << 2,
    HashComments = 1 << 3,
    BackslashEscapes = 1 << 4,
    NestedBlockComments = 1 << 5,
    DoubleQuotedStrings = 1 << 6,

    /// <summary>MySQL only treats <c>--</c> as a comment when whitespace or the end of the text follows it.</summary>
    DashCommentNeedsSpace = 1 << 7,
}
