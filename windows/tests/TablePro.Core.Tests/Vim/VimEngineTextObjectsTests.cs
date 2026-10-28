using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>Text objects (words, WORDs, quotes, brackets, tags, paragraphs) with operators and in visual mode.</summary>
public sealed class VimEngineTextObjectsTests
{
    private const string Sample = "hello world foo bar\n";

    private static string SelectedText(VimHarness h) => h.Text.Substring(h.Buffer.SelectionStart, h.Buffer.SelectionLength);

    [Fact]
    public void CIWChangesInnerWordAtCursor()
    {
        var h = new VimHarness(Sample, 6);
        h.Keys("ciw");
        Assert.Equal("hello  foo bar\n", h.Text);
        Assert.Equal(VimMode.Insert, h.Mode);
    }

    [Fact]
    public void CAWChangesAroundWord()
    {
        var h = new VimHarness(Sample, 6);
        h.Keys("caw");
        Assert.Equal("hello foo bar\n", h.Text);
    }

    [Fact]
    public void DIWDeletesInnerWord()
    {
        var h = new VimHarness(Sample, 0);
        h.Keys("diw");
        Assert.Equal(" world foo bar\n", h.Text);
    }

    [Fact]
    public void DAWDeletesAroundWord()
    {
        var h = new VimHarness(Sample, 0);
        h.Keys("daw");
        Assert.Equal("world foo bar\n", h.Text);
    }

    [Fact]
    public void YIWYanksInnerWord()
    {
        var h = new VimHarness(Sample, 6);
        h.Keys("yiw");
        h.Keys("P");
        Assert.Contains("worldworld", h.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void IWOnPunctuationSelectsPunctRun()
    {
        var h = new VimHarness("hello,,world\n", 5);
        h.Keys("diw");
        Assert.Equal("helloworld\n", h.Text);
    }

    [Fact]
    public void IWOnWhitespaceSelectsWhitespace()
    {
        var h = new VimHarness("hello   world\n", 6);
        h.Keys("diw");
        Assert.Equal("helloworld\n", h.Text);
    }

    [Fact]
    public void DIWUppercaseDeletesBigWord()
    {
        var h = new VimHarness("hello,world foo\n", 6);
        h.Keys("d");
        h.Key('i');
        h.Key('W', shift: true);
        Assert.Equal(" foo\n", h.Text);
    }

    [Fact]
    public void DIQuoteDeletesInsideQuotes()
    {
        var h = new VimHarness("foo \"bar baz\" qux\n", 7);
        h.Keys("di\"");
        Assert.Equal("foo \"\" qux\n", h.Text);
    }

    [Fact]
    public void DAQuoteDeletesIncludingQuotes()
    {
        var h = new VimHarness("foo \"bar baz\" qux\n", 7);
        h.Keys("da\"");

        // a" takes one trailing space along with the quotes.
        Assert.Equal("foo qux\n", h.Text);
    }

    [Fact]
    public void DIApostropheDeletesInsideQuotes()
    {
        var h = new VimHarness("foo 'bar' qux\n", 6);
        h.Keys("di'");
        Assert.Equal("foo '' qux\n", h.Text);
    }

    [Fact]
    public void DIParenDeletesInsideParentheses()
    {
        var h = new VimHarness("func(arg1, arg2) {}\n", 8);
        h.Keys("di(");
        Assert.Equal("func() {}\n", h.Text);
    }

    [Fact]
    public void DAParenDeletesIncludingParentheses()
    {
        var h = new VimHarness("func(arg1, arg2) {}\n", 8);
        h.Keys("da(");
        Assert.Equal("func {}\n", h.Text);
    }

    [Fact]
    public void DIBIsSynonymOfDIParen()
    {
        var h = new VimHarness("func(arg1) bar\n", 7);
        h.Keys("dib");
        Assert.Equal("func() bar\n", h.Text);
    }

    [Fact]
    public void DIBraceDeletesInsideBraces()
    {
        var h = new VimHarness("if (x) { return 1; }\n", 12);
        h.Keys("di{");
        Assert.Equal("if (x) {}\n", h.Text);
    }

    [Fact]
    public void DIBigBIsSynonymOfDIBrace()
    {
        var h = new VimHarness("if (x) { y; }\n", 10);
        h.Keys("d");
        h.Key('i');
        h.Key('B', shift: true);
        Assert.Equal("if (x) {}\n", h.Text);
    }

    [Fact]
    public void DIBracketDeletesInsideBrackets()
    {
        var h = new VimHarness("arr[1, 2, 3]\n", 5);
        h.Keys("di[");
        Assert.Equal("arr[]\n", h.Text);
    }

    [Fact]
    public void DIAngleBracketDeletesInsideAngles()
    {
        var h = new VimHarness("Vec<int> v;\n", 5);
        h.Keys("di<");
        Assert.Equal("Vec<> v;\n", h.Text);
    }

    [Fact]
    public void DITDeletesInsideTag()
    {
        var h = new VimHarness("<div>hello</div>\n", 7);
        h.Keys("dit");
        Assert.Equal("<div></div>\n", h.Text);
    }

    [Fact]
    public void DATDeletesIncludingTags()
    {
        var h = new VimHarness("<div>hello</div>\n", 7);
        h.Keys("dat");
        Assert.Equal("\n", h.Text);
    }

    [Fact]
    public void DIPDeletesInnerParagraph()
    {
        var h = new VimHarness("para one\nstill one\n\npara two\n", 3);
        h.Keys("dip");
        Assert.Equal("\n\npara two\n", h.Text);
    }

    [Fact]
    public void DAPDeletesAroundParagraph()
    {
        var h = new VimHarness("para one\nstill one\n\npara two\n", 3);
        h.Keys("dap");
        Assert.Equal("para two\n", h.Text);
    }

    [Fact]
    public void VisualIWSelectsInnerWord()
    {
        var h = new VimHarness(Sample, 6);
        h.Keys("viw");
        Assert.Equal("world", SelectedText(h));
    }

    [Fact]
    public void VisualIQSelectsInsideQuotes()
    {
        var h = new VimHarness("x = \"hello\"\n", 6);
        h.Keys("vi\"");
        Assert.Equal("hello", SelectedText(h));
    }

    [Fact]
    public void DIParenSelectsInnermostPair()
    {
        var h = new VimHarness("f(g(x))\n", 4);
        h.Keys("di(");
        Assert.Equal("f(g())\n", h.Text);
    }

    [Fact]
    public void DIParenWithCursorOnOpenParen()
    {
        var h = new VimHarness("f(arg)\n", 1);
        h.Keys("di(");
        Assert.Equal("f()\n", h.Text);
    }

    [Fact]
    public void DIParenWithCursorOnCloseParen()
    {
        var h = new VimHarness("f(arg)\n", 5);
        h.Keys("di(");
        Assert.Equal("f()\n", h.Text);
    }
}
