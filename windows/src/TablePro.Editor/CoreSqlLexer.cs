using System.Buffers;
using TablePro.Editor.Model;
using TablePro.Interop;

namespace TablePro.Editor;

// Span kinds are TablePro.Interop.SyntaxKind values.
public sealed class CoreSqlLexer(SqlGrammar grammar) : ISyntaxLexer
{
    public SqlGrammar Grammar { get; } = grammar;

    public int Tokenize(ReadOnlySpan<char> text, Span<SyntaxSpan> spans)
    {
        if (text.IsEmpty)
        {
            return 0;
        }
        var tokens = ArrayPool<SyntaxToken>.Shared.Rent(text.Length);
        try
        {
            var count = Math.Min(SqlSyntax.Tokenize(Grammar, text, tokens.AsSpan(0, text.Length)), spans.Length);
            for (var i = 0; i < count; i++)
            {
                var token = tokens[i];
                spans[i] = new SyntaxSpan(token.Start, token.Length, (byte)token.Kind);
            }
            return count;
        }
        finally
        {
            ArrayPool<SyntaxToken>.Shared.Return(tokens);
        }
    }
}
