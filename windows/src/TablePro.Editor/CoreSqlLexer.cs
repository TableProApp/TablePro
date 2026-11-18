using System.Buffers;
using TablePro.Editor.Model;
using TablePro.Interop;

namespace TablePro.Editor;

// Span kinds are TablePro.Interop.SyntaxKind values. Statements split as the drivers split a script.
public sealed class CoreSqlLexer(SqlGrammar grammar) : ISyntaxLexer, ISqlStructure
{
    private static readonly SyntaxRoles s_roles = new(
        (byte)SyntaxKind.Keyword, (byte)SyntaxKind.Comment, (byte)SyntaxKind.Punctuation, (byte)SyntaxKind.Operator);

    public SqlGrammar Grammar { get; } = grammar;

    public SyntaxRoles Roles => s_roles;

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

    public void SplitStatements(ReadOnlySpan<char> text, List<(int Start, int End)> statements)
    {
        ArgumentNullException.ThrowIfNull(statements);
        var found = new List<StatementRange>();
        SqlSyntax.Statements(Grammar, text, found);
        statements.EnsureCapacity(statements.Count + found.Count);
        foreach (var statement in found)
        {
            statements.Add((statement.Start, statement.End));
        }
    }
}
