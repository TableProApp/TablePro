namespace TablePro.Editor.Model.Tests;

public sealed class UndoTests
{
    [Fact]
    public void OneUndoRemovesAWordTypedWithoutSpaces()
    {
        var model = Carets.Model("SELECT 1;\n|FROM t;");
        foreach (var c in "abcdefgh")
        {
            model.Type(c.ToString());
        }
        Assert.Equal(1, model.Document.Undo.UndoCount);

        model.Undo();

        Assert.Equal("SELECT 1;\n|FROM t;", Carets.Show(model));
        Assert.False(model.Document.Undo.CanUndo);
    }

    [Fact]
    public void ASpaceAfterAWordStartsTheNextStep()
    {
        var model = Carets.Model("|");
        foreach (var c in "select *")
        {
            model.Type(c.ToString());
        }

        model.Undo();
        Assert.Equal("select|", Carets.Show(model));
        model.Undo();
        Assert.Equal("|", Carets.Show(model));
    }

    [Fact]
    public void MovingTheCaretEndsTheTypingStep()
    {
        var model = Carets.Model("x|");
        model.Type("a");
        model.Move(CaretMove.Left, extend: false);
        model.Move(CaretMove.Right, extend: false);
        model.Type("b");

        model.Undo();

        Assert.Equal("xa|", Carets.Show(model));
    }

    [Fact]
    public void ABackspaceRunIsOneStepAndRedoBringsItBack()
    {
        var model = Carets.Model("select column_name|");
        for (var i = 0; i < 6; i++)
        {
            model.Backspace();
        }
        Assert.Equal("select colum|", Carets.Show(model));

        model.Undo();
        Assert.Equal("select column_name|", Carets.Show(model));
        model.Redo();
        Assert.Equal("select colum|", Carets.Show(model));
    }

    [Fact]
    public void TypingAtThreeCaretsIsOneStepPerRun()
    {
        var model = Carets.Model("a|\nb|\nc|");
        model.Type("x");
        model.Type("y");

        Assert.Equal("axy|\nbxy|\ncxy|", Carets.Show(model));
        model.Undo();
        Assert.Equal("a|\nb|\nc|", Carets.Show(model));
    }

    [Fact]
    public void ColoringNeverAddsAStep()
    {
        var document = new TextDocument("select 1;\n/* a\n b */ select 'x';");
        var model = new EditorModel(document);
        var highlighter = new SyntaxHighlighter(document, new FakeLexer());
        model.SetCaret(document.Length);
        model.Type("z");
        var steps = document.Undo.UndoCount;
        var spans = new List<SyntaxSpan>();

        highlighter.GetTokens(0, document.LineCount - 1, spans);
        highlighter.EnsureStates(document.LineCount - 1);

        Assert.NotEmpty(spans);
        Assert.Equal(steps, document.Undo.UndoCount);
        model.Undo();
        Assert.Equal("select 1;\n/* a\n b */ select 'x';", document.GetText());
    }

    [Fact]
    public void PasteIsItsOwnStep()
    {
        var model = Carets.Model("|");
        model.Type("a");
        model.Paste("bcd");
        model.Type("e");

        model.Undo();
        Assert.Equal("abcd|", Carets.Show(model));
        model.Undo();
        Assert.Equal("a|", Carets.Show(model));
    }

    [Fact]
    public void UndoRestoresTheSelectionTypedOver()
    {
        var model = Carets.Model("select name from t");
        model.SetSelection(7, 11);
        model.Type("id");

        model.Undo();

        Assert.Equal("select [name] from t", Carets.Show(model));
    }

    [Fact]
    public void ANewEditClearsRedo()
    {
        var model = Carets.Model("|");
        model.Type("a");
        model.Undo();
        model.Type("b");

        Assert.False(model.Document.Undo.CanRedo);
    }
}
