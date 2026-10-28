namespace TablePro.Core.Tests.Vim;

public sealed class VimEngineNormalMotionsTests
{
    // Line 0 "hello world\n" is offsets 0..11, line 1 "second line\n" 12..23, line 2 "third line\n" 24..34.
    private const string Standard = "hello world\nsecond line\nthird line\n";

    private static VimHarness At(int caret) => new(Standard, caret);

    private static int LineOf(VimHarness h) => h.Buffer.LineAndColumn(h.Pos).Line;

    [Fact]
    public void HMovesLeftByOne()
    {
        var h = At(5);
        h.Keys("h");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void HStopsAtLineStart()
    {
        var h = At(12);
        h.Keys("h");
        Assert.Equal(12, h.Pos);
    }

    [Fact]
    public void HStopsAtBufferStart()
    {
        var h = At(0);
        h.Keys("h");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void HWithCount()
    {
        var h = At(8);
        h.Keys("5h");
        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void HCountClampedToLineStart()
    {
        var h = At(14);
        h.Keys("99h");
        Assert.Equal(12, h.Pos);
    }

    [Fact]
    public void LMovesRightByOne()
    {
        var h = At(0);
        h.Keys("l");
        Assert.Equal(1, h.Pos);
    }

    [Fact]
    public void LStopsBeforeNewline()
    {
        var h = At(10);
        h.Keys("l");
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void LWithCount()
    {
        var h = At(0);
        h.Keys("4l");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void LCountClampedToLineEnd()
    {
        var h = At(0);
        h.Keys("99l");
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void JMovesDownOneLine()
    {
        var h = At(0);
        h.Keys("j");
        Assert.Equal(12, h.Pos);
    }

    [Fact]
    public void JPreservesColumn()
    {
        var h = At(5);
        h.Keys("j");
        Assert.Equal(17, h.Pos);
    }

    [Fact]
    public void JStaysOnLastLine()
    {
        var h = At(28);
        h.Keys("j");
        Assert.Equal(2, LineOf(h));
    }

    [Fact]
    public void JWithCount()
    {
        var h = At(0);
        h.Keys("2j");
        Assert.Equal(2, LineOf(h));
    }

    [Fact]
    public void KMovesUpOneLine()
    {
        var h = At(12);
        h.Keys("k");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void KPreservesColumn()
    {
        var h = At(18);
        h.Keys("k");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void KStaysOnFirstLine()
    {
        var h = At(5);
        h.Keys("k");
        Assert.Equal(0, LineOf(h));
    }

    [Fact]
    public void KWithCount()
    {
        var h = At(28);
        h.Keys("2k");
        Assert.Equal(0, LineOf(h));
    }

    [Fact]
    public void JGoalColumnSurvivesShortLines()
    {
        // The goal column 10 is remembered across the shorter middle line.
        var h = new VimHarness("0123456789xx\nshort\n0123456789xx\n", 10);
        h.Keys("j");
        h.Keys("j");
        Assert.Equal((2, 10), h.Buffer.LineAndColumn(h.Pos));
    }

    [Fact]
    public void HResetsGoalColumn()
    {
        var h = At(10);
        h.Keys("jh");
        h.Keys("j");
        var (line, column) = h.Buffer.LineAndColumn(h.Pos);
        Assert.Equal(2, line);
        Assert.True(column < 10);
    }

    [Fact]
    public void WMovesToNextWordStart()
    {
        var h = At(0);
        h.Keys("w");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void WAcrossLineBoundary()
    {
        var h = At(6);
        h.Keys("w");
        Assert.Equal(12, h.Pos);
    }

    [Fact]
    public void WStopsAtPunctuation()
    {
        var h = new VimHarness("hello,world\n");
        h.Keys("w");
        Assert.Equal(5, h.Pos);
    }

    [Fact]
    public void WWithCount()
    {
        var h = At(0);
        h.Keys("3w");
        Assert.Equal(19, h.Pos);
    }

    [Fact]
    public void WAtLastWordOfBufferStaysOnLastChar()
    {
        var h = new VimHarness("SELECT * FROM users;", 19);
        h.Keys("w");
        Assert.Equal(19, h.Pos);
    }

    [Fact]
    public void WAtLastWordSingleLineWithoutNewline()
    {
        // With no next word, w clamps onto the last content character as Vim does on the last line.
        var h = new VimHarness("hello");
        h.Keys("w");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void WClampsToLastCharOnLineWithTrailingNewline()
    {
        var h = new VimHarness("hello\n");
        h.Keys("w");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void CapitalWTreatsPunctuationAsWordChar()
    {
        var h = new VimHarness("hello,world foo\n");
        h.Key('W', shift: true);
        Assert.Equal(12, h.Pos);
    }

    [Fact]
    public void CapitalWWithCount()
    {
        var h = new VimHarness("a.b c.d e.f g.h\n");
        h.Keys("2");
        h.Key('W', shift: true);
        Assert.Equal(8, h.Pos);
    }

    [Fact]
    public void BMovesToPreviousWordStart()
    {
        var h = At(6);
        h.Keys("b");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void BFromMidWordGoesToWordStart()
    {
        var h = At(3);
        h.Keys("b");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void BAtStartOfBufferStaysPut()
    {
        var h = At(0);
        h.Keys("b");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void BAcrossLineBoundary()
    {
        var h = At(12);
        h.Keys("b");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void BWithCount()
    {
        var h = At(17);
        h.Keys("3b");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void CapitalBTreatsPunctuationAsWordChar()
    {
        var h = new VimHarness("hello,world\n", 8);
        h.Key('B', shift: true);
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void EMovesToEndOfCurrentWord()
    {
        var h = At(0);
        h.Keys("e");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void EAtWordEndJumpsToNextWordEnd()
    {
        var h = At(4);
        h.Keys("e");
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void EWithCount()
    {
        var h = At(0);
        h.Keys("3e");
        Assert.Equal(17, h.Pos);
    }

    [Fact]
    public void CapitalEIgnoresPunctuation()
    {
        var h = new VimHarness("a.b.c word\n");
        h.Key('E', shift: true);
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void GeMovesToPreviousWordEnd()
    {
        var h = At(12);
        h.Keys("ge");
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void GeWithCount()
    {
        var h = At(17);
        h.Keys("2ge");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void CapitalGeIgnoresPunctuation()
    {
        var h = new VimHarness("a.b.c word\n", 6);
        h.Keys("g");
        h.Key('E', shift: true);
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void ZeroGoesToLineStart()
    {
        var h = At(8);
        h.Keys("0");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void ZeroIgnoresLeadingWhitespace()
    {
        var h = new VimHarness("   hello\n", 5);
        h.Keys("0");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void DollarGoesToLineEnd()
    {
        var h = At(0);
        h.Keys("$");
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void DollarOnLineWithoutTrailingNewline()
    {
        var h = new VimHarness("hello");
        h.Keys("$");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void CaretGoesToFirstNonBlank()
    {
        var h = new VimHarness("   hello world\n", 10);
        h.Keys("^");
        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void CaretOnBlankLineGoesToLineStart()
    {
        var h = new VimHarness("hello\n\nworld\n", 6);
        h.Keys("^");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void UnderscoreGoesToFirstNonBlank()
    {
        var h = new VimHarness("\t\thello\n", 5);
        h.Keys("_");
        Assert.Equal(2, h.Pos);
    }

    [Fact]
    public void GgGoesToDocumentStart()
    {
        var h = At(25);
        h.Keys("gg");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void GgGoesToFirstNonBlankOnFirstLine()
    {
        var h = new VimHarness("   hello\nworld\n", 12);
        h.Keys("gg");
        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void CapitalGGoesToLastLineFirstNonBlank()
    {
        var h = new VimHarness("one\ntwo\n   three\n");
        h.Key('G', shift: true);
        Assert.Equal(11, h.Pos);
    }

    [Fact]
    public void CountGGoesToSpecificLine()
    {
        var h = At(0);
        h.Keys("2");
        h.Key('G', shift: true);
        Assert.Equal(1, LineOf(h));
    }

    [Fact]
    public void CountGgGoesToSpecificLine()
    {
        var h = At(0);
        h.Keys("2gg");
        Assert.Equal(1, LineOf(h));
    }

    [Fact]
    public void CountGClampedAtLastLine()
    {
        var h = At(0);
        h.Keys("999");
        h.Key('G', shift: true);
        Assert.Equal(2, LineOf(h));
    }

    [Fact]
    public void HHomeMovesToTopOfScreen()
    {
        // The fake buffer shows every line, so the screen top is the first line.
        var h = At(28);
        h.Key('H', shift: true);
        Assert.Equal(0, LineOf(h));
    }

    [Fact]
    public void LLastMovesToBottomOfScreen()
    {
        var h = At(0);
        h.Key('L', shift: true);
        Assert.Equal(2, LineOf(h));
    }

    [Fact]
    public void MMiddleMovesToMiddleOfScreen()
    {
        var h = At(0);
        h.Key('M', shift: true);
        Assert.Equal(1, LineOf(h));
    }

    [Fact]
    public void PercentJumpsToMatchingParen()
    {
        var h = new VimHarness("(hello)\n");
        h.Keys("%");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void PercentJumpsBackToOpenParen()
    {
        var h = new VimHarness("(hello)\n", 6);
        h.Keys("%");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void PercentMatchesNestedBrackets()
    {
        var h = new VimHarness("(a(b)c)\n");
        h.Keys("%");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void PercentMatchesCurlyBraces()
    {
        var h = new VimHarness("{a}\n");
        h.Keys("%");
        Assert.Equal(2, h.Pos);
    }

    [Fact]
    public void PercentMatchesSquareBrackets()
    {
        var h = new VimHarness("[a]\n");
        h.Keys("%");
        Assert.Equal(2, h.Pos);
    }

    [Fact]
    public void PendingGCancelledByUnknownKey()
    {
        // gz is no command, so it is dropped and the following l is a plain motion.
        var h = At(5);
        h.Keys("g");
        h.Keys("z");
        h.Keys("l");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void PendingGCancelledByEscape()
    {
        var h = At(5);
        h.Keys("g");
        h.Key('\u001B');
        h.Keys("l");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void MotionsOnEmptyBufferDoNotCrash()
    {
        var h = new VimHarness(string.Empty);
        h.Keys("hjklwbe0$^_");
        h.Keys("gg");
        h.Key('G', shift: true);
        Assert.Equal(0, h.Pos);
        Assert.Equal(string.Empty, h.Text);
    }
}
