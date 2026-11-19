using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineInsertEntryTests
{
    private const string Text = "hello world\nsecond line\nthird line\n";

    [Fact]
    public void ILowerEntersInsertMode()
    {
        var s = new VimSession(Text, caret: 3);
        s.Press("i");
        Assert.Equal(VimMode.Insert, s.Mode);
    }

    [Fact]
    public void ILowerDoesNotMoveCursor()
    {
        var s = new VimSession(Text, caret: 3);
        s.Press("i");
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void ILowerConsumesKey()
    {
        var s = new VimSession(Text);
        Assert.True(s.Key("i"));
    }

    [Fact]
    public void ICapitalEntersInsertModeAtFirstNonBlank()
    {
        var s = new VimSession("   hello\n", caret: 6);
        s.Key("I", shift: true);
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void ICapitalAtLineStartWithoutLeadingSpace()
    {
        var s = new VimSession(Text, caret: 5);
        s.Key("I", shift: true);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void AAppendsAfterCursor()
    {
        var s = new VimSession(Text, caret: 2);
        s.Press("a");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void AAtEndOfLineLandsAfterLastChar()
    {
        // d is at 10 and the line break at 11, so a lands between them.
        var s = new VimSession(Text, caret: 10);
        s.Press("a");
        Assert.Equal(11, s.Caret);
    }

    [Fact]
    public void AAtBufferEndStaysAtEnd()
    {
        var s = new VimSession(Text, caret: Text.Length);
        s.Press("a");
        Assert.Equal(s.Text.Length, s.Caret);
    }

    [Fact]
    public void ACapitalEntersInsertAtLineEnd()
    {
        var s = new VimSession(Text, caret: 3);
        s.Key("A", shift: true);
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal(11, s.Caret);
    }

    [Fact]
    public void ACapitalOnLineWithoutTrailingNewline()
    {
        var s = new VimSession("hello", caret: 0);
        s.Key("A", shift: true);
        Assert.Equal(5, s.Caret);
    }

    [Fact]
    public void OOpensLineBelowAndEntersInsert()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("o");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.StartsWith("hello world\n\n", s.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void OPositionsCursorOnNewLine()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("o");
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void OOnLastLineWithoutTrailingNewline()
    {
        var s = new VimSession("one\ntwo", caret: 5);
        s.Press("o");
        Assert.Equal("one\ntwo\n", s.Text);
        Assert.Equal(8, s.Caret);
    }

    [Fact]
    public void CapitalOOpensLineAbove()
    {
        var s = new VimSession(Text, caret: 14);
        s.Press("O");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void CapitalOOnFirstLine()
    {
        var s = new VimSession(Text, caret: 3);
        s.Press("O");
        Assert.Equal(0, s.Caret);
        Assert.StartsWith("\nhello world", s.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void SLowerDeletesCharAndEntersInsert()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("s");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("ello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void SLowerWithCount()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("3s");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("lo world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void SLowerDoesNotCrossNewline()
    {
        var s = new VimSession(Text, caret: 10);
        s.Press("9s");
        Assert.Equal("hello worl\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CapitalSDeletesLineContentAndEntersInsert()
    {
        var s = new VimSession(Text, caret: 5);
        s.Key("S", shift: true);
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("\nsecond line\nthird line\n", s.Text);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void CapitalSWithCount()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("2");
        s.Key("S", shift: true);
        Assert.Equal("\nthird line\n", s.Text);
    }

    [Fact]
    public void EscapeReturnsToNormalMode()
    {
        var s = new VimSession(Text);
        s.Press("i");
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void EscapeMovesCursorBackOne()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("i");
        s.Escape();
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void EscapeAtLineStartDoesNotCrossBoundary()
    {
        var s = new VimSession(Text, caret: 12);
        s.Press("i");
        s.Escape();
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void EscapeAtBufferStartStays()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("i");
        s.Escape();
        Assert.Equal(0, s.Caret);
    }

    // Typing "SELECT * FROM users;" leaves the caret past the last character; Escape must still step back onto it.
    [Fact]
    public void EscapePastLastCharOfBufferWithoutTrailingNewline()
    {
        var s = new VimSession("SELECT * FROM users;", caret: 20);
        s.Press("i");
        Assert.Equal(VimMode.Insert, s.Mode);
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Equal(19, s.Caret);
    }

    // The caret before the final line break is the end of the last content line, not the empty line after it.
    [Fact]
    public void EscapePastLastCharOfBufferWithTrailingNewline()
    {
        var s = new VimSession("SELECT * FROM users;\n", caret: 20);
        s.Press("i");
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Equal(19, s.Caret);
    }

    // The empty line after a final line break is its own line, so Escape does not step back over the break.
    [Fact]
    public void EscapeOnPhantomLineAfterTrailingNewline()
    {
        var s = new VimSession("SELECT;\n", caret: 8);
        s.Press("i");
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Equal(8, s.Caret);
    }

    // The key router passes a key through to the editor only when the engine does not consume it.
    [Fact]
    public void EscapeAfterTypingSemicolonAtEndIsConsumed()
    {
        var s = new VimSession("SELECT * FROM users;", caret: 20);
        s.Press("i");
        Assert.True(s.Key(VimEngine.Escape));
    }

    [Fact]
    public void CharactersInInsertModeAreNotConsumed()
    {
        var s = new VimSession(Text);
        s.Press("i");
        Assert.False(s.Key("x"));
    }

    [Fact]
    public void EscapeInInsertIsConsumed()
    {
        var s = new VimSession(Text);
        s.Press("i");
        Assert.True(s.Key(VimEngine.Escape));
    }

    [Fact]
    public void GIResumesInsertAtLastInsertLocation()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("i");
        s.Escape();
        s.SetCaret(0);
        s.Press("gi");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal(5, s.Caret);
    }

    [Fact]
    public void ModeChangeCallbackFiresOnInsertEntry()
    {
        var s = new VimSession(Text);
        VimMode? captured = null;
        s.Engine.StatusChanged += (_, _) => captured = s.Mode;
        s.Press("i");
        Assert.Equal(VimMode.Insert, captured);
    }

    [Fact]
    public void ModeChangeCallbackFiresOnInsertExit()
    {
        var s = new VimSession(Text);
        s.Press("i");
        VimMode? captured = null;
        s.Engine.StatusChanged += (_, _) => captured = s.Mode;
        s.Escape();
        Assert.Equal(VimMode.Normal, captured);
    }

    [Fact]
    public void GiAfterAnEditOnTheLineResumesAtTheLineEnd()
    {
        var s = new VimSession("abc\ntail\n", caret: 0);
        s.Press("A");
        s.Type("X");
        s.Escape();
        s.Press("0rYgi");
        s.Type("Z");
        s.Escape();
        Assert.Equal("YbcXZ\ntail\n", s.Text);
    }
}
