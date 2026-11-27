namespace TablePro.Editor.Model.Tests;

// Statements end at a ';' the fake lexer reads as punctuation, so one inside a string or a comment ends nothing.
internal sealed class FakeStructure : ISqlStructure
{
    public static readonly SyntaxRoles FakeRoles = new(FakeLexer.Word, FakeLexer.Comment, FakeLexer.Punctuation, FakeLexer.Punctuation);

    public SyntaxRoles Roles => FakeRoles;

    public void SplitStatements(ReadOnlySpan<char> text, List<(int Start, int End)> statements)
    {
        var spans = new SyntaxSpan[Math.Max(1, text.Length)];
        var count = new FakeLexer().Tokenize(text, spans);
        var start = -1;
        var end = -1;
        for (var i = 0; i < count; i++)
        {
            var span = spans[i];
            if (span.Kind == FakeLexer.Comment)
            {
                continue;
            }
            if (span.Kind == FakeLexer.Punctuation && text[span.Start] == ';')
            {
                if (start >= 0)
                {
                    statements.Add((start, end));
                }
                start = -1;
                continue;
            }
            if (start < 0)
            {
                start = span.Start;
            }
            end = span.End;
        }
        if (start >= 0)
        {
            statements.Add((start, end));
        }
    }
}
