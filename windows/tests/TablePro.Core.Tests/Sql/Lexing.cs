using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

internal readonly record struct Lexeme(SqlTokenKind Kind, string Text, bool IsUnterminated = false);

internal static class Lexing
{
    public static List<Lexeme> All(string text, SqlLexerFeatures features)
    {
        var list = new List<Lexeme>();
        var lexer = new SqlLexer(text, features);
        while (lexer.TryRead(out var token))
        {
            list.Add(new Lexeme(token.Kind, text.Substring(token.Start, token.Length), token.IsUnterminated));
        }

        return list;
    }

    public static List<Lexeme> Significant(string text, SqlLexerFeatures features) =>
        All(text, features).Where(t => t.Kind != SqlTokenKind.Whitespace).ToList();

    public static List<Lexeme> Significant(string text, SqlDialect dialect) => Significant(text, dialect.LexerFeatures);
}
