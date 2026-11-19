using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineFindCharTests
{
    private const string Standard = "hello world foo bar\nsecond line\n";

    private static VimSession At(int caret) => new(Standard, caret: caret);

    [Fact]
    public void FMovesToNextOccurrenceOnLine()
    {
        var s = At(0);
        s.Press("fo");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void FFromMidLineFindsNextOccurrence()
    {
        var s = At(5);
        s.Press("fo");
        Assert.Equal(7, s.Caret);
    }

    [Fact]
    public void FNotFoundStaysPut()
    {
        var s = At(0);
        s.Press("fz");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void FDoesNotCrossLineBoundary()
    {
        var s = At(0);
        s.Press("fs");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void FWithCount()
    {
        var s = At(0);
        s.Press("2fo");
        Assert.Equal(7, s.Caret);
    }

    [Fact]
    public void FThirdOccurrence()
    {
        var s = At(0);
        s.Press("3fo");
        Assert.Equal(13, s.Caret);
    }

    [Fact]
    public void FCountLargerThanAvailableStaysPut()
    {
        var s = At(0);
        s.Press("99fo");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void CapitalFMovesToPreviousOccurrence()
    {
        var s = At(10);
        s.Key("F", shift: true);
        s.Key("o");
        Assert.Equal(7, s.Caret);
    }

    [Fact]
    public void CapitalFNotFoundStaysPut()
    {
        var s = At(10);
        s.Key("F", shift: true);
        s.Key("z");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void CapitalFDoesNotCrossLineBoundary()
    {
        var s = At(20);
        s.Key("F", shift: true);
        s.Key("h");
        Assert.Equal(20, s.Caret);
    }

    [Fact]
    public void CapitalFWithCount()
    {
        var s = At(18);
        s.Press("2");
        s.Key("F", shift: true);
        s.Key("o");
        Assert.Equal(13, s.Caret);
    }

    [Fact]
    public void TLandsOneCharBeforeMatch()
    {
        var s = At(0);
        s.Press("to");
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void TAlreadyAdjacentSkipsToNext()
    {
        var s = At(3);
        s.Press("to");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void TNotFoundStaysPut()
    {
        var s = At(0);
        s.Press("tz");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void TDoesNotCrossLineBoundary()
    {
        var s = At(0);
        s.Press("ts");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void TWithCount()
    {
        var s = At(0);
        s.Press("2to");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void CapitalTLandsOneCharAfterMatch()
    {
        var s = At(10);
        s.Key("T", shift: true);
        s.Key("o");
        Assert.Equal(8, s.Caret);
    }

    [Fact]
    public void CapitalTNotFoundStaysPut()
    {
        var s = At(10);
        s.Key("T", shift: true);
        s.Key("z");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void CapitalTWithCount()
    {
        var s = At(18);
        s.Press("2");
        s.Key("T", shift: true);
        s.Key("o");
        Assert.Equal(14, s.Caret);
    }

    [Fact]
    public void SemicolonRepeatsForwardFind()
    {
        var s = At(0);
        s.Press("fo");
        s.Press(";");
        Assert.Equal(7, s.Caret);
        s.Press(";");
        Assert.Equal(13, s.Caret);
    }

    [Fact]
    public void SemicolonRepeatsBackwardFind()
    {
        var s = At(18);
        s.Key("F", shift: true);
        s.Key("o");
        Assert.Equal(14, s.Caret);
        s.Press(";");
        Assert.Equal(13, s.Caret);
    }

    [Fact]
    public void SemicolonRepeatsTill()
    {
        var s = At(0);
        s.Press("to");
        Assert.Equal(3, s.Caret);
        s.Press(";");
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void SemicolonWithCount()
    {
        var s = At(0);
        s.Press("fo");
        Assert.Equal(4, s.Caret);
        s.Press("2;");
        Assert.Equal(13, s.Caret);
    }

    [Fact]
    public void CommaReversesForwardFind()
    {
        var s = At(0);
        s.Press("fo");
        s.Press("fo");
        s.Press(",");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void CommaReversesBackwardFind()
    {
        var s = At(18);
        s.Key("F", shift: true);
        s.Key("o");
        Assert.Equal(14, s.Caret);
        // No 'o' follows offset 14 on the line, so the reversed search finds nothing.
        s.Press(",");
        Assert.Equal(14, s.Caret);
    }

    [Fact]
    public void CommaWithCount()
    {
        var s = At(13);
        s.Press("fo");
        s.Press("2,");
        Assert.Equal(7, s.Caret);
    }

    [Fact]
    public void DeleteUntilCharacter()
    {
        var s = At(0);
        s.Press("dfo");
        Assert.Equal(" world foo bar\nsecond line\n", s.Text);
    }

    [Fact]
    public void DeleteTillCharacter()
    {
        var s = At(0);
        s.Press("dto");
        Assert.Equal("o world foo bar\nsecond line\n", s.Text);
    }

    [Fact]
    public void ChangeUntilCharacter()
    {
        var s = At(0);
        s.Press("cfo");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal(" world foo bar\nsecond line\n", s.Text);
    }

    [Fact]
    public void YankUntilCharacter()
    {
        var s = At(0);
        s.Press("yfo");
        Assert.Equal(Standard, s.Text);
    }

    [Fact]
    public void FThenEscapeCancels()
    {
        var s = At(0);
        s.Press("f");
        s.Escape();
        s.Press("l");
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void DCapitalFStopsShortOfTheCharacterUnderTheCursor()
    {
        var s = new VimSession("abcdef\n", caret: 4);
        s.Press("dFb");
        Assert.Equal("aef\n", s.Text);
        Assert.Equal("bcd", s.Engine.Register.Text);
    }

    [Fact]
    public void DCapitalTKeepsTheTargetAndTheCharacterUnderTheCursor()
    {
        var s = new VimSession("abcdef\n", caret: 4);
        s.Press("dTb");
        Assert.Equal("abef\n", s.Text);
        Assert.Equal("cd", s.Engine.Register.Text);
    }

    [Theory]
    [InlineData("d;w")]
    [InlineData("d,w")]
    public void ARepeatedFindWithNothingToRepeatEndsTheCommand(string keys)
    {
        var s = new VimSession("one two three\n", caret: 0);
        s.Press(keys);
        Assert.Equal("one two three\n", s.Text);
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void AFailedRepeatedFindDropsTheOperator()
    {
        var s = At(0);
        s.Press("fbd;w");
        Assert.Equal(Standard, s.Text);
        Assert.Equal(20, s.Caret);
    }
}
