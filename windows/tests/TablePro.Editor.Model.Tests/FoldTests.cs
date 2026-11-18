namespace TablePro.Editor.Model.Tests;

public sealed class FoldTests
{
    private const string Script = "select a,\n  b,\n  c\nfrom t;\nselect 1;\nselect (\n  2\n);";

    private static DocumentStructure Analyze(string text) =>
        DocumentStructure.Analyze(text, 1, new FakeLexer(), new FakeStructure());

    [Fact]
    public void StatementsBracketsAndBlockCommentsFold()
    {
        var structure = Analyze(Script + "\n/* one\ntwo */");

        Assert.Equal(
            [new FoldRegion(0, 3), new FoldRegion(5, 7), new FoldRegion(8, 9)],
            structure.Regions);
    }

    [Fact]
    public void ABracketFoldLeavesItsCloserOnScreen()
    {
        var structure = Analyze("x;\nselect *\nfrom (\n  select 1\n  from t\n) s;");

        Assert.Contains(new FoldRegion(2, 4), structure.Regions);
        Assert.Contains(new FoldRegion(1, 5), structure.Regions);
    }

    [Fact]
    public void BracketsInStringsAndCommentsOpenNothing()
    {
        var structure = Analyze("x;\nselect ')' /* ( */,\n(\n  1\n  )");

        Assert.Equal([new FoldRegion(1, 4), new FoldRegion(2, 3)], structure.Regions);
    }

    [Fact]
    public void BeginBlocksFoldButBeginTransactionDoesNot()
    {
        var text = "create procedure p()\nbegin\n  select 1;\n  select 2;\nend;\nbegin transaction;\ncommit;";
        var structure = DocumentStructure.Analyze(text, 1, new FakeLexer(), new NoStatements());

        Assert.Equal([new FoldRegion(1, 3)], structure.Regions);
    }

    [Fact]
    public void CaseEndsAtEndAndEndIfClosesNothing()
    {
        var text = "select\ncase\n  when 1 then 2\nend\nx\nbegin\n if a then\n  b;\n end if;\nend";
        var structure = DocumentStructure.Analyze(text, 1, new FakeLexer(), new NoStatements());

        Assert.Contains(new FoldRegion(1, 2), structure.Regions);
        Assert.Contains(new FoldRegion(5, 8), structure.Regions);
    }

    [Fact]
    public void WhereRegionsStartOnOneLineTheLargerOneStays()
    {
        var structure = Analyze("select (\n  1\n) +\n  2;");

        Assert.Equal([new FoldRegion(0, 3)], structure.Regions);
    }

    [Fact]
    public void ATextPastTheLimitHasNoStructure()
    {
        var structure = Analyze(new string('a', DocumentStructure.SizeLimit + 1));

        Assert.Empty(structure.Statements);
        Assert.Empty(structure.Regions);
    }

    [Fact]
    public void TheStatementAtTheCaretIsTheOneItIsInOrTheLastBefore()
    {
        var structure = Analyze("  select 1;\n\nselect 2;  ");

        Assert.Equal((2, 10), structure.StatementAt(0));
        Assert.Equal((2, 10), structure.StatementAt(11));
        Assert.Equal((13, 21), structure.StatementAt(13));
        Assert.Equal((13, 21), structure.StatementAt(24));
        Assert.Null(Analyze("/* nothing */").StatementAt(3));
    }

    [Fact]
    public void FoldAllFoldsTopLevelRegionsOnly()
    {
        var structure = Analyze("select (\n  1\n) + (\n 2\n);\nx;");

        Assert.Equal([new FoldRegion(0, 4)], structure.TopLevel());
        Assert.Equal(new FoldRegion(2, 3), structure.InnermostAround(3));
    }

