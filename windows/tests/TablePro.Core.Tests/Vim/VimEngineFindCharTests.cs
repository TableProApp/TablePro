using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

public sealed class VimEngineFindCharTests
{
    // 'o' sits at offsets 4, 7, 13 and 14 on line 0; line 1 starts at 20.
    private const string Standard = "hello world foo bar\nsecond line\n";

    private static VimHarness At(int caret) => new(Standard, caret);

    [Fact]
    public void FMovesToNextOccurrenceOnLine()
    {
        var h = At(0);
        h.Keys("fo");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void FFromMidLineFindsNextOccurrence()
    {
        var h = At(5);
        h.Keys("fo");
        Assert.Equal(7, h.Pos);
    }

    [Fact]
    public void FNotFoundStaysPut()
    {
        var h = At(0);
        h.Keys("fz");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void FDoesNotCrossLineBoundary()
    {
        // The only 's' is on line 1.
        var h = At(0);
        h.Keys("fs");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void FWithCount()
    {
        var h = At(0);
        h.Keys("2fo");
        Assert.Equal(7, h.Pos);
    }

    [Fact]
    public void FThirdOccurrence()
    {
        var h = At(0);
        h.Keys("3fo");
        Assert.Equal(13, h.Pos);
    }

    [Fact]
    public void FCountLargerThanAvailableStaysPut()
    {
        var h = At(0);
        h.Keys("99fo");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void CapitalFMovesToPreviousOccurrence()
    {
        var h = At(10);
        h.Key('F', shift: true);
        h.Key('o');
        Assert.Equal(7, h.Pos);
    }

    [Fact]
    public void CapitalFNotFoundStaysPut()
    {
        var h = At(10);
        h.Key('F', shift: true);
        h.Key('z');
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void CapitalFDoesNotCrossLineBoundary()
    {
        var h = At(20);
        h.Key('F', shift: true);
        h.Key('h');
        Assert.Equal(20, h.Pos);
    }

    [Fact]
    public void CapitalFWithCount()
    {
        var h = At(18);
        h.Keys("2");
        h.Key('F', shift: true);
        h.Key('o');
        Assert.Equal(13, h.Pos);
    }

    [Fact]
    public void TLandsOneCharBeforeMatch()
    {
        var h = At(0);
        h.Keys("to");
        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void TAlreadyAdjacentSkipsToNext()
    {
        // Already just before an 'o', t moves on to the next match rather than standing still.
        var h = At(3);
        h.Keys("to");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void TNotFoundStaysPut()
    {
        var h = At(0);
        h.Keys("tz");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void TDoesNotCrossLineBoundary()
    {
        var h = At(0);
        h.Keys("ts");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void TWithCount()
    {
        var h = At(0);
        h.Keys("2to");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void CapitalTLandsOneCharAfterMatch()
    {
        var h = At(10);
        h.Key('T', shift: true);
        h.Key('o');
        Assert.Equal(8, h.Pos);
    }

    [Fact]
    public void CapitalTNotFoundStaysPut()
    {
        var h = At(10);
        h.Key('T', shift: true);
        h.Key('z');
        Assert.Equal(10, h.Pos);
    }

    [Fact]
    public void CapitalTWithCount()
    {
        // The second 'o' back from 18 is at 13, so till lands one after it.
        var h = At(18);
        h.Keys("2");
        h.Key('T', shift: true);
        h.Key('o');
        Assert.Equal(14, h.Pos);
    }

    [Fact]
    public void SemicolonRepeatsForwardFind()
    {
        var h = At(0);
        h.Keys("fo");
        h.Keys(";");
        Assert.Equal(7, h.Pos);
        h.Keys(";");
        Assert.Equal(13, h.Pos);
    }

    [Fact]
    public void SemicolonRepeatsBackwardFind()
    {
        var h = At(18);
        h.Key('F', shift: true);
        h.Key('o');
        Assert.Equal(14, h.Pos);
        h.Keys(";");
        Assert.Equal(13, h.Pos);
    }

    [Fact]
    public void SemicolonRepeatsTill()
    {
        var h = At(0);
        h.Keys("to");
        Assert.Equal(3, h.Pos);
        h.Keys(";");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void SemicolonWithCount()
    {
        var h = At(0);
        h.Keys("fo");
        Assert.Equal(4, h.Pos);
        h.Keys("2;");
        Assert.Equal(13, h.Pos);
    }

    [Fact]
    public void CommaReversesForwardFind()
    {
        var h = At(0);
        h.Keys("fo");
        h.Keys("fo");
        h.Keys(",");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void CommaReversesBackwardFind()
    {
        // No 'o' follows offset 14 on the line, so the reversed (forward) search stays put.
        var h = At(18);
        h.Key('F', shift: true);
        h.Key('o');
        Assert.Equal(14, h.Pos);
        h.Keys(",");
        Assert.Equal(14, h.Pos);
    }

    [Fact]
    public void CommaWithCount()
    {
        var h = At(13);
        h.Keys("fo");
        h.Keys("2,");
        Assert.Equal(7, h.Pos);
    }

    [Fact]
    public void DeleteUntilCharacter()
    {
        var h = At(0);
        h.Keys("dfo");
        Assert.Equal(" world foo bar\nsecond line\n", h.Text);
    }

    [Fact]
    public void DeleteTillCharacter()
    {
        var h = At(0);
        h.Keys("dto");
        Assert.Equal("o world foo bar\nsecond line\n", h.Text);
    }

    [Fact]
    public void ChangeUntilCharacter()
    {
        var h = At(0);
        h.Keys("cfo");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal(" world foo bar\nsecond line\n", h.Text);
    }

    [Fact]
    public void YankUntilCharacter()
    {
        var h = At(0);
        h.Keys("yfo");
        Assert.Equal(Standard, h.Text);
    }

    [Fact]
    public void FThenEscapeCancels()
    {
        var h = At(0);
        h.Keys("f");
        h.Key('\u001B');
        h.Keys("l");
        Assert.Equal(1, h.Pos);
    }
}
