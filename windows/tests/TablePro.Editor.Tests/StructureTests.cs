using TablePro.Editor.Model;
using TablePro.Testing;
using Windows.System;

namespace TablePro.Editor.Tests;

public sealed class StructureTests
{
    private const string Script = "select a,\n  b\nfrom t;\nselect (1 + 2);";

    [Fact]
    public Task AWrappedLineGivesARectanglePerRow() => WinUiApp.RunAsync(async () =>
    {
        var line = string.Concat(Enumerable.Repeat("select 1 + ", 40));
        var editor = new SqlEditor { Text = line, WordWrap = true };
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
            Assert.True(editor.RangeRects(0, line.Length).Count > 1, "a long wrapped line drew on one row");
            Assert.True(editor.Model.Rows.RowCount > 1);

            editor.WordWrap = false;
            Assert.Single(editor.RangeRects(0, line.Length));
            Assert.Equal(1, editor.Model.Rows.RowCount);
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });

    [Fact]
    public Task FoldAllHidesAStatementsLinesAndTheKeysFoldAndOpenIt() => WinUiApp.RunAsync(async () =>
    {
        var editor = new SqlEditor { Text = Script, Lexer = new TestLexer() };
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");

            Assert.True(editor.FoldAll());
            Assert.Equal([new FoldRegion(0, 2)], editor.Folds);
            Assert.Equal(2, editor.VisibleRanges().Count);

            editor.Model.SetCaret(3);
            Assert.True(editor.HandleKey((VirtualKey)221, control: true, shift: true, alt: false));
            Assert.Empty(editor.Folds);
            Assert.Single(editor.VisibleRanges());

            editor.Model.SetCaret(12);
            Assert.True(editor.HandleKey((VirtualKey)219, control: true, shift: true, alt: false));
            Assert.Equal([new FoldRegion(0, 2)], editor.Folds);
            Assert.Equal(editor.Document.GetLineEnd(0), editor.Model.Primary.Active);

            editor.GoTo(12);
            Assert.Empty(editor.Folds);

            Assert.True(editor.FoldAll());
            editor.ScrollIntoView(12, alignToTop: true);
            Assert.Empty(editor.Folds);
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });

    [Fact]
    public Task TheBandIsTheStatementAtTheCaretAndStepsAsideForASelection() => WinUiApp.RunAsync(async () =>
    {
        var editor = new SqlEditor { Text = Script, Lexer = new TestLexer(), HighlightsCurrentStatement = true };
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");

            editor.Model.SetCaret(Script.Length);
            Assert.Equal((Script.IndexOf("select (", StringComparison.Ordinal), Script.Length - 1), editor.StatementBand());
            editor.Model.SetCaret(2);
            Assert.Equal((0, Script.IndexOf(';', StringComparison.Ordinal)), editor.StatementBand());
            editor.Model.SetSelection(0, 3);
            Assert.Null(editor.StatementBand());
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });

    [Fact]
    public Task TheBracketsBesideTheCaretPair() => WinUiApp.RunAsync(async () =>
    {
        var editor = new SqlEditor { Text = Script, Lexer = new TestLexer() };
        try
        {
            Assert.True(await EditorHost.ShowAsync(editor), "the editor drew no frame");
            var open = Script.IndexOf('(', StringComparison.Ordinal);
            var close = Script.IndexOf(')', StringComparison.Ordinal);

            editor.Model.SetCaret(close + 1);
            Assert.Equal((open, close), editor.BracketPair());
            editor.Model.SetCaret(2);
            Assert.Null(editor.BracketPair());
        }
        finally
        {
            EditorHost.Clear();
            editor.Dispose();
        }
    });

    // Words as keywords, single-character punctuation and ';' ending a statement: enough structure for the control.
    internal sealed class TestLexer : ISyntaxLexer, ISqlStructure
    {
        private const byte Keyword = 1;
        private const byte Comment = 5;
        private const byte Operator = 6;
        private const byte Punctuation = 7;

        public SyntaxRoles Roles { get; } = new(Keyword, Comment, Punctuation, Operator);

        public int Tokenize(ReadOnlySpan<char> text, Span<SyntaxSpan> spans)
        {
            var count = 0;
            var i = 0;
            while (i < text.Length)
            {
                if (char.IsWhiteSpace(text[i]))
                {
                    i++;
                    continue;
                }
                var end = i + 1;
                var kind = Punctuation;
                if (char.IsLetterOrDigit(text[i]))
                {
                    while (end < text.Length && char.IsLetterOrDigit(text[end]))
                    {
                        end++;
                    }
                    kind = Keyword;
                }
                spans[count++] = new SyntaxSpan(i, end - i, kind);
                i = end;
            }
            return count;
        }

        public void SplitStatements(ReadOnlySpan<char> text, List<(int Start, int End)> statements)
        {
            var start = -1;
            var end = -1;
            for (var i = 0; i < text.Length; i++)
            {
                if (text[i] == ';')
                {
                    if (start >= 0)
                    {
                        statements.Add((start, end));
                    }
                    start = -1;
                }
                else if (!char.IsWhiteSpace(text[i]))
                {
                    start = start < 0 ? i : start;
                    end = i + 1;
                }
            }
            if (start >= 0)
            {
                statements.Add((start, end));
            }
        }
    }
}
