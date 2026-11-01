using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

public sealed class VimEngineControlKeyTests
{
    private static readonly string ThirtyLines = string.Concat(Enumerable.Range(0, 30).Select(i => $"line{i} text\n"));

    private static VimHarness AtLine(int line, int column = 0)
    {
        var h = new VimHarness(ThirtyLines);
        h.Select(h.Buffer.OffsetForLine(line, column));
        return h;
    }

    private static bool Control(VimHarness h, char letter) => h.Key((char)(letter & 0x1F));

    private static int LineOf(VimHarness h) => h.Buffer.LineAndColumn(h.Pos).Line;

    private static (int Start, int Length) SelectionOf(VimHarness h) => (h.Buffer.SelectionStart, h.Buffer.SelectionLength);

    [Fact]
    public void ControlRRedoesThroughTheEngine()
    {
        var h = AtLine(0);
        Assert.True(Control(h, 'r'));
        Assert.Equal(1, h.Buffer.RedoCount);
    }

    [Fact]
    public void ControlRTakesACount()
    {
        var h = AtLine(0);
        h.Keys("3");
        Control(h, 'r');
        Assert.Equal(3, h.Buffer.RedoCount);
    }

    [Fact]
    public void ControlHMovesLeftLikeH()
    {
        // In normal mode Ctrl+H is a motion, never a delete.
        var h = AtLine(0, 5);
        var original = h.Text;
        Assert.True(Control(h, 'h'));
        Assert.Equal(4, h.Pos);
        Assert.Equal(original, h.Text);
    }

    [Fact]
    public void ControlHTakesACount()
    {
        var h = AtLine(0, 5);
        h.Keys("3");
        Control(h, 'h');
        Assert.Equal(2, h.Pos);
    }

    [Fact]
    public void ControlNAndControlPMoveBetweenLines()
    {
        var h = AtLine(4, 2);
        Control(h, 'n');
        Assert.Equal(5, LineOf(h));
        Control(h, 'p');
        Control(h, 'p');
        Assert.Equal(3, LineOf(h));
    }

    [Fact]
    public void ControlNCompletesAPendingOperatorLikeJ()
    {
        var h = new VimHarness("one\ntwo\nthree\n");
        h.Keys("d");
        Control(h, 'n');
        Assert.Equal("three\n", h.Text);
    }

    [Fact]
    public void ScrollControlCancelsAPendingOperator()
    {
        // Ctrl+D is no motion, so it abandons the pending d and the w after it only moves.
        var h = new VimHarness("one two three\n");
        h.Keys("d");
        Control(h, 'd');
        h.Keys("w");
        Assert.Equal("one two three\n", h.Text);
        Assert.Null(h.Engine.PendingOperator);
    }

    [Fact]
    public void ScrollControlUsesAndConsumesItsCount()
    {
        var h = AtLine(0);
        h.Keys("4");
        Control(h, 'd');
        Assert.Equal(4, LineOf(h));
        h.Keys("j");
        Assert.Equal(5, LineOf(h));
    }

    [Fact]
    public void UnboundControlCharacterDoesNotEditInNormalMode()
    {
        var h = AtLine(0, 3);
        var original = h.Text;
        Assert.True(Control(h, 'k'));
        Assert.True(Control(h, 'o'));
        Assert.True(Control(h, 't'));
        Assert.Equal(original, h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void OptionTypedCharactersDoNotEditInNormalMode()
    {
        var h = AtLine(0, 3);
        var original = h.Text;
        Assert.True(h.Key('˙'));
        Assert.True(h.Key(' '));
        Assert.Equal(original, h.Text);
    }

    [Fact]
    public void ReplaceCharConsumesAControlCharacterWithoutWritingIt()
    {
        // r takes Ctrl+D as its argument, so the x after it deletes.
        var h = new VimHarness("hello\n");
        h.Keys("r");
        Control(h, 'd');
        h.Keys("x");
        Assert.Equal("ello\n", h.Text);
    }

    [Fact]
    public void ControlDExtendsTheVisualSelection()
    {
        var h = AtLine(0);
        h.Keys("v");
        Control(h, 'd');
        var (start, length) = SelectionOf(h);
        Assert.Equal(0, start);
        Assert.Equal(15, h.Buffer.LineAndColumn(start + length - 1).Line);
        Assert.Equal(VimMode.Visual(linewise: false), h.Mode);
    }

    [Fact]
    public void ControlHMovesTheVisualCursor()
    {
        var h = AtLine(0);
        h.Keys("vll");
        Control(h, 'h');
        Assert.Equal((0, 2), SelectionOf(h));
    }

    [Fact]
    public void UnboundControlCharacterLeavesTheVisualSelection()
    {
        var h = AtLine(0);
        h.Keys("vl");
        var original = h.Text;
        Control(h, 'k');
        Assert.Equal(original, h.Text);
        Assert.Equal((0, 2), SelectionOf(h));
        Assert.Equal(VimMode.Visual(linewise: false), h.Mode);
    }

    [Fact]
    public void ControlHInInsertModeIsLeftToTheTextView()
    {
        // Insert mode Ctrl+H is the text view's backspace, which deletes a whole surrogate pair.
        var h = new VimHarness("a\U0001F600b\n", 3);
        h.Keys("i");
        Assert.False(Control(h, 'h'));
        Assert.Equal("a\U0001F600b\n", h.Text);
        Assert.Equal(VimMode.Insert, h.Mode);
    }

    [Fact]
    public void ControlHInReplaceModeRestoresLikeBackspace()
    {
        var h = new VimHarness("hello\n");
        h.Key('R', shift: true);
        h.Key('X', shift: true);
        h.Key('Y', shift: true);
        Control(h, 'h');
        Assert.Equal("Xello\n", h.Text);
        Assert.Equal(1, h.Pos);
    }

    [Fact]
    public void OptionTypedCharacterOverwritesInReplaceMode()
    {
        var h = new VimHarness("hello\n");
        h.Key('R', shift: true);
        h.Key('é');
        Assert.Equal("éello\n", h.Text);
    }

    [Fact]
    public void ControlHErasesInTheCommandLine()
    {
        var h = AtLine(0);
        h.Keys(":ab");
        Control(h, 'h');
        Assert.Equal(VimMode.CommandLine(":a"), h.Mode);
    }

    [Fact]
    public void ControlCharacterIsNotAppendedToTheCommandLine()
    {
        var h = AtLine(0);
        h.Keys(":");
        Control(h, 'd');
        Control(h, 'k');
        Assert.Equal(VimMode.CommandLine(":"), h.Mode);
    }
}
