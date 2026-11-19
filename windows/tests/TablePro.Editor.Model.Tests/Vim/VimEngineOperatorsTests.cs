using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineOperatorsTests
{
    private const string Initial = "hello world\nsecond line\nthird line\n";

    [Fact]
    public void XDeletesCharUnderCursor()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("x");
        Assert.Equal("ello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void XWithCount()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("3x");
        Assert.Equal("lo world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void XDoesNotCrossNewline()
    {
        var s = new VimSession(Initial, caret: 10);
        s.Press("5x");
        Assert.Equal("hello worl\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void XOnEmptyLineIsNoOp()
    {
        var s = new VimSession("a\n\nb\n", caret: 2);
        s.Press("x");
        Assert.Equal("a\n\nb\n", s.Text);
    }

    [Fact]
    public void XOnLastCharOfLineMovesCursorBack()
    {
        var s = new VimSession(Initial, caret: 10);
        s.Press("x");
        Assert.Equal(9, s.Caret);
    }

    [Fact]
    public void CapitalXDeletesCharBeforeCursor()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Key("X", shift: true);
        Assert.Equal("hell world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CapitalXWithCount()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("3");
        s.Key("X", shift: true);
        Assert.Equal("he world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CapitalXAtLineStartIsNoOp()
    {
        var s = new VimSession(Initial, caret: 12);
        s.Key("X", shift: true);
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void CapitalXAtBufferStartIsNoOp()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Key("X", shift: true);
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void DDDeletesCurrentLine()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("dd");
        Assert.Equal("second line\nthird line\n", s.Text);
    }

    [Fact]
    public void DDWithCount()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("2dd");
        Assert.Equal("third line\n", s.Text);
    }

    [Fact]
    public void DDOnLastLineLeavesPreviousLineCursorOnIt()
    {
        var s = new VimSession(Initial, caret: 28);
        s.Press("dd");
        Assert.Equal("hello world\nsecond line\n", s.Text);
    }

    [Fact]
    public void DDOnSoleLineEmptiesBuffer()
    {
        var s = new VimSession("only\n", caret: 0);
        s.Press("dd");
        Assert.Equal("", s.Text);
    }

    [Fact]
    public void DDCountClampsAtBufferEnd()
    {
        var s = new VimSession(Initial, caret: 12);
        s.Press("99dd");
        Assert.Equal("hello world\n", s.Text);
    }

    [Fact]
    public void DWDeletesToNextWord()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("dw");
        Assert.Equal("world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void DEDeletesToWordEndInclusive()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("de");
        Assert.Equal(" world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void DBDeletesBackwardWord()
    {
        var s = new VimSession(Initial, caret: 6);
        s.Press("db");
        Assert.Equal("world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void DDollarDeletesToLineEnd()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("d$");
        Assert.Equal("hello\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void DZeroDeletesToLineStart()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("d0");
        Assert.Equal(" world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void DCaretDeletesToFirstNonBlank()
    {
        var s = new VimSession("   hello\n", caret: 6);
        s.Press("d^");
        Assert.Equal("   lo\n", s.Text);
    }

    [Fact]
    public void DGoesGoesAllToEndOfBuffer()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("d");
        s.Key("G", shift: true);
        Assert.Equal("", s.Text);
    }

    [Fact]
    public void DGGFromMidBufferDeletesToTop()
    {
        var s = new VimSession(Initial, caret: 14);
        s.Press("dgg");
        Assert.Equal("third line\n", s.Text);
    }

    [Fact]
    public void DJDeletesTwoLines()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("dj");
        Assert.Equal("third line\n", s.Text);
    }

    [Fact]
    public void DKDeletesTwoLines()
    {
        var s = new VimSession(Initial, caret: 12);
        s.Press("dk");
        Assert.Equal("third line\n", s.Text);
    }

    [Fact]
    public void DCountWordsDeletesMultipleWords()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("d3w");
        Assert.Equal("line\nthird line\n", s.Text);
    }

    [Fact]
    public void CapitalDDeletesToEndOfLine()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Key("D", shift: true);
        Assert.Equal("hello\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CapitalDOnEmptyLineIsNoOp()
    {
        var s = new VimSession("\nfoo\n", caret: 0);
        s.Key("D", shift: true);
        Assert.Equal("\nfoo\n", s.Text);
    }

    [Fact]
    public void YYDoesNotModifyBuffer()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yy");
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void YYThenPasteRestoresLine()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yyp");
        Assert.Equal("hello world\nhello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void YYWithCount()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("2yyp");
        Assert.Equal("hello world\nhello world\nsecond line\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void YYCursorStaysAtLineStart()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("yy");
        Assert.Equal(0, s.Engine.Buffer.LineAndColumn(s.Caret).Line);
    }

    [Fact]
    public void YWYanksWordIntoRegister()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("yw");
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void YWThenPasteInsertsWord()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("ywp");
        Assert.Equal("hhello ello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void YDollarYanksToLineEnd()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("y$p");
        Assert.Equal("hello  worldworld\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CapitalYYanksLine()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Key("Y", shift: true);
        s.Press("p");
        Assert.Equal("hello world\nhello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CCDeletesLineContentEntersInsert()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("cc");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("\nsecond line\nthird line\n", s.Text);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void CCWithCount()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("2cc");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("\nthird line\n", s.Text);
    }

    [Fact]
    public void CWChangesWord()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("cw");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CDollarChangesToLineEnd()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("c$");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("hello\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CEChangesToWordEndInclusive()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("ce");
        Assert.Equal(" world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void CapitalCChangesToEndOfLine()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Key("C", shift: true);
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("hello\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void PendingDCancelledByEscape()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("d");
        s.Escape();
        s.Press("l");
        Assert.Equal(1, s.Caret);
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void PendingCCancelledByEscape()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("c");
        s.Escape();
        s.Press("l");
        Assert.Equal(1, s.Caret);
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void PendingYCancelledByEscape()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("y");
        s.Escape();
        s.Press("p");
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void PendingOperatorCancelledByUnknownKey()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("dz");
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void CountTimesCountMultipliesMotion()
    {
        var s = new VimSession("a b c d e f g\n", caret: 0);
        s.Press("2d3w");
        Assert.Equal("g\n", s.Text);
    }

    [Fact]
    public void DeleteAndPasteRoundTrip()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("dw");
        Assert.Equal("world\nsecond line\nthird line\n", s.Text);
        s.Key("P", shift: true);
        Assert.Equal(Initial, s.Text);
    }
}
