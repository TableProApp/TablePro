using TablePro.Core.Editing.MultiCursor;
using TablePro.Core.Keymaps;
using TablePro.Core.Tests.MultiCursor;

namespace TablePro.Core.Tests.Keymaps;

/// <summary>The macOS editor's Emacs interceptor tests, run against the engine over the multi-caret model.</summary>
public sealed class EmacsEngineTests
{
    private readonly FakeMultiCursorBuffer _buffer = new("SELECT id FROM users\nWHERE id = 1");
    private readonly MultiCursorModel _model;
    private readonly EmacsEngine _engine;

    public EmacsEngineTests()
    {
        _model = new MultiCursorModel(_buffer);
        _engine = new EmacsEngine(_model, new KillRing());
    }

    private Caret Selection => Assert.Single(_model.Carets);

    private void CaretAt(int offset) => _model.Reset(offset, offset);

    private void Press(EmacsCommandKind kind) => _engine.Perform(EmacsCommand.Of(kind));

    private void Press(EmacsMotion motion) => _engine.Perform(EmacsCommand.Move(motion));

    /// <summary>Resolves a key the way the editor does, so the arrows see whether the mark is active.</summary>
    private bool PressKey(EmacsKey key, char character = '\0', bool control = false, bool alt = false)
    {
        if (EmacsKeymap.Resolve(new EmacsKeystroke(key, character, control, alt), _engine.IsMarkActive) is not { } command)
        {
            return false;
        }

        _engine.Perform(command);
        return true;
    }

    [Fact]
    public void ControlAndMetaKeysMoveTheCaret()
    {
        Press(EmacsMotion.ForwardChar);
        Assert.Equal(Caret.At(1), Selection);
        Press(EmacsMotion.BackwardChar);
        Assert.Equal(Caret.At(0), Selection);
        Press(EmacsMotion.ForwardWord);
        Assert.Equal(Caret.At(6), Selection);
        Press(EmacsMotion.EndOfLine);
        Assert.Equal(Caret.At(20), Selection);
        Press(EmacsMotion.BeginningOfLine);
        Assert.Equal(Caret.At(0), Selection);
        Press(EmacsMotion.NextLine);
        Assert.Equal(21, Selection.Active);
    }

    [Fact]
    public void SetMarkThenMotionsGrowTheRegionEitherWay()
    {
        CaretAt(7);
        Press(EmacsCommandKind.SetMark);
        Press(EmacsMotion.ForwardWord);
        Assert.Equal((7, 9), (Selection.Start, Selection.End));
        Press(EmacsMotion.BackwardChar);
        Press(EmacsMotion.BackwardChar);
        Press(EmacsMotion.BackwardChar);
        Assert.Equal((6, 7), (Selection.Start, Selection.End));
        Assert.True(PressKey(EmacsKey.Right));
        Assert.Equal(Caret.At(7), Selection with { PreferredColumn = -1 });
    }

    [Fact]
    public void KillRegionThenYankPutsItBack()
    {
        CaretAt(7);
        Press(EmacsCommandKind.SetMark);
        Press(EmacsMotion.ForwardWord);
        Press(EmacsCommandKind.KillRegion);
        Assert.Equal("SELECT  FROM users\nWHERE id = 1", _buffer.Text);
        CaretAt(0);
        Press(EmacsCommandKind.Yank);
        Assert.Equal("idSELECT  FROM users\nWHERE id = 1", _buffer.Text);
    }

    [Fact]
    public void CopyRegionEndsItAndLeavesTheTextAlone()
    {
        Press(EmacsCommandKind.SetMark);
        Press(EmacsMotion.ForwardWord);
        Press(EmacsCommandKind.CopyRegion);
        Assert.Equal("SELECT id FROM users\nWHERE id = 1", _buffer.Text);
        Assert.Equal(Caret.At(6), Selection with { PreferredColumn = -1 });
        Press(EmacsMotion.ForwardChar);
        Assert.Equal(Caret.At(7), Selection);
        Press(EmacsCommandKind.Yank);
        Assert.Equal("SELECT SELECTid FROM users\nWHERE id = 1", _buffer.Text);
    }

    [Fact]
    public void QuitEndsTheRegionAtPoint()
    {
        Press(EmacsCommandKind.SetMark);
        Press(EmacsMotion.EndOfLine);
        Assert.Equal((0, 20), (Selection.Start, Selection.End));
        Press(EmacsCommandKind.Quit);
        Assert.Equal(Caret.At(20), Selection with { PreferredColumn = -1 });
        Press(EmacsMotion.BackwardChar);
        Assert.Equal(Caret.At(19), Selection);
    }

    [Fact]
    public void AChangeFromOutsideEndsTheRegion()
    {
        Press(EmacsCommandKind.SetMark);
        Press(EmacsMotion.ForwardChar);
        CaretAt(10);
        Press(EmacsMotion.ForwardChar);
        Assert.Equal(Caret.At(11), Selection);
        Assert.False(PressKey(EmacsKey.Right));
    }

