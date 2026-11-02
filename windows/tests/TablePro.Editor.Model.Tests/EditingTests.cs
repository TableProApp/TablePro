namespace TablePro.Editor.Model.Tests;

public sealed class EditingTests
{
    [Fact]
    public void LineBreaksAreStoredAsLineFeedsAndExportedAsTheFileHadThem()
    {
        var document = new TextDocument("a\r\nb\r\nc");

        Assert.Equal("a\nb\nc", document.GetText());
        Assert.Equal(3, document.LineCount);
        Assert.Equal(LineEnding.CrLf, document.LineEnding);
        Assert.Equal("a\r\nb\r\nc", document.ExportText(0, document.Length));
    }

    [Theory]
    [InlineData("sel|", "(", "sel(|)")]
    [InlineData("sel|x", "(", "sel(|x")]
    [InlineData("f(|)", ")", "f()|")]
    [InlineData("where a = |", "'", "where a = '|'")]
    [InlineData("don|", "'", "don'|")]
    [InlineData("'it|'", "'", "'it'|")]
    public void PairsCloseAndStepOver(string before, string typed, string after)
    {
        var model = Carets.Model(before);
        model.Type(typed);
        Assert.Equal(after, Carets.Show(model));
    }

    [Fact]
    public void AnOpenerWrapsTheSelection()
    {
        var model = Carets.Model("select a + b from t");
        model.SetSelection(7, 12);
        model.Type("(");
        Assert.Equal("select ([a + b]) from t", Carets.Show(model));
    }

    [Fact]
    public void BackspaceBetweenAPairRemovesBoth()
    {
        var model = Carets.Model("f(|)");
        model.Backspace();
        Assert.Equal("f|", Carets.Show(model));
    }

    [Fact]
    public void BackspaceInIndentationGoesBackOneStop()
    {
        var model = Carets.Model("      |x");
        model.Backspace();
        Assert.Equal("    |x", Carets.Show(model));
    }

    [Fact]
    public void EnterKeepsIndentationAndOpensBrackets()
    {
        var model = Carets.Model("    select (|)");
        model.NewLine();
        Assert.Equal("    select (\n        |\n    )", Carets.Show(model));
    }

    [Fact]
    public void HomeAlternatesBetweenTextAndLineStart()
    {
        var model = Carets.Model("    select|");
        model.Move(CaretMove.LineStart, extend: false);
        Assert.Equal("    |select", Carets.Show(model));
        model.Move(CaretMove.LineStart, extend: false);
        Assert.Equal("|    select", Carets.Show(model));
    }

    [Theory]
    [InlineData("|select a_b, c", "select |a_b, c")]
    [InlineData("select |a_b, c", "select a_b|, c")]
    [InlineData("select a_b|, c", "select a_b, |c")]
    [InlineData("a|\nb", "a\n|b")]
    public void CtrlRightStopsAtWordStarts(string before, string after)
    {
        var model = Carets.Model(before);
        model.Move(CaretMove.WordRight, extend: false);
        Assert.Equal(after, Carets.Show(model));
    }

    [Theory]
    [InlineData("select a_b, c|", "select a_b, |c")]
    [InlineData("select a_b|", "select |a_b")]
    [InlineData("a\n|b", "a|\nb")]
    public void CtrlLeftStopsAtWordStarts(string before, string after)
    {
        var model = Carets.Model(before);
        model.Move(CaretMove.WordLeft, extend: false);
        Assert.Equal(after, Carets.Show(model));
    }

    [Fact]
    public void UpAndDownKeepTheColumn()
    {
        var model = Carets.Model("select long_n|ame\nab\nfrom other_table");
        model.Move(CaretMove.Down, extend: false);
        Assert.Equal("select long_name\nab|\nfrom other_table", Carets.Show(model));
        model.Move(CaretMove.Down, extend: false);
        Assert.Equal("select long_name\nab\nfrom other_ta|ble", Carets.Show(model));
    }

    [Fact]
    public void ShiftArrowsExtendAndArrowsCollapse()
    {
        var model = Carets.Model("ab|cd");
        model.Move(CaretMove.Right, extend: true);
        model.Move(CaretMove.Right, extend: true);
        Assert.Equal("ab[cd]", Carets.Show(model));
        model.Move(CaretMove.Left, extend: false);
        Assert.Equal("ab|cd", Carets.Show(model));
    }

    [Fact]
    public void ArrowsStepOverSurrogatePairsAndMarks()
    {
        var model = Carets.Model("|😀éx");
        model.Move(CaretMove.Right, extend: false);
        Assert.Equal(2, model.Primary.Active);
        model.Move(CaretMove.Right, extend: false);
        Assert.Equal(4, model.Primary.Active);
    }

