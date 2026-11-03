using System.Buffers;
using TablePro.Interop.Native;

namespace TablePro.Interop;

// The core's codes for tablepro_syntax_tokens follow these declaration orders.
public enum SqlGrammar
{
    PostgreSql,
    MySql,
    Sqlite,
    MsSql,
    ClickHouse,
    DuckDb,
    Cql,
    Redis,
    Mongo,
}

public enum SyntaxKind : byte
{
    Identifier,
    Keyword,
    StringLiteral,
    QuotedIdentifier,
    Number,
    Comment,
    Operator,
    Punctuation,
}

public readonly record struct SyntaxToken(int Start, int Length, SyntaxKind Kind);

public static class SqlSyntax
{
    private const int StackTokens = 256;

    // UTF-16 offsets. A span as long as text holds every token, a shorter one the first. Redis and MongoDB have none.
    public static unsafe int Tokenize(
        SqlGrammar grammar,
        ReadOnlySpan<char> text,
        Span<SyntaxToken> tokens,
        bool? backslashEscapes = null)
    {
        if (!Enum.IsDefined(grammar))
        {
            throw new ArgumentOutOfRangeException(nameof(grammar), grammar, "Not a grammar the core knows.");
        }

        var capacity = Math.Min(text.Length, tokens.Length);
        if (capacity == 0)
        {
            return 0;
        }

        uint escapes = backslashEscapes switch
        {
            false => 0,
            true => 1,
            null => 2,
        };
        TpSyntaxToken[]? rented = null;
        var native = capacity <= StackTokens
            ? stackalloc TpSyntaxToken[capacity]
            : (rented = ArrayPool<TpSyntaxToken>.Shared.Rent(capacity)).AsSpan(0, capacity);
        try
        {
            uint written;
            fixed (char* units = text)
            fixed (TpSyntaxToken* output = native)
            {
                written = WindowMethods.tablepro_syntax_tokens(
                    (uint)grammar,
                    escapes,
                    (ushort*)units,
                    (uint)text.Length,
                    output,
                    (uint)capacity);
            }

            var count = (int)Math.Min(written, (uint)capacity);
            for (var i = 0; i < count; i++)
            {
                var token = native[i];
                tokens[i] = new SyntaxToken((int)token.start, (int)token.length, (SyntaxKind)token.kind);
            }

            return count;
        }
        finally
        {
            if (rented is not null)
            {
                ArrayPool<TpSyntaxToken>.Shared.Return(rented);
            }
        }
    }
}
