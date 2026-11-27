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
    public void CWChangesToTheWordEnd()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("cw");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal(" world\nsecond line\nthird line\n", s.Text);
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

    [Fact]
    public void AKeyThatIsNotAMotionEndsTheOperator()
    {
        var s = new VimSession("one two\n", caret: 0);
        s.Press("dxw");
        Assert.Equal("one two\n", s.Text);
        Assert.Equal(4, s.Caret);
    }

    [Theory]
    [InlineData("dgi")]
    [InlineData("dgv")]
    [InlineData("dgJ")]
    [InlineData("dgu")]
    public void AGCommandThatIsNotAMotionEndsTheOperator(string keys)
    {
        var s = new VimSession("one\ntwo\n", caret: 0);
        s.Press(keys);
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.False(s.Engine.IsPending);
        s.Press("w");
        Assert.Equal("one\ntwo\n", s.Text);
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void DPercentDeletesThroughTheMatchingBracket()
    {
        var s = new VimSession("a (b c) d\n", caret: 2);
        s.Press("d%");
        Assert.Equal("a  d\n", s.Text);
        Assert.Equal("(b c)", s.Engine.Register.Text);
    }

    [Fact]
    public void CPercentChangesTheBracketedText()
    {
        var s = new VimSession("a (b c) d\n", caret: 2);
        s.Press("c%");
        Assert.Equal("a  d\n", s.Text);
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void DPercentWithNoBracketEndsTheCommand()
    {
        var s = new VimSession("a b c d\n", caret: 0);
        s.Press("d%w");
        Assert.Equal("a b c d\n", s.Text);
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void DCountPercentTakesTheLinesThatFarThrough()
    {
        var s = new VimSession("a\nb\nc\nd\n", caret: 0);
        s.Press("d50%");
        Assert.Equal("c\nd\n", s.Text);
        Assert.True(s.Engine.Register.IsLinewise);
    }

    [Fact]
    public void DnDeletesUpToTheNextMatch()
    {
        var s = new VimSession("foo bar foo baz\n", caret: 0);
        s.Press("/foo\r0dn");
        Assert.Equal("foo baz\n", s.Text);
        Assert.Equal("foo bar ", s.Engine.Register.Text);
    }

    [Fact]
    public void DStarDeletesUpToTheNextMatchOfTheWord()
    {
        var s = new VimSession("foo x foo y\n", caret: 0);
        s.Press("d*");
        Assert.Equal("foo y\n", s.Text);
    }

    [Fact]
    public void DRightParenDeletesUpToTheNextSentence()
    {
        var s = new VimSession("One. Two. Three.\n", caret: 0);
        s.Press("d)");
        Assert.Equal("Two. Three.\n", s.Text);
    }

    [Fact]
    public void DSectionDeletesUpToTheNextSection()
    {
        var s = new VimSession("x\n{\ny\n}\n", caret: 0);
        s.Press("d]]");
        Assert.Equal("{\ny\n}\n", s.Text);
    }

    [Fact]
    public void DQuoteMarkTakesTheLinesThroughTheMark()
    {
        var s = new VimSession("aaa\nbbb\nccc\n", caret: 8);
        s.Press("magg");
        s.Press("d'a");
        Assert.Equal(string.Empty, s.Text);
        Assert.Equal("aaa\nbbb\nccc\n", s.Engine.Register.Text);
    }

    [Fact]
    public void DBacktickMarkDeletesUpToTheMark()
    {
        var s = new VimSession("aaa\nbbb\nccc\n", caret: 5);
        s.Press("magg");
        s.Press("d`a");
        Assert.Equal("bb\nccc\n", s.Text);
    }

    [Fact]
    public void DQuoteOnAnUnsetMarkEndsTheCommand()
    {
        var s = new VimSession("aaa bbb\n", caret: 0);
        s.Press("d'aw");
        Assert.Equal("aaa bbb\n", s.Text);
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void DLTakesTheLinesToTheLastOnScreen()
    {
        var s = new VimSession("aaa\nbbb\nccc\n", caret: 0);
        s.Press("dL");
        Assert.Equal(string.Empty, s.Text);
    }

    [Fact]
    public void DjOnTheLastLineDeletesNothing()
    {
        var s = new VimSession("aaa\nbbb\n", caret: 4);
        s.Press("djx");
        Assert.Equal("aaa\nbb\n", s.Text);
    }

    [Fact]
    public void DMinusOnTheFirstLineDeletesNothing()
    {
        var s = new VimSession("a\nb\n", caret: 0);
        s.Press("d-x");
        Assert.Equal("\nb\n", s.Text);
    }

    [Fact]
    public void DPlusTakesTheLineAndTheNext()
    {
        var s = new VimSession("a\nb\nc\n", caret: 0);
        s.Press("d+");
        Assert.Equal("c\n", s.Text);
    }

    [Fact]
    public void DbAtALineStartKeepsTheLineBreak()
    {
        var s = new VimSession("foo bar\nbaz\n", caret: 8);
        s.Press("db");
        Assert.Equal("foo \nbaz\n", s.Text);
        Assert.Equal("bar", s.Engine.Register.Text);
    }

    [Fact]
    public void DBraceFromTheIndentTakesTheParagraphsLines()
    {
        var s = new VimSession("aaa\nbbb\n\nccc\n", caret: 0);
        s.Press("d}");
        Assert.Equal("\nccc\n", s.Text);
        Assert.Equal("aaa\nbbb\n", s.Engine.Register.Text);
        Assert.True(s.Engine.Register.IsLinewise);
    }

    [Fact]
    public void DBraceFromInsideALineStopsBeforeTheLineBreak()
    {
        var s = new VimSession("aaa\nbbb\n\nccc\n", caret: 1);
        s.Press("d}");
        Assert.Equal("a\n\nccc\n", s.Text);
        Assert.Equal("aa\nbbb", s.Engine.Register.Text);
        Assert.False(s.Engine.Register.IsLinewise);
    }

    [Fact]
    public void DBraceOnTheLastParagraphTakesItsLines()
    {
        var s = new VimSession("aaa\nbbb\n", caret: 0);
        s.Press("d}");
        Assert.Equal(string.Empty, s.Text);
        Assert.True(s.Engine.Register.IsLinewise);
    }

    [Fact]
    public void DSearchFromTheIndentTakesWholeLines()
    {
        var s = new VimSession("hello world\nsecond line\n", caret: 0);
        s.Press("d/sec\r");
        Assert.Equal("second line\n", s.Text);
        Assert.True(s.Engine.Register.IsLinewise);
    }

    [Fact]
    public void DwOnTheLastWordStopsAtTheLineEnd()
    {
        var s = new VimSession("foo bar\nbaz\n", caret: 4);
        s.Press("dw");
        Assert.Equal("foo \nbaz\n", s.Text);
    }

    [Fact]
    public void DBigWOnTheLastWordStopsAtTheLineEnd()
    {
        var s = new VimSession("foo b.r\n  baz\n", caret: 4);
        s.Press("dW");
        Assert.Equal("foo \n  baz\n", s.Text);
    }

    [Fact]
    public void DwOnAnEmptyLineDeletesTheLine()
    {
        var s = new VimSession("aaa\n\nbbb\n", caret: 4);
        s.Press("dw");
        Assert.Equal("aaa\nbbb\n", s.Text);
    }

    [Fact]
    public void DwOnAnEmptyLastLineDeletesNothing()
    {
        var s = new VimSession("aaa\n\n", caret: 4);
        s.Press("dwk");
        Assert.Equal("aaa\n\n", s.Text);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void CwWithACountChangesToTheLastWordsEnd()
    {
        var s = new VimSession("foo bar baz\n", caret: 0);
        s.Press("2cw");
        Assert.Equal(" baz\n", s.Text);
        Assert.Equal(VimMode.Insert, s.Mode);
    }

    [Fact]
    public void CwOnBlanksChangesThemUpToTheNextWord()
    {
        var s = new VimSession("foo   bar\n", caret: 4);
        s.Press("cw");
        Assert.Equal("foo bar\n", s.Text);
    }

    [Fact]
    public void CBigWChangesToTheBigWordsEnd()
    {
        var s = new VimSession("a.b c\n", caret: 0);
        s.Press("cW");
        Assert.Equal(" c\n", s.Text);
    }

    [Fact]
    public void CjLeavesOneEmptyLineToTypeOn()
    {
        var s = new VimSession("a\nb\nc\n", caret: 0);
        s.Press("cj");
        Assert.Equal("\nc\n", s.Text);
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal(0, s.Caret);
        Assert.Equal("a\nb\n", s.Engine.Register.Text);
    }

    [Fact]
    public void CBraceFromTheIndentLeavesOneEmptyLine()
    {
        var s = new VimSession("aaa\nbbb\n\nccc\n", caret: 0);
        s.Press("c}");
        Assert.Equal("\n\nccc\n", s.Text);
        Assert.Equal(VimMode.Insert, s.Mode);
    }

    [Fact]
    public void CGLeavesOneEmptyLine()
    {
        var s = new VimSession("a\nb\nc\n", caret: 2);
        s.Press("cG");
        Assert.Equal("a\n\n", s.Text);
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void IndentWithACharacterMotionShiftsTheWholeLine()
    {
        var s = new VimSession("hello world\n", caret: 6);
        s.Press(">w");
        Assert.Equal("    hello world\n", s.Text);
    }

    [Fact]
    public void IndentWithAWordObjectShiftsTheWholeLine()
    {
        var s = new VimSession("hello world\n", caret: 6);
        s.Press(">iw");
        Assert.Equal("    hello world\n", s.Text);
    }
}
