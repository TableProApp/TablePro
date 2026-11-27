namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineNormalMotionsTests
{
    // Line 0 is offsets 0..11, line 1 is 12..23, line 2 is 24..34.
    private const string Standard = "hello world\nsecond line\nthird line\n";

    private static VimSession At(int caret, string text = Standard) => new(text, caret: caret);

    private static int Line(VimSession s) => s.Engine.Buffer.LineAndColumn(s.Caret).Line;

    [Fact]
    public void HMovesLeftByOne()
    {
        var s = At(5);
        s.Press("h");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void HStopsAtLineStart()
    {
        var s = At(12);
        s.Press("h");
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void HStopsAtBufferStart()
    {
        var s = At(0);
        s.Press("h");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void HWithCount()
    {
        var s = At(8);
        s.Press("5h");
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void HCountClampedToLineStart()
    {
        var s = At(14);
        s.Press("99h");
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void LMovesRightByOne()
    {
        var s = At(0);
        s.Press("l");
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void LStopsBeforeNewline()
    {
        var s = At(10);
        s.Press("l");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void LWithCount()
    {
        var s = At(0);
        s.Press("4l");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void LCountClampedToLineEnd()
    {
        var s = At(0);
        s.Press("99l");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void JMovesDownOneLine()
    {
        var s = At(0);
        s.Press("j");
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void JPreservesColumn()
    {
        var s = At(5);
        s.Press("j");
        Assert.Equal(17, s.Caret);
    }

    [Fact]
    public void JStaysOnLastLine()
    {
        var s = At(28);
        s.Press("j");
        Assert.Equal(2, Line(s));
    }

    [Fact]
    public void JWithCount()
    {
        var s = At(0);
        s.Press("2j");
        Assert.Equal(2, Line(s));
    }

    [Fact]
    public void KMovesUpOneLine()
    {
        var s = At(12);
        s.Press("k");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void KPreservesColumn()
    {
        var s = At(18);
        s.Press("k");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void KStaysOnFirstLine()
    {
        var s = At(5);
        s.Press("k");
        Assert.Equal(0, Line(s));
    }

    [Fact]
    public void KWithCount()
    {
        var s = At(28);
        s.Press("2k");
        Assert.Equal(0, Line(s));
    }

    [Fact]
    public void JGoalColumnSurvivesShortLines()
    {
        var s = At(10, "0123456789xx\nshort\n0123456789xx\n");
        // Line 1 is shorter than column 10, so the second j has to restore the goal column.
        s.Press("j");
        s.Press("j");
        var (line, col) = s.Engine.Buffer.LineAndColumn(s.Caret);
        Assert.Equal(2, line);
        Assert.Equal(10, col);
    }

    [Fact]
    public void HResetsGoalColumn()
    {
        var s = At(10);
        s.Press("jh");
        s.Press("j");
        var (line, col) = s.Engine.Buffer.LineAndColumn(s.Caret);
        Assert.Equal(2, line);
        Assert.True(col < 10, "h should reset goal column so subsequent j uses new column");
    }

    [Fact]
    public void WMovesToNextWordStart()
    {
        var s = At(0);
        s.Press("w");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void WAcrossLineBoundary()
    {
        var s = At(6);
        s.Press("w");
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void WStopsAtPunctuation()
    {
        var s = At(0, "hello,world\n");
        s.Press("w");
        Assert.Equal(5, s.Caret);
    }

    [Fact]
    public void WWithCount()
    {
        var s = At(0);
        s.Press("3w");
        Assert.Equal(19, s.Caret);
    }

    [Fact]
    public void WAtLastWordOfBufferStaysOnLastChar()
    {
        var s = At(19, "SELECT * FROM users;");
        s.Press("w");
        Assert.Equal(19, s.Caret);
    }

    [Fact]
    public void WAtLastWordSingleLineWithoutNewline()
    {
        var s = At(0, "hello");
        s.Press("w");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void WClampsToLastCharOnLineWithTrailingNewline()
    {
        var s = At(0, "hello\n");
        s.Press("w");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void CapitalWTreatsPunctuationAsWordChar()
    {
        var s = At(0, "hello,world foo\n");
        s.Key("W", shift: true);
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void CapitalWWithCount()
    {
        var s = At(0, "a.b c.d e.f g.h\n");
        s.Press("2");
        s.Key("W", shift: true);
        Assert.Equal(8, s.Caret);
    }

    [Fact]
    public void BMovesToPreviousWordStart()
    {
        var s = At(6);
        s.Press("b");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void BFromMidWordGoesToWordStart()
    {
        var s = At(3);
        s.Press("b");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void BAtStartOfBufferStaysPut()
    {
        var s = At(0);
        s.Press("b");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void BAcrossLineBoundary()
    {
        var s = At(12);
        s.Press("b");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void BWithCount()
    {
        var s = At(17);
        s.Press("3b");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void CapitalBTreatsPunctuationAsWordChar()
    {
        var s = At(8, "hello,world\n");
        s.Key("B", shift: true);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void EMovesToEndOfCurrentWord()
    {
        var s = At(0);
        s.Press("e");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void EAtWordEndJumpsToNextWordEnd()
    {
        var s = At(4);
        s.Press("e");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void EWithCount()
    {
        var s = At(0);
        s.Press("3e");
        Assert.Equal(17, s.Caret);
    }

    [Fact]
    public void CapitalEIgnoresPunctuation()
    {
        var s = At(0, "a.b.c word\n");
        s.Key("E", shift: true);
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void GEMovesToPreviousWordEnd()
    {
        var s = At(12);
        s.Press("ge");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void GEWithCount()
    {
        var s = At(17);
        s.Press("2ge");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void CapitalGEIgnoresPunctuation()
    {
        var s = At(6, "a.b.c word\n");
        s.Press("g");
        s.Key("E", shift: true);
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void ZeroGoesToLineStart()
    {
        var s = At(8);
        s.Press("0");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void ZeroIgnoresLeadingWhitespace()
    {
        var s = At(5, "   hello\n");
        s.Press("0");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void DollarGoesToLineEnd()
    {
        var s = At(0);
        s.Press("$");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void DollarOnLineWithoutTrailingNewline()
    {
        var s = At(0, "hello");
        s.Press("$");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void CaretGoesToFirstNonBlank()
    {
        var s = At(10, "   hello world\n");
        s.Press("^");
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void CaretOnBlankLineGoesToLineStart()
    {
        var s = At(6, "hello\n\nworld\n");
        s.Press("^");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void UnderscoreGoesToFirstNonBlank()
    {
        var s = At(5, "\t\thello\n");
        s.Press("_");
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void GGGoesToDocumentStart()
    {
        var s = At(25);
        s.Press("gg");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void GGGoesToFirstNonBlankOnFirstLine()
    {
        var s = At(12, "   hello\nworld\n");
        s.Press("gg");
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void CapitalGGoesToLastLineFirstNonBlank()
    {
        var s = At(0, "one\ntwo\n   three\n");
        s.Key("G", shift: true);
        Assert.Equal(11, s.Caret);
    }

    [Fact]
    public void CountGGoesToSpecificLine()
    {
        var s = At(0);
        s.Press("2");
        s.Key("G", shift: true);
        Assert.Equal(1, Line(s));
    }

    [Fact]
    public void CountGGGoesToSpecificLine()
    {
        var s = At(0);
        s.Press("2gg");
        Assert.Equal(1, Line(s));
    }

    [Fact]
    public void CountGClampedAtLastLine()
    {
        var s = At(0);
        s.Press("999");
        s.Key("G", shift: true);
        Assert.Equal(2, Line(s));
    }

    [Fact]
    public void HHomeMovesToTopOfScreen()
    {
        var s = At(28);
        s.Key("H", shift: true);
        Assert.Equal(0, Line(s));
    }

    [Fact]
    public void LLastMovesToBottomOfScreen()
    {
        var s = At(0);
        s.Key("L", shift: true);
        Assert.Equal(2, Line(s));
    }

    [Fact]
    public void MMiddleMovesToMiddleOfScreen()
    {
        var s = At(0);
        s.Key("M", shift: true);
        Assert.Equal(1, Line(s));
    }

    [Fact]
    public void PercentJumpsToMatchingParen()
    {
        var s = At(0, "(hello)\n");
        s.Press("%");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void PercentJumpsBackToOpenParen()
    {
        var s = At(6, "(hello)\n");
        s.Press("%");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void PercentMatchesNestedBrackets()
    {
        var s = At(0, "(a(b)c)\n");
        s.Press("%");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void PercentMatchesCurlyBraces()
    {
        var s = At(0, "{a}\n");
        s.Press("%");
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void PercentMatchesSquareBrackets()
    {
        var s = At(0, "[a]\n");
        s.Press("%");
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void PendingGCancelledByUnknownKey()
    {
        var s = At(5);
        s.Press("g");
        s.Press("z");
        s.Press("l");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void PendingGCancelledByEscape()
    {
        var s = At(5);
        s.Press("g");
        s.Escape();
        s.Press("l");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void MotionsOnEmptyBufferDoNotCrash()
    {
        var s = At(0, "");
        s.Press("hjklwbe0$^_");
        s.Press("gg");
        s.Key("G", shift: true);
        Assert.Equal(0, s.Caret);
        Assert.Equal("", s.Text);
    }

    [Fact]
    public void ACountBeforePercentGoesThatFarThroughTheText()
    {
        var s = At(0, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
        s.Press("50%");
        Assert.Equal(8, s.Caret);
    }

    [Fact]
    public void ACountAboveAHundredBeforePercentDoesNotMove()
    {
        var s = At(2, "a\nb\n");
        s.Press("101%");
        Assert.Equal(2, s.Caret);
        Assert.False(s.Engine.IsPending);
    }

    [Fact]
    public void ACountBeforeHGoesToThatLineFromTheTop()
    {
        var s = At(6, "a\nb\nc\nd\n");
        s.Press("2H");
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void ACountBeforeLGoesToThatLineFromTheBottom()
    {
        var s = At(0, "a\nb\nc\nd\n");
        s.Press("2L");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void ACountBeforeStarGoesToThatMatch()
    {
        var s = At(0, "foo x foo y foo z\n");
        s.Press("2*");
        Assert.Equal(12, s.Caret);
    }

    [Fact]
    public void PercentSetsThePreviousPosition()
    {
        var s = At(0, "(a) b\n");
        s.Press("%");
        Assert.Equal(2, s.Caret);
        s.Press("``");
        Assert.Equal(0, s.Caret);
    }
}