    [Fact]
    public void AFoldHidesItsLinesFromTheRowsAndMovesSkipIt()
    {
        var model = Carets.Model(Script);
        model.Rows.Folds.Fold(new FoldRegion(0, 3));

        Assert.Equal(5, model.Rows.RowCount);
        Assert.Equal(1, model.Rows.FirstRowOf(4));
        Assert.Equal(4, model.Rows.LineAtRow(1));
        Assert.Equal(0, model.Rows.RowOf(12));

        model.SetCaret(9);
        model.Move(CaretMove.Down, extend: false);
        Assert.Equal(36, model.Primary.Active);
        model.Move(CaretMove.Up, extend: false);
        Assert.Equal(9, model.Primary.Active);
        model.Move(CaretMove.Right, extend: false);
        Assert.Equal(27, model.Primary.Active);
        model.Move(CaretMove.Left, extend: false);
        Assert.Equal(9, model.Primary.Active);
        Assert.True(model.Rows.Folds.IsFolded(0));
    }

    [Fact]
    public void DownFromAFoldOverTheLastLinesKeepsItShut()
    {
        var model = Carets.Model("x;\nselect a,\n  b;");
        model.Rows.Folds.Fold(new FoldRegion(1, 2));
        model.SetCaret(4);

        model.Move(CaretMove.Down, extend: false);
        model.Move(CaretMove.PageDown, extend: false, pageLines: 10);

        Assert.True(model.Rows.Folds.IsFolded(1));
        Assert.Equal(model.Document.GetLineEnd(1), model.Primary.Active);
    }

    [Fact]
    public void ACaretSentIntoAFoldOpensIt()
    {
        var model = Carets.Model(Script);
        model.Rows.Folds.Fold(new FoldRegion(0, 3));

        model.SetCaret(13);

        Assert.Equal(0, model.Rows.Folds.Count);
        Assert.True(model.Rows.IsIdentity);
    }

    [Fact]
    public void TypingOnTheFirstLineKeepsTheFoldAndEditsBelowShiftIt()
    {
        var model = Carets.Model("x;\n" + Script);
        model.Rows.Folds.Fold(new FoldRegion(1, 4));

        model.SetCaret(1);
        model.Type("y");
        Assert.Equal([new FoldRegion(1, 4)], model.Rows.Folds.Folded);
        model.SetCaret(3);
        model.NewLine();
        Assert.Equal([new FoldRegion(2, 5)], model.Rows.Folds.Folded);
        model.SetCaret(model.Document.GetLineEnd(2));
        model.Type("z");
        Assert.Equal([new FoldRegion(2, 5)], model.Rows.Folds.Folded);
        model.Type("\n");
        Assert.Empty(model.Rows.Folds.Folded);
    }

    [Fact]
    public void AFoldStaysOnlyWhileItsRegionDoes()
    {
        var folds = new FoldSet();
        folds.Fold(new FoldRegion(0, 3));
        folds.Fold(new FoldRegion(5, 6));

        Assert.True(folds.Reconcile([new FoldRegion(0, 4), new FoldRegion(9, 10)]));

        Assert.Equal([new FoldRegion(0, 4)], folds.Folded);
    }

    [Fact]
    public void NestedFoldsMergeTheirHiddenLines()
    {
        var folds = new FoldSet();
        folds.Fold(new FoldRegion(0, 5));
        folds.Fold(new FoldRegion(2, 3));
        folds.Fold(new FoldRegion(6, 8));

        Assert.Equal([(1, 5), (7, 8)], folds.Hidden);
        Assert.Equal(0, folds.VisibleLine(3));
        Assert.True(folds.Reveal(3));
        Assert.Equal([new FoldRegion(6, 8)], folds.Folded);
    }

    [Fact]
    public void AStructureMappedThroughAnEditShiftsWhatComesAfter()
    {
        var document = new TextDocument("x;\n" + Script);
        var structure = Analyze(document.GetText());
        DocumentStructure? mapped = null;
        document.Changed += (_, change) => mapped = structure.Map(change);

        document.Replace(0, 0, "\n");

        Assert.Equal(new FoldRegion(2, 5), mapped!.Regions[0]);
        Assert.Equal((4, 29), mapped.Statements[1]);
    }

    // Only the keyword blocks, so a test reads their regions alone.
    private sealed class NoStatements : ISqlStructure
    {
        public SyntaxRoles Roles => FakeStructure.FakeRoles;

        public void SplitStatements(ReadOnlySpan<char> text, List<(int Start, int End)> statements)
        {
        }
    }
}
