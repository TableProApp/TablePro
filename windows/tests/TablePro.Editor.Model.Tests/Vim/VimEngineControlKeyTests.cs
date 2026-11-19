using System.Globalization;
using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineControlKeyTests
{
    private static readonly string Lines =
        string.Join("\n", Enumerable.Range(0, 30).Select(i => "line" + i.ToString(CultureInfo.InvariantCulture) + " text")) + "\n";

    private static bool Control(VimSession s, char letter) => s.Key(((char)(letter & 0x1F)).ToString());

    private static int Line(VimSession s) => s.Engine.Buffer.LineAndColumn(s.Caret).Line;

    private static void CaretAt(VimSession s, int line, int column = 0) => s.SetCaret(s.Engine.Buffer.Offset(line, column));

    [Fact]
    public void ControlRRedoesThroughTheEngine()
    {
        var s = new VimSession(Lines);
        s.Press("x");
        s.Press("u");
        Assert.True(Control(s, 'r'));
        Assert.Equal(Lines[1..], s.Text);
    }

    [Fact]
    public void ControlRTakesACount()
    {
        // Four undone edits and 3 Ctrl+R leave the last one undone, so exactly three were redone.
        var s = new VimSession(Lines);
        s.Press("xxxx");
        s.Press("4u");
        s.Press("3");
        Control(s, 'r');
        Assert.Equal(Lines[3..], s.Text);
    }

    [Fact]
    public void ControlHMovesLeftLikeH()
    {
        var s = new VimSession(Lines);
        CaretAt(s, 0, 5);
        var original = s.Text;
        Assert.True(Control(s, 'h'));
        Assert.Equal(4, s.Caret);
        Assert.True(s.Text == original, "Ctrl+H must move the caret in Normal mode, never delete");
    }

    [Fact]
    public void ControlHTakesACount()
    {
        var s = new VimSession(Lines);
        CaretAt(s, 0, 5);
        s.Press("3");
        Control(s, 'h');
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void ControlNAndControlPMoveBetweenLines()
    {
        var s = new VimSession(Lines);
        CaretAt(s, 4, 2);
        Control(s, 'n');
        Assert.Equal(5, Line(s));
        Control(s, 'p');
        Control(s, 'p');
        Assert.Equal(3, Line(s));
    }

    [Fact]
    public void ControlNCompletesAPendingOperatorLikeJ()
    {
        var s = new VimSession("one\ntwo\nthree\n");
        s.Press("d");
        Control(s, 'n');
        Assert.Equal("three\n", s.Text);
    }

    [Fact]
    public void ScrollControlCancelsAPendingOperator()
    {
        var s = new VimSession("one two three\n");
        s.Press("d");
        Control(s, 'd');
        s.Press("w");
        Assert.True(s.Text == "one two three\n", "Ctrl+D is no motion, so it abandons the pending d");
        Assert.Null(s.Engine.PendingOperator);
    }

    [Fact]
    public void ScrollControlUsesAndConsumesItsCount()
    {
        var s = new VimSession(Lines);
        CaretAt(s, 0);
        s.Press("4");
        Control(s, 'd');
        Assert.Equal(4, Line(s));
        s.Press("j");
        Assert.True(Line(s) == 5, "The count must not carry over to the next command");
    }

    [Fact]
    public void UnboundControlCharacterDoesNotEditInNormalMode()
    {
        var s = new VimSession(Lines);
        CaretAt(s, 0, 3);
        var original = s.Text;
        Assert.True(Control(s, 'k'));
        Assert.True(Control(s, 'o'));
        Assert.True(Control(s, 't'));
        Assert.Equal(original, s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void OptionTypedCharactersDoNotEditInNormalMode()
    {
        var s = new VimSession(Lines);
        CaretAt(s, 0, 3);
        var original = s.Text;
        Assert.True(s.Key("˙"));
        Assert.True(s.Key(" "));
        Assert.Equal(original, s.Text);
    }

    [Fact]
    public void ReplaceCharConsumesAControlCharacterWithoutWritingIt()
    {
        var s = new VimSession("hello\n");
        s.Press("r");
        Control(s, 'd');
        s.Press("x");
        Assert.True(s.Text == "ello\n", "r takes Ctrl+D as its argument, so the next x deletes");
    }

    [Fact]
    public void ControlDExtendsTheVisualSelection()
    {
        var s = new VimSession(Lines);
        CaretAt(s, 0);
        s.Press("v");
        Control(s, 'd');
        var (location, length) = s.Selection;
        Assert.Equal(0, location);
        Assert.True(
            s.Engine.Buffer.LineAndColumn(location + length - 1).Line == 15,
            "Ctrl+D moves the visual cursor half the visible lines down");
        Assert.Equal(VimMode.Visual, s.Mode);
    }

    [Fact]
    public void ControlHMovesTheVisualCursor()
    {
        var s = new VimSession(Lines);
        CaretAt(s, 0);
        s.Press("vll");
        Control(s, 'h');
        Assert.Equal((0, 2), s.Selection);
    }

    [Fact]
    public void UnboundControlCharacterLeavesTheVisualSelection()
    {
        var s = new VimSession(Lines);
        CaretAt(s, 0);
        s.Press("vl");
        var original = s.Text;
        Control(s, 'k');
        Assert.Equal(original, s.Text);
        Assert.Equal((0, 2), s.Selection);
        Assert.Equal(VimMode.Visual, s.Mode);
    }

    [Fact]
    public void ControlHInInsertModeIsLeftToTheTextView()
    {
        var s = new VimSession("a\U0001F600b\n", caret: 3);
        s.Press("i");
        Assert.False(Control(s, 'h'), "Insert mode Ctrl+H is the editor's delete backward, as Backspace is");
        Assert.Equal("a\U0001F600b\n", s.Text);
        Assert.Equal(VimMode.Insert, s.Mode);
    }

    [Fact]
    public void ControlHInReplaceModeRestoresLikeBackspace()
    {
        var s = new VimSession("hello\n");
        s.Key("R", shift: true);
        s.Key("X", shift: true);
        s.Key("Y", shift: true);
        Control(s, 'h');
        Assert.Equal("Xello\n", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void OptionTypedCharacterOverwritesInReplaceMode()
    {
        var s = new VimSession("hello\n");
        s.Key("R", shift: true);
        s.Key("é");
        Assert.Equal("éello\n", s.Text);
    }

    [Fact]
    public void ControlHErasesInTheCommandLine()
    {
        var s = new VimSession(Lines);
        s.Press(":ab");
        Control(s, 'h');
        Assert.Equal(VimMode.CommandLine, s.Mode);
        Assert.Equal(":a", s.Engine.CommandLine);
    }

    [Fact]
    public void ControlCharacterIsNotAppendedToTheCommandLine()
    {
        var s = new VimSession(Lines);
        s.Press(":");
        Control(s, 'd');
        Control(s, 'k');
        Assert.Equal(VimMode.CommandLine, s.Mode);
        Assert.Equal(":", s.Engine.CommandLine);
    }
}
