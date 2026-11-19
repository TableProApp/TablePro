using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineTextObjectsTests
{
    private const string Text = "hello world foo bar\n";

    private static string Selected(VimSession s) => s.Text.Substring(s.Selection.Location, s.Selection.Length);

    [Fact]
    public void CIWChangesInnerWordAtCursor()
    {
        var s = new VimSession(Text, caret: 6);
        s.Press("ciw");
        Assert.Equal("hello  foo bar\n", s.Text);
        Assert.Equal(VimMode.Insert, s.Mode);
    }

    [Fact]
    public void CAWChangesAroundWord()
    {
        var s = new VimSession(Text, caret: 6);
        s.Press("caw");
        Assert.Equal("hello foo bar\n", s.Text);
    }

    [Fact]
    public void DIWDeletesInnerWord()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("diw");
        Assert.Equal(" world foo bar\n", s.Text);
    }

    [Fact]
    public void DAWDeletesAroundWord()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("daw");
        Assert.Equal("world foo bar\n", s.Text);
    }

    [Fact]
    public void YIWYanksInnerWord()
    {
        var s = new VimSession(Text, caret: 6);
        s.Press("yiw");
        s.Press("P");
        Assert.Contains("worldworld", s.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void IWOnPunctuationSelectsPunctRun()
    {
        var s = new VimSession("hello,,world\n", caret: 5);
        s.Press("diw");
        Assert.Equal("helloworld\n", s.Text);
    }

    [Fact]
    public void IWOnWhitespaceSelectsWhitespace()
    {
        var s = new VimSession("hello   world\n", caret: 6);
        s.Press("diw");
        Assert.Equal("helloworld\n", s.Text);
    }

    [Fact]
    public void DIWUppercaseDeletesBigWord()
    {
        var s = new VimSession("hello,world foo\n", caret: 6);
        s.Press("d");
        s.Key("i");
        s.Key("W", shift: true);
        Assert.Equal(" foo\n", s.Text);
    }

    [Fact]
    public void DIQuoteDeletesInsideQuotes()
    {
        var s = new VimSession("foo \"bar baz\" qux\n", caret: 7);
        s.Press("di\"");
        Assert.Equal("foo \"\" qux\n", s.Text);
    }

    [Fact]
    public void DAQuoteDeletesIncludingQuotes()
    {
        var s = new VimSession("foo \"bar baz\" qux\n", caret: 7);
        s.Press("da\"");
        Assert.Equal("foo qux\n", s.Text);
    }

    [Fact]
    public void DIApostropheDeletesInsideQuotes()
    {
        var s = new VimSession("foo 'bar' qux\n", caret: 6);
        s.Press("di'");
        Assert.Equal("foo '' qux\n", s.Text);
    }

    [Fact]
    public void DIParenDeletesInsideParentheses()
    {
        var s = new VimSession("func(arg1, arg2) {}\n", caret: 8);
        s.Press("di(");
        Assert.Equal("func() {}\n", s.Text);
    }

    [Fact]
    public void DAParenDeletesIncludingParentheses()
    {
        var s = new VimSession("func(arg1, arg2) {}\n", caret: 8);
        s.Press("da(");
        Assert.Equal("func {}\n", s.Text);
    }

    [Fact]
    public void DIBIsSynonymOfDIParen()
    {
        var s = new VimSession("func(arg1) bar\n", caret: 7);
        s.Press("dib");
        Assert.Equal("func() bar\n", s.Text);
    }

    [Fact]
    public void DIBraceDeletesInsideBraces()
    {
        var s = new VimSession("if (x) { return 1; }\n", caret: 12);
        s.Press("di{");
        Assert.Equal("if (x) {}\n", s.Text);
    }

    [Fact]
    public void DIBigBIsSynonymOfDIBrace()
    {
        var s = new VimSession("if (x) { y; }\n", caret: 10);
        s.Press("d");
        s.Key("i");
        s.Key("B", shift: true);
        Assert.Equal("if (x) {}\n", s.Text);
    }

    [Fact]
    public void DIBracketDeletesInsideBrackets()
    {
        var s = new VimSession("arr[1, 2, 3]\n", caret: 5);
        s.Press("di[");
        Assert.Equal("arr[]\n", s.Text);
    }

    [Fact]
    public void DIAngleBracketDeletesInsideAngles()
    {
        var s = new VimSession("Vec<int> v;\n", caret: 5);
        s.Press("di<");
        Assert.Equal("Vec<> v;\n", s.Text);
    }

    [Fact]
    public void DITDeletesInsideTag()
    {
        var s = new VimSession("<div>hello</div>\n", caret: 7);
        s.Press("dit");
        Assert.Equal("<div></div>\n", s.Text);
    }

    [Fact]
    public void DATDeletesIncludingTags()
    {
        var s = new VimSession("<div>hello</div>\n", caret: 7);
        s.Press("dat");
        Assert.Equal("\n", s.Text);
    }

    [Fact]
    public void DIPDeletesInnerParagraph()
    {
        var s = new VimSession("para one\nstill one\n\npara two\n", caret: 3);
        s.Press("dip");
        Assert.Equal("\n\npara two\n", s.Text);
    }

    [Fact]
    public void DAPDeletesAroundParagraph()
    {
        var s = new VimSession("para one\nstill one\n\npara two\n", caret: 3);
        s.Press("dap");
        Assert.Equal("para two\n", s.Text);
    }

    [Fact]
    public void VisualIWSelectsInnerWord()
    {
        var s = new VimSession(Text, caret: 6);
        s.Press("viw");
        Assert.Equal("world", Selected(s));
    }

    [Fact]
    public void VisualIQSelectsInsideQuotes()
    {
        var s = new VimSession("x = \"hello\"\n", caret: 6);
        s.Press("vi\"");
        Assert.Equal("hello", Selected(s));
    }

    [Fact]
    public void DIParenSelectsInnermostPair()
    {
        var s = new VimSession("f(g(x))\n", caret: 4);
        s.Press("di(");
        Assert.Equal("f(g())\n", s.Text);
    }

    [Fact]
    public void DIParenWithCursorOnOpenParen()
    {
        var s = new VimSession("f(arg)\n", caret: 1);
        s.Press("di(");
        Assert.Equal("f()\n", s.Text);
    }

    [Fact]
    public void DIParenWithCursorOnCloseParen()
    {
        var s = new VimSession("f(arg)\n", caret: 5);
        s.Press("di(");
        Assert.Equal("f()\n", s.Text);
    }
}
