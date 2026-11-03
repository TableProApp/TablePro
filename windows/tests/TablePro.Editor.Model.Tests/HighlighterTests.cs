using System.Text;

namespace TablePro.Editor.Model.Tests;

public sealed class HighlighterTests
{
    [Fact]
    public void ALineInsideABlockCommentColorsAsComment()
    {
        var document = new TextDocument("select 1;\n/* one\ntwo\nthree */ select 2;");
        var highlighter = new SyntaxHighlighter(document, new FakeLexer());
        var spans = new List<SyntaxSpan>();

        highlighter.GetTokens(2, 2, spans);

        var line = document.GetLineStart(2);
        Assert.Contains(spans, s => s.Kind == FakeLexer.Comment && s.Start < line && s.End > line);
        Assert.False(highlighter.IsLineClean(2));
        Assert.True(highlighter.IsLineClean(1));
    }

    [Fact]
    public void EditsGiveTheSameColorsAsAFreshRead()
    {
        var random = new Random(77);
        var document = new TextDocument(Script(400));
        var highlighter = new SyntaxHighlighter(document, new FakeLexer());
        var pieces = new[] { "/*", "*/", "'", "\n", "x", " ", "select" };
        var spans = new List<SyntaxSpan>();
        for (var step = 0; step < 300; step++)
        {
            var offset = random.Next(document.Length + 1);
            if (random.Next(4) == 0 && offset < document.Length)
            {
                document.Replace(offset, Math.Min(5, document.Length - offset), string.Empty);
            }
            else
            {
                document.Replace(offset, 0, pieces[random.Next(pieces.Length)]);
            }
            var first = random.Next(document.LineCount);
            var last = Math.Min(document.LineCount - 1, first + 30);
            highlighter.GetTokens(first, last, spans);

            var fresh = new SyntaxHighlighter(new TextDocument(document.GetText()), new FakeLexer());
            var expected = new List<SyntaxSpan>();
            fresh.GetTokens(first, last, expected);
            Assert.Equal(expected, spans);
        }
    }

    [Fact]
    public void TypingInTheMiddleRelexesOnlyAroundTheEdit()
    {
        var document = new TextDocument(Script(40_000));
        var model = new EditorModel(document);
        var highlighter = new SyntaxHighlighter(document, new FakeLexer());
        highlighter.EnsureStates(document.LineCount - 1);
        var middle = document.LineCount / 2;
        model.SetCaret(document.GetLineEnd(middle));
        var before = highlighter.LexedChars;

        model.Type("a");
        highlighter.EnsureStates(document.LineCount - 1);

        Assert.Equal(document.LineCount, highlighter.Frontier);
        Assert.True(highlighter.LexedChars - before < 200_000, $"lexed {highlighter.LexedChars - before}");
    }

    [Fact]
    public void OpeningACommentReachesTheLinesBelow()
    {
        var document = new TextDocument(string.Concat(Enumerable.Repeat("select a;\n", 200)));
        var highlighter = new SyntaxHighlighter(document, new FakeLexer());
        highlighter.EnsureStates(document.LineCount - 1);
        Assert.True(highlighter.IsLineClean(150));

        document.Replace(document.GetLineStart(10), 0, "/*");

        Assert.False(highlighter.IsLineClean(150));
    }

    [Fact]
    public void IdlePassesReachTheEndWithTheSameFacts()
    {
        var text = Script(30_000);
        var idle = new SyntaxHighlighter(new TextDocument(text), new FakeLexer());
        var direct = new SyntaxHighlighter(new TextDocument(text), new FakeLexer());
        direct.EnsureStates(29_999);

        var passes = 0;
        while (idle.AdvanceIdle(2))
        {
            passes++;
        }

        Assert.True(passes > 1);
        Assert.Equal(direct.Frontier, idle.Frontier);
        for (var line = 0; line < 30_000; line += 97)
        {
            Assert.Equal(direct.IsLineClean(line), idle.IsLineClean(line));
        }
    }

    [Fact]
    public void IdlePassesGetPastALineLongerThanAWindow()
    {
        var document = new TextDocument(new string('x', 200_000) + "\n" + Script(100));
        var highlighter = new SyntaxHighlighter(document, new FakeLexer());

        var passes = 0;
        while (highlighter.AdvanceIdle(4) && passes < 50)
        {
            passes++;
        }

        Assert.Equal(document.LineCount, highlighter.Frontier);
    }

    private static string Script(int lines)
    {
        var text = new StringBuilder();
        for (var i = 0; i < lines; i++)
        {
            text.Append(i % 7 == 0 ? "/* note " + i : "select a, 'x' from t" + i);
            text.Append(i % 7 == 0 ? " */" : ";");
            text.Append('\n');
        }
        return text.ToString();
    }
}