    [Fact]
    public void AClickWhereTheCaretAlreadyIsStillEndsTheRegion()
    {
        Press(EmacsCommandKind.SetMark);
        _model.Touch();
        Press(EmacsMotion.ForwardChar);
        Assert.Equal(Caret.At(1), Selection);
    }

    [Fact]
    public void KillLineWithAnActiveRegionKillsFromPoint()
    {
        Press(EmacsCommandKind.SetMark);
        Press(EmacsMotion.ForwardWord);
        Press(EmacsCommandKind.KillLine);
        Assert.Equal("SELECT\nWHERE id = 1", _buffer.Text);
    }

    [Fact]
    public void KillLineAtTheEndOfALineKillsTheBreak()
    {
        Press(EmacsMotion.EndOfLine);
        Press(EmacsCommandKind.KillLine);
        Assert.Equal("SELECT id FROM usersWHERE id = 1", _buffer.Text);
    }

    [Fact]
    public void KillWordsInARowJoinOneEntryAndYankPopWalksTheRing()
    {
        Press(EmacsCommandKind.KillWord);
        Press(EmacsCommandKind.KillWord);
        Assert.Equal(" FROM users\nWHERE id = 1", _buffer.Text);
        Press(EmacsMotion.EndOfLine);
        Assert.True(PressKey(EmacsKey.Backspace, alt: true));
        Assert.Equal(" FROM \nWHERE id = 1", _buffer.Text);
        Press(EmacsCommandKind.Yank);
        Assert.Equal(" FROM users\nWHERE id = 1", _buffer.Text);
        Press(EmacsCommandKind.YankPop);
        Assert.Equal(" FROM SELECT id\nWHERE id = 1", _buffer.Text);
        Press(EmacsCommandKind.YankPop);
        Assert.Equal(" FROM users\nWHERE id = 1", _buffer.Text);
    }

    [Fact]
    public void BackwardKillsInARowPrependToOneEntry()
    {
        Press(EmacsMotion.EndOfLine);
        Press(EmacsCommandKind.BackwardKillWord);
        Press(EmacsCommandKind.BackwardKillWord);
        Assert.Equal("SELECT id \nWHERE id = 1", _buffer.Text);
        CaretAt(0);
        Press(EmacsCommandKind.Yank);
        Assert.StartsWith("FROM usersSELECT", _buffer.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void YankPopWithoutAYankDoesNothing()
    {
        Press(EmacsCommandKind.KillWord);
        Press(EmacsCommandKind.YankPop);
        Assert.Equal(" id FROM users\nWHERE id = 1", _buffer.Text);
    }

    [Fact]
    public void KillAndYankAtSeveralCaretsKeepOnePiecePerCaret()
    {
        _model.SetCarets([Caret.At(0), Caret.At(21)], 1);
        Press(EmacsCommandKind.KillWord);
        Assert.Equal(" id FROM users\n id = 1", _buffer.Text);
        Press(EmacsMotion.EndOfLine);
        Press(EmacsCommandKind.Yank);
        Assert.Equal(" id FROM usersSELECT\n id = 1WHERE", _buffer.Text);
    }

    [Fact]
    public void TheMarkExtendsEveryCaret()
    {
        _model.SetCarets([Caret.At(0), Caret.At(21)], 0);
        Press(EmacsCommandKind.SetMark);
        Press(EmacsMotion.ForwardWord);
        Assert.Equal("SELECT,WHERE", string.Join(',', _model.SelectedTexts()));
    }

    [Fact]
    public void UnboundKeysAreNotClaimed()
    {
        Assert.False(PressKey(EmacsKey.Character, 't', control: true));
        Assert.False(PressKey(EmacsKey.Character, 'l', alt: true));
        Assert.False(PressKey(EmacsKey.Character, 'x'));
    }

    [Fact]
    public void KillRingKeepsItsCapacity()
    {
        var ring = new KillRing(2);
        var owner = new object();
        ring.Kill(["a"], forward: true, before: null, after: new KillContinuation(owner, 1, 0));
        ring.Kill(["b"], forward: true, before: null, after: new KillContinuation(owner, 2, 0));
        ring.Kill(["c"], forward: true, before: null, after: new KillContinuation(owner, 3, 0));
        Assert.Equal(2, ring.Entries.Count);
        Assert.Equal("c", ring.Yank()[0]);
        Assert.Equal("b", ring.Rotate()[0]);
        Assert.Equal("c", ring.Rotate()[0]);
    }

    [Fact]
    public void AKillContinuesOnlyFromWhereThePreviousOneLeftTheEditor()
    {
        var ring = new KillRing();
        var owner = new object();
        var state = new KillContinuation(owner, 1, 10);
        ring.Kill(["ab"], forward: true, before: null, after: state);
        ring.Kill(["cd"], forward: true, before: state, after: state with { Version = 2 });
        ring.Kill(["ef"], forward: true, before: new KillContinuation(new object(), 2, 10), after: state);
        Assert.Equal("ef", ring.Entries[0][0]);
        Assert.Equal("abcd", ring.Entries[1][0]);
    }
}
