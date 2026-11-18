using System.Buffers;
using TablePro.Interop.Native;

namespace TablePro.Interop;

// The core's codes for tablepro_syntax_tokens and tablepro_script_statements follow these declaration orders.
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

public readonly record struct StatementRange(int Start, int End);

public static class SqlSyntax
{
    private const int StackTokens = 256;
    private const int StackStatements = 256;

    // UTF-16 offsets. A span as long as text holds every token, a shorter one the first. Redis and MongoDB have none.
    public static unsafe int Tokenize(
        SqlGrammar grammar,
        ReadOnlySpan<char> text,
        Span<SyntaxToken> tokens,
        bool? backslashEscapes = null)
    {
        CheckGrammar(grammar);
        var capacity = Math.Min(text.Length, tokens.Length);
        if (capacity == 0)
        {
            return 0;
        }

        var escapes = Escapes(backslashEscapes);
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

    // UTF-16 offsets of each statement without its terminator, split as the drivers split a script.
    public static void Statements(
        SqlGrammar grammar,
        ReadOnlySpan<char> text,
        List<StatementRange> statements,
        bool? backslashEscapes = null)
    {
        CheckGrammar(grammar);
        ArgumentNullException.ThrowIfNull(statements);
        statements.Clear();
        if (text.IsEmpty)
        {
            return;
        }

        var escapes = Escapes(backslashEscapes);
        Span<TpStatementSpan> stack = stackalloc TpStatementSpan[StackStatements];
        var count = Split(grammar, escapes, text, stack);
        if (count <= StackStatements)
        {
            Add(statements, stack[..count]);
            return;
        }

        var rented = ArrayPool<TpStatementSpan>.Shared.Rent(count);
        try
        {
            var pooled = rented.AsSpan(0, count);
            Add(statements, pooled[..Math.Min(Split(grammar, escapes, text, pooled), count)]);
        }
        finally
        {
            ArrayPool<TpStatementSpan>.Shared.Return(rented);
        }
    }

    // The statements the text holds, which may be more than spans has room for.
    private static unsafe int Split(
        SqlGrammar grammar,
        uint escapes,
        ReadOnlySpan<char> text,
        Span<TpStatementSpan> spans)
    {
        fixed (char* units = text)
        fixed (TpStatementSpan* output = spans)
        {
            return (int)WindowMethods.tablepro_script_statements(
                (uint)grammar,
                escapes,
                (ushort*)units,
                (uint)text.Length,
                output,
                (uint)spans.Length);
        }
    }

    private static void Add(List<StatementRange> statements, ReadOnlySpan<TpStatementSpan> spans)
    {
        statements.EnsureCapacity(spans.Length);
        foreach (var span in spans)
        {
            statements.Add(new StatementRange((int)span.start, (int)span.end));
        }
    }

    private static void CheckGrammar(SqlGrammar grammar)
    {
        if (!Enum.IsDefined(grammar))
        {
            throw new ArgumentOutOfRangeException(nameof(grammar), grammar, "Not a grammar the core knows.");
        }
    }

    private static uint Escapes(bool? backslashEscapes)
    {
        return backslashEscapes switch
        {
            false => 0,
            true => 1,
            null => 2,
        };
    }
}
