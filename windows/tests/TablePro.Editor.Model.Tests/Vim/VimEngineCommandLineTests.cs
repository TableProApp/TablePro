using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineCommandLineTests
{
    private const string Initial = "hello world\nsecond line\nthird line\n";

    private static void Enter(VimSession s) => s.Key("\r");

    [Fact]
    public void ColonEntersCommandLineModeWithPrompt()
    {
        var s = new VimSession(Initial);
        s.Press(":");
        Assert.Equal(VimMode.CommandLine, s.Mode);
        Assert.Equal(":", s.Engine.CommandLine);
    }

    [Fact]
    public void SlashEntersSearchModeWithPrompt()
    {
        var s = new VimSession(Initial);
        s.Press("/");
        Assert.Equal(VimMode.CommandLine, s.Mode);
        Assert.Equal("/", s.Engine.CommandLine);
    }

    [Fact]
    public void QuestionMarkEntersReverseSearchMode()
    {
        var s = new VimSession(Initial);
        s.Press("?");
        Assert.Equal(VimMode.CommandLine, s.Mode);
        Assert.Equal("?", s.Engine.CommandLine);
    }

    [Fact]
    public void CharactersAccumulateInBuffer()
    {
        var s = new VimSession(Initial);
        s.Press(":wq");
        Assert.Equal(VimMode.CommandLine, s.Mode);
        Assert.Equal(":wq", s.Engine.CommandLine);
    }

    [Fact]
    public void WhitespaceAccumulatesInBuffer()
    {
        var s = new VimSession(Initial);
        s.Press(":set ");
        Assert.Equal(VimMode.CommandLine, s.Mode);
        Assert.Equal(":set ", s.Engine.CommandLine);
    }

    [Fact]
    public void SearchPatternAccumulates()
    {
        var s = new VimSession(Initial);
        s.Press("/hello");
        Assert.Equal(VimMode.CommandLine, s.Mode);
        Assert.Equal("/hello", s.Engine.CommandLine);
    }

    [Fact]
    public void BackspaceRemovesLastChar()
    {
        var s = new VimSession(Initial);
        s.Press(":wq");
        s.Backspace();
        Assert.Equal(VimMode.CommandLine, s.Mode);
        Assert.Equal(":w", s.Engine.CommandLine);
    }

    [Fact]
    public void BackspaceOnLonePromptExitsToNormal()
    {
        var s = new VimSession(Initial);
        s.Press(":");
        s.Backspace();
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void BackspaceOnSearchPromptExitsToNormal()
    {
        var s = new VimSession(Initial);
        s.Press("/");
        s.Backspace();
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void EscapeCancelsCommand()
    {
        var s = new VimSession(Initial);
        s.Press(":wq");
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Empty(s.Commands);
    }

    [Fact]
    public void EnterDispatchesColonCommand()
    {
        var s = new VimSession(Initial);
        s.Press(":w");
        Enter(s);
        Assert.Equal(["w"], s.Commands);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void EnterDispatchesMultiCharCommand()
    {
        var s = new VimSession(Initial);
        s.Press(":write file.sql");
        Enter(s);
        Assert.Equal(["write file.sql"], s.Commands);
    }

    [Fact]
    public void SearchDoesNotDispatchToOnCommand()
    {
        var s = new VimSession(Initial);
        s.Press("/hello");
        Enter(s);
        Assert.Empty(s.Commands);
    }

    [Fact]
    public void EnterOnEmptyCommandDispatchesEmptyString()
    {
        var s = new VimSession(Initial);
        s.Press(":");
        Enter(s);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void CommandW()
    {
        var s = new VimSession(Initial);
        s.Press(":w");
        Enter(s);
        Assert.Equal(["w"], s.Commands);
    }

    [Fact]
    public void CommandQ()
    {
        var s = new VimSession(Initial);
        s.Press(":q");
        Enter(s);
        Assert.Equal(["q"], s.Commands);
    }

    [Fact]
    public void CommandWQ()
    {
        var s = new VimSession(Initial);
        s.Press(":wq");
        Enter(s);
        Assert.Equal(["wq"], s.Commands);
    }

    [Fact]
    public void CommandX()
    {
        var s = new VimSession(Initial);
        s.Press(":x");
        Enter(s);
        Assert.Equal(["x"], s.Commands);
    }

    [Fact]
    public void CanReEnterAfterDispatch()
    {
        var s = new VimSession(Initial);
        s.Press(":w");
        Enter(s);
        Assert.Equal(VimMode.Normal, s.Mode);
        s.Press(":q");
        Enter(s);
        Assert.Equal(["w", "q"], s.Commands);
    }

    [Fact]
    public void DisplayLabelShowsBufferInCommandLineMode()
    {
        var s = new VimSession(Initial);
        s.Press(":wq");
        Assert.Equal(":wq", s.Engine.ModeLabel);
    }

    [Fact]
    public void ASearchAfterAnOperatorIsItsMotion()
    {
        var s = new VimSession(Initial);
        s.Press("d/sec");
        Enter(s);
        Assert.Equal("second line\nthird line\n", s.Text);
        Assert.Equal("hello world\n", s.Engine.Register.Text);
        Assert.True(s.Engine.Register.IsLinewise);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void ABackwardSearchAfterAnOperatorDeletesBackToTheMatch()
    {
        var s = new VimSession(Initial, caret: 6);
        s.Press("d?ll");
        Enter(s);
        Assert.Equal("heworld\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void ASearchWithNoMatchAfterAnOperatorEndsTheCommand()
    {
        var s = new VimSession(Initial);
        s.Press("d/zzz");
        Enter(s);
        Assert.False(s.Engine.IsPending);
        s.Press("w");
        Assert.Equal(Initial, s.Text);
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void AnExCommandAfterAnOperatorRunsAndDropsTheOperator()
    {
        var s = new VimSession(Initial);
        s.Press("d:w");
        Enter(s);
        Assert.Equal(["w"], s.Commands);
        s.Press("w");
        Assert.Equal(Initial, s.Text);
        Assert.Equal(6, s.Caret);
    }
}
