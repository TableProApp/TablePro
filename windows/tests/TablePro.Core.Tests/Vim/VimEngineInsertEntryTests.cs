using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>Entering and leaving insert mode: i, I, a, A, o, O, s, S, gi and Escape.</summary>
public sealed class VimEngineInsertEntryTests
{
    private const string Text = "hello world\nsecond line\nthird line\n";

    private static VimHarness Make(int caret = 0) => new(Text, caret);

    [Fact]
    public void ILowerEntersInsertMode()
    {
        var h = Make(3);
        h.Keys("i");
        Assert.Equal(VimMode.Insert, h.Mode);
    }

    [Fact]
    public void ILowerDoesNotMoveCursor()
    {
        var h = Make(3);
        h.Keys("i");
        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void ILowerConsumesKey() => Assert.True(Make().Key('i'));

    [Fact]
    public void ICapitalEntersInsertModeAtFirstNonBlank()
    {
        var h = new VimHarness("   hello\n", 6);
        h.Key('I', shift: true);
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void ICapitalAtLineStartWithoutLeadingSpace()
    {
        var h = Make(5);
        h.Key('I', shift: true);
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void AAppendsAfterCursor()
    {
        var h = Make(2);
        h.Keys("a");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void AAtEndOfLineLandsAfterLastChar()
    {
        // 'd' is at 10 and '\n' at 11, so appending lands between them.
        var h = Make(10);
        h.Keys("a");
        Assert.Equal(11, h.Pos);
    }

    [Fact]
    public void AAtBufferEndStaysAtEnd()
    {
        var h = Make(Text.Length);
        h.Keys("a");
        Assert.Equal(Text.Length, h.Pos);
    }

    [Fact]
    public void ACapitalEntersInsertAtLineEnd()
    {
        var h = Make(3);
        h.Key('A', shift: true);
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal(11, h.Pos);
    }

    [Fact]
    public void ACapitalOnLineWithoutTrailingNewline()
    {
        var h = new VimHarness("hello");
        h.Key('A', shift: true);
        Assert.Equal(5, h.Pos);
    }

    [Fact]
    public void OOpensLineBelowAndEntersInsert()
    {
        var h = Make(5);
        h.Keys("o");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.StartsWith("hello world\n\n", h.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void OPositionsCursorOnNewLine()
    {
        var h = Make(5);
        h.Keys("o");
        Assert.Equal(12, h.Pos);
    }

    [Fact]
    public void OOnLastLineWithoutTrailingNewline()
    {
        var h = new VimHarness("one\ntwo", 5);
        h.Keys("o");
        Assert.Equal("one\ntwo\n", h.Text);
        Assert.Equal(8, h.Pos);
    }

    [Fact]
    public void CapitalOOpensLineAbove()
    {
        var h = Make(14);
        h.Keys("O");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal(12, h.Pos);
    }

    [Fact]
    public void CapitalOOnFirstLine()
    {
        var h = Make(3);
        h.Keys("O");
        Assert.Equal(0, h.Pos);
        Assert.StartsWith("\nhello world", h.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void SLowerDeletesCharAndEntersInsert()
    {
        var h = Make();
        h.Keys("s");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal("ello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void SLowerWithCount()
    {
        var h = Make();
        h.Keys("3s");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal("lo world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void SLowerDoesNotCrossNewline()
    {
        var h = Make(10);
        h.Keys("9s");
        Assert.Equal("hello worl\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CapitalSDeletesLineContentAndEntersInsert()
    {
        var h = Make(5);
        h.Key('S', shift: true);
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal("\nsecond line\nthird line\n", h.Text);
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void CapitalSWithCount()
    {
        var h = Make();
        h.Keys("2");
        h.Key('S', shift: true);
        Assert.Equal("\nthird line\n", h.Text);
    }

    [Fact]
    public void EscapeReturnsToNormalMode()
    {
        var h = Make();
        h.Keys("i");
        h.Key('\u001B');
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void EscapeMovesCursorBackOne()
    {
        var h = Make(5);
        h.Keys("i");
        h.Key('\u001B');
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void EscapeAtLineStartDoesNotCrossBoundary()
    {
        var h = Make(12);
        h.Keys("i");
        h.Key('\u001B');
        Assert.Equal(12, h.Pos);
    }

    [Fact]
    public void EscapeAtBufferStartStays()
    {
        var h = Make();
        h.Keys("i");
        h.Key('\u001B');
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void EscapePastLastCharOfBufferWithoutTrailingNewline()
    {
        // Typing "SELECT * FROM users;" leaves the caret past the last character; Escape steps back onto ';'.
        var h = new VimHarness("SELECT * FROM users;", 20);
        h.Keys("i");
        Assert.Equal(VimMode.Insert, h.Mode);
        h.Key('\u001B');
        Assert.Equal(VimMode.Normal, h.Mode);
        Assert.Equal(19, h.Pos);
    }

    [Fact]
    public void EscapePastLastCharOfBufferWithTrailingNewline()
    {
        // Offset 20 is the end of the last content line, before its '\n', not the empty line after it.
        var h = new VimHarness("SELECT * FROM users;\n", 20);
        h.Keys("i");
        h.Key('\u001B');
        Assert.Equal(VimMode.Normal, h.Mode);
        Assert.Equal(19, h.Pos);
    }

    [Fact]
    public void EscapeOnPhantomLineAfterTrailingNewline()
    {
        // The empty line after a trailing '\n' is a line of its own, so Escape does not step back over the newline.
        var h = new VimHarness("SELECT;\n", 8);
        h.Keys("i");
        h.Key('\u001B');
        Assert.Equal(VimMode.Normal, h.Mode);
        Assert.Equal(8, h.Pos);
    }

    [Fact]
    public void EscapeAfterTypingSemicolonAtEndIsConsumed()
    {
        // The editor passes keys through only when the engine declines them, so Escape must be consumed here.
        var h = new VimHarness("SELECT * FROM users;", 20);
        h.Keys("i");
        Assert.True(h.Key('\u001B'));
    }

    [Fact]
    public void CharactersInInsertModeAreNotConsumed()
    {
        var h = Make();
        h.Keys("i");
        Assert.False(h.Key('x'));
    }

    [Fact]
    public void EscapeInInsertIsConsumed()
    {
        var h = Make();
        h.Keys("i");
        Assert.True(h.Key('\u001B'));
    }

    [Fact]
    public void GiResumesInsertAtLastInsertLocation()
    {
        var h = Make(5);
        h.Keys("i");
        h.Key('\u001B');
        h.Select(0);
        h.Keys("gi");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal(5, h.Pos);
    }

    [Fact]
    public void ModeChangeCallbackFiresOnInsertEntry()
    {
        var h = Make();
        VimMode? captured = null;
        h.Engine.ModeChanged += (_, mode) => captured = mode;
        h.Keys("i");
        Assert.Equal(VimMode.Insert, captured);
    }

    [Fact]
    public void ModeChangeCallbackFiresOnInsertExit()
    {
        var h = Make();
        h.Keys("i");
        VimMode? captured = null;
        h.Engine.ModeChanged += (_, mode) => captured = mode;
        h.Key('\u001B');
        Assert.Equal(VimMode.Normal, captured);
    }
}
