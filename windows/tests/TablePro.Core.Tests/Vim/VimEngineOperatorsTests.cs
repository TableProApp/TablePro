using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>The delete, change and yank operators: doublings, shortcuts and operator plus motion.</summary>
public sealed class VimEngineOperatorsTests
{
    private const string Sample = "hello world\nsecond line\nthird line\n";
    private const char Escape = '\u001B';

    private static VimHarness At(int caret) => new(Sample, caret);

    [Fact]
    public void XDeletesCharUnderCursor()
    {
        var h = At(0);
        h.Keys("x");
        Assert.Equal("ello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void XWithCount()
    {
        var h = At(0);
        h.Keys("3x");
        Assert.Equal("lo world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void XDoesNotCrossNewline()
    {
        var h = At(10);
        h.Keys("5x");
        Assert.Equal("hello worl\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void XOnEmptyLineIsNoOp()
    {
        var h = new VimHarness("a\n\nb\n", 2);
        h.Keys("x");
        Assert.Equal("a\n\nb\n", h.Text);
    }

    [Fact]
    public void XOnLastCharOfLineMovesCursorBack()
    {
        var h = At(10);
        h.Keys("x");
        Assert.Equal(9, h.Pos);
    }

    [Fact]
    public void CapitalXDeletesCharBeforeCursor()
    {
        var h = At(5);
        h.Key('X', shift: true);
        Assert.Equal("hell world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CapitalXWithCount()
    {
        var h = At(5);
        h.Keys("3");
        h.Key('X', shift: true);
        Assert.Equal("he world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CapitalXAtLineStartIsNoOp()
    {
        var h = At(12);
        h.Key('X', shift: true);
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void CapitalXAtBufferStartIsNoOp()
    {
        var h = At(0);
        h.Key('X', shift: true);
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void DDDeletesCurrentLine()
    {
        var h = At(5);
        h.Keys("dd");
        Assert.Equal("second line\nthird line\n", h.Text);
    }

    [Fact]
    public void DDWithCount()
    {
        var h = At(0);
        h.Keys("2dd");
        Assert.Equal("third line\n", h.Text);
    }

    [Fact]
    public void DDOnLastLineLeavesPreviousLineCursorOnIt()
    {
        var h = At(28);
        h.Keys("dd");
        Assert.Equal("hello world\nsecond line\n", h.Text);
    }

    [Fact]
    public void DDOnSoleLineEmptiesBuffer()
    {
        var h = new VimHarness("only\n", 0);
        h.Keys("dd");
        Assert.Equal(string.Empty, h.Text);
    }

    [Fact]
    public void DDCountClampsAtBufferEnd()
    {
        var h = At(12);
        h.Keys("99dd");
        Assert.Equal("hello world\n", h.Text);
    }

    [Fact]
    public void DWDeletesToNextWord()
    {
        var h = At(0);
        h.Keys("dw");
        Assert.Equal("world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void DEDeletesToWordEndInclusive()
    {
        var h = At(0);
        h.Keys("de");
        Assert.Equal(" world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void DBDeletesBackwardWord()
    {
        var h = At(6);
        h.Keys("db");
        Assert.Equal("world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void DDollarDeletesToLineEnd()
    {
        var h = At(5);
        h.Keys("d$");
        Assert.Equal("hello\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void DZeroDeletesToLineStart()
    {
        var h = At(5);
        h.Keys("d0");
        Assert.Equal(" world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void DCaretDeletesToFirstNonBlank()
    {
        var h = new VimHarness("   hello\n", 6);
        h.Keys("d^");
        Assert.Equal("   lo\n", h.Text);
    }

    [Fact]
    public void DGoesGoesAllToEndOfBuffer()
    {
        var h = At(0);
        h.Keys("d");
        h.Key('G', shift: true);
        Assert.Equal(string.Empty, h.Text);
    }

    [Fact]
    public void DGGFromMidBufferDeletesToTop()
    {
        var h = At(14);
        h.Keys("dgg");
        Assert.Equal("third line\n", h.Text);
    }

    [Fact]
    public void DJDeletesTwoLines()
    {
        var h = At(0);
        h.Keys("dj");
        Assert.Equal("third line\n", h.Text);
    }

    [Fact]
    public void DKDeletesTwoLines()
    {
        var h = At(12);
        h.Keys("dk");
        Assert.Equal("third line\n", h.Text);
    }

    [Fact]
    public void DCountWordsDeletesMultipleWords()
    {
        var h = At(0);
        h.Keys("d3w");
        Assert.Equal("line\nthird line\n", h.Text);
    }

    [Fact]
    public void CapitalDDeletesToEndOfLine()
    {
        var h = At(5);
        h.Key('D', shift: true);
        Assert.Equal("hello\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CapitalDOnEmptyLineIsNoOp()
    {
        var h = new VimHarness("\nfoo\n", 0);
        h.Key('D', shift: true);
        Assert.Equal("\nfoo\n", h.Text);
    }

    [Fact]
    public void YYDoesNotModifyBuffer()
    {
        var h = At(0);
        h.Keys("yy");
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void YYThenPasteRestoresLine()
    {
        var h = At(0);
        h.Keys("yyp");
        Assert.Equal("hello world\nhello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void YYWithCount()
    {
        var h = At(0);
        h.Keys("2yyp");
        Assert.Equal("hello world\nhello world\nsecond line\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void YYCursorStaysAtLineStart()
    {
        var h = At(5);
        h.Keys("yy");
        Assert.Equal(0, h.Buffer.LineAndColumn(h.Pos).Line);
    }

    [Fact]
    public void YWYanksWordIntoRegister()
    {
        var h = At(0);
        h.Keys("yw");
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void YWThenPasteInsertsWord()
    {
        var h = At(0);
        h.Keys("ywp");
        Assert.Equal("hhello ello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void YDollarYanksToLineEnd()
    {
        var h = At(5);
        h.Keys("y$p");
        Assert.Equal("hello  worldworld\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CapitalYYanksLine()
    {
        var h = At(0);
        h.Key('Y', shift: true);
        h.Keys("p");
        Assert.Equal("hello world\nhello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CCDeletesLineContentEntersInsert()
    {
        var h = At(5);
        h.Keys("cc");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal("\nsecond line\nthird line\n", h.Text);
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void CCWithCount()
    {
        var h = At(0);
        h.Keys("2cc");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal("\nthird line\n", h.Text);
    }

    [Fact]
    public void CWChangesWord()
    {
        var h = At(0);
        h.Keys("cw");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal("world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CDollarChangesToLineEnd()
    {
        var h = At(5);
        h.Keys("c$");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal("hello\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CEChangesToWordEndInclusive()
    {
        var h = At(0);
        h.Keys("ce");
        Assert.Equal(" world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void CapitalCChangesToEndOfLine()
    {
        var h = At(5);
        h.Key('C', shift: true);
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal("hello\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void PendingDCancelledByEscape()
    {
        var h = At(0);
        h.Keys("d");
        h.Key(Escape);
        h.Keys("l");
        Assert.Equal(1, h.Pos);
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void PendingCCancelledByEscape()
    {
        var h = At(0);
        h.Keys("c");
        h.Key(Escape);
        h.Keys("l");
        Assert.Equal(1, h.Pos);
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void PendingYCancelledByEscape()
    {
        var h = At(0);
        h.Keys("y");
        h.Key(Escape);
        h.Keys("p");

        // The cancelled yank left the register empty, so p pastes nothing.
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void PendingOperatorCancelledByUnknownKey()
    {
        var h = At(0);
        h.Keys("dz");
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void CountTimesCountMultipliesMotion()
    {
        var h = new VimHarness("a b c d e f g\n", 0);
        h.Keys("2d3w");
        Assert.Equal("g\n", h.Text);
    }

    [Fact]
    public void DeleteAndPasteRoundTrip()
    {
        var h = At(0);
        h.Keys("dw");
        Assert.Equal("world\nsecond line\nthird line\n", h.Text);
        h.Key('P', shift: true);
        Assert.Equal(Sample, h.Text);
    }
}
