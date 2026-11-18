namespace TablePro.Editor.Model.Tests;

public sealed class WrapTests
{
    private static List<int> Breaks(string line, int columns, int tabSize = 4)
    {
        var breaks = new List<int>();
        LineWrap.Breaks(line, columns, tabSize, breaks);
        return breaks;
    }

    [Fact]
    public void ALineThatFitsDoesNotBreak()
    {
        Assert.Empty(Breaks("select 1", 8));
        Assert.Empty(Breaks(string.Empty, 8));
    }

    [Fact]
    public void ARowBreaksAfterItsLastSpaceAndSpacesHangPastTheEdge()
    {
        Assert.Equal([11], Breaks("select abc from t", 10));
        Assert.Equal([7, 16], Breaks("select abc from t", 8));
        Assert.Equal([15], Breaks("abcdefghij     k", 10));
    }

    [Fact]
    public void AWordLongerThanTheRowBreaksAtTheEdge()
    {
        Assert.Equal([4, 8], Breaks("abcdefghij", 4));
    }

    [Fact]
    public void WideCharactersTakeTwoColumnsAndAPairIsNeverSplit()
    {
        Assert.Equal([2], Breaks("你好世界", 5));
        Assert.Equal([4], Breaks("😀😀😀", 4));
    }

    [Fact]
    public void ACombiningMarkStaysWithItsLetter()
    {
        // The accent takes no column, so the row breaks after it and not between it and its letter.
        Assert.Equal([4], Breaks("abe" + (char)0x301 + "cd", 3));
    }

    [Fact]
    public void ASpacingMarkStaysWithItsLetterAndHomeLandsAfterIt()
    {
        var line = "1234567" + (char)0x915 + (char)0x93E + "x";
        Assert.Equal([9], Breaks(line, 8));

        var model = Carets.Model(line);
        model.Rows.SetWrap(8, 4);
        model.SetCaret(line.Length);
        model.Move(CaretMove.LineStart, extend: false);
        Assert.Equal(9, model.Primary.Active);
        model.Move(CaretMove.Up, extend: false);
        model.Move(CaretMove.LineEnd, extend: false);
        Assert.Equal(7, model.Primary.Active);
    }

    [Fact]
    public void ATabRunsToTheNextStopOfItsRow()
    {
        Assert.Equal(8, LineWrap.Columns("ab\tc".AsSpan(0, 3), 8));
        Assert.Equal(9, LineWrap.Columns("ab\tc", 8));
        Assert.Equal(3, LineWrap.OffsetAtColumn("ab\tcd", 8, 8));
    }

    [Fact]
    public void RowsFollowTheBreaksAndHomeAndEndStayOnTheRow()
    {
        var model = Carets.Model("select abc from t\nx");
        model.Rows.SetWrap(8, 4);

        Assert.Equal(4, model.Rows.RowCount);
        Assert.Equal((0, 7, 16), model.Rows.RowSpan(1));
        Assert.Equal(3, model.Rows.FirstRowOf(1));
        Assert.Equal(1, model.Rows.RowOf(7));
        Assert.Equal(2, model.Rows.RowOf(17));

        model.SetCaret(9);
        model.Move(CaretMove.LineStart, extend: false);
        Assert.Equal(7, model.Primary.Active);
        model.Move(CaretMove.LineEnd, extend: false);
        Assert.Equal(15, model.Primary.Active);
    }

    [Fact]
    public void UpAndDownMoveByRowsAndKeepTheirColumn()
    {
        var model = Carets.Model("select abc from t\nxy");
        model.Rows.SetWrap(8, 4);
        model.SetCaret(2);

        model.Move(CaretMove.Down, extend: false);
        Assert.Equal(9, model.Primary.Active);
        model.Move(CaretMove.Down, extend: false);
        Assert.Equal(17, model.Primary.Active);
        model.Move(CaretMove.Down, extend: false);
        Assert.Equal(20, model.Primary.Active);
        model.Move(CaretMove.Up, extend: false);
        Assert.Equal(17, model.Primary.Active);
    }

    [Fact]
    public void EndOfAWrappedRowNeverLandsBetweenALetterAndItsAccent()
    {
        var model = Carets.Model("1234567e" + (char)0x301 + "x yz");
        model.Rows.SetWrap(8, 4);

        model.Move(CaretMove.LineEnd, extend: false);

        Assert.Equal(7, model.Primary.Active);
    }

    [Fact]
    public void AColumnSelectionTakesEachRowOfAWrappedLine()
    {
        var model = Carets.Model("select abc from t");
        model.Rows.SetWrap(8, 4);

        model.SetRowColumnSelection(0, 1, 1, 3);

        Assert.Equal("s[el]ect a[bc] from t", Carets.Show(model));
        Assert.Equal((1, 3), model.RowColumnOf(10));
    }

    [Fact]
    public void AnEditLaysOutOnlyItsLinesAgain()
    {
        var model = Carets.Model("ab\ncd|");
        model.Rows.SetWrap(4, 4);
        Assert.Equal(2, model.Rows.RowCount);

        model.Type(" efgh ijkl");
        Assert.Equal(4, model.Rows.RowCount);
        model.Undo();
        Assert.Equal(2, model.Rows.RowCount);
    }

    [Fact]
    public void TurningWrapOffGivesOneRowALine()
    {
        var model = Carets.Model("select abc from t");
        model.Rows.SetWrap(10, 4);
        Assert.False(model.Rows.SetWrap(10, 4));
        Assert.True(model.Rows.SetWrap(0, 4));
        Assert.True(model.Rows.IsIdentity);
        Assert.Equal(1, model.Rows.RowCount);
    }
}