    [Fact]
    public void CtrlDSelectsTheWordThenAddsTheNextMatch()
    {
        var model = Carets.Model("select id| from a join b on a.id = b.id");
        model.SelectNextOccurrence();
        Assert.Equal("select [id] from a join b on a.id = b.id", Carets.Show(model));
        model.SelectNextOccurrence();
        model.SelectNextOccurrence();
        Assert.Equal("select [id] from a join b on a.[id] = b.[id]", Carets.Show(model));
        model.Type("key");
        Assert.Equal("select key| from a join b on a.key| = b.key|", Carets.Show(model));
    }

    [Fact]
    public void EscapeKeepsOnlyThePrimaryCaret()
    {
        var model = Carets.Model("a|\nb|\nc|");
        Assert.True(model.CollapseToPrimary());
        Assert.Single(model.Selections);
    }

    [Fact]
    public void CtrlAltDownAddsACaretBelow()
    {
        var model = Carets.Model("ab|c\ndef\ng");
        model.AddCaretVertically(1);
        model.AddCaretVertically(1);
        Assert.Equal("ab|c\nde|f\ng|", Carets.Show(model));
    }

    [Fact]
    public void AltDragSelectsAColumn()
    {
        var model = Carets.Model("abcdef\nab\nabcdef");
        model.SetColumnSelection(0, 1, 2, 4);
        Assert.Equal("a[bcd]ef\na[b]\na[bcd]ef", Carets.Show(model));
    }

    [Fact]
    public void ToggleCommentAddsThenRemoves()
    {
        var model = Carets.Model("select 1;\n    select 2;");
        model.SelectAll();
        model.ToggleLineComment();
        Assert.Equal("--select 1;\n--    select 2;", model.Document.GetText());
        model.ToggleLineComment();
        Assert.Equal("select 1;\n    select 2;", model.Document.GetText());
    }

    [Fact]
    public void IndentAndOutdentEverySelectedLine()
    {
        var model = Carets.Model("a\nb\nc");
        model.SetSelection(0, 3);
        model.Tab();
        Assert.Equal("    a\n    b\nc", model.Document.GetText());
        model.Outdent();
        Assert.Equal("a\nb\nc", model.Document.GetText());
    }

    [Fact]
    public void AltDownMovesTheLineAndItsCaret()
    {
        var model = Carets.Model("on|e\ntwo\nthree");
        model.MoveLines(down: true);
        Assert.Equal("two\non|e\nthree", Carets.Show(model));
        model.Undo();
        Assert.Equal("on|e\ntwo\nthree", Carets.Show(model));
    }

    [Fact]
    public void ShiftAltDownCopiesTheLine()
    {
        var model = Carets.Model("on|e\ntwo");
        model.CopyLines(down: true);
        Assert.Equal("one\non|e\ntwo", Carets.Show(model));
    }

    [Fact]
    public void CtrlShiftKDeletesTheLine()
    {
        var model = Carets.Model("one\ntw|o\nthree");
        model.DeleteLines();
        Assert.Equal("one\n|three", Carets.Show(model));
    }

    [Fact]
    public void CopyWithNothingSelectedTakesTheLine()
    {
        var model = Carets.Model("one\ntw|o\nthree");
        Assert.Equal("two\n", model.CopyText());
    }

    [Fact]
    public void PasteGivesEachCaretItsOwnLine()
    {
        var model = Carets.Model("a|\nb|");
        model.Paste("1\n2");
        Assert.Equal("a1|\nb2|", Carets.Show(model));
    }

    [Fact]
    public void AnOutsideEditMovesTheCarets()
    {
        var model = Carets.Model("select |1");
        model.Document.Replace(0, 0, "-- x\n");
        Assert.Equal("-- x\nselect |1", Carets.Show(model));
    }

    [Fact]
    public void FindWrapsAndHonorsWholeWords()
    {
        var document = new TextDocument("select id, ident from t where id = 1");
        var query = new SearchQuery("id", WholeWord: true);

        var first = TextSearch.Next(document, query, 0, backward: false);
        var second = TextSearch.Next(document, query, first!.Value.Start + 1, backward: false);
        var wrapped = TextSearch.Next(document, query, second!.Value.Start + 1, backward: false);
        var back = TextSearch.Next(document, query, first.Value.Start, backward: true);

        Assert.Equal(7, first.Value.Start);
        Assert.Equal(30, second.Value.Start);
        Assert.Equal(7, wrapped!.Value.Start);
        Assert.Equal(30, back!.Value.Start);
    }
}
