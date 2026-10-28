using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>Command-line mode for :, / and ?: typing, editing, cancelling and dispatching what was typed.</summary>
public sealed class VimEngineCommandLineTests
{
    private readonly VimHarness _h = new("hello world\nsecond line\nthird line\n");
    private string? _dispatched;

    public VimEngineCommandLineTests() => _h.Engine.CommandEntered += (_, command) => _dispatched = command;

    private void Enter() => _h.Key('\r');

    private void Backspace() => _h.Key('\u007F');

    [Fact]
    public void ColonEntersCommandLineModeWithPrompt()
    {
        _h.Keys(":");
        Assert.Equal(VimMode.CommandLine(":"), _h.Mode);
    }

    [Fact]
    public void SlashEntersSearchModeWithPrompt()
    {
        _h.Keys("/");
        Assert.Equal(VimMode.CommandLine("/"), _h.Mode);
    }

    [Fact]
    public void QuestionMarkEntersReverseSearchMode()
    {
        _h.Keys("?");
        Assert.Equal(VimMode.CommandLine("?"), _h.Mode);
    }

    [Fact]
    public void CharactersAccumulateInBuffer()
    {
        _h.Keys(":wq");
        Assert.Equal(VimMode.CommandLine(":wq"), _h.Mode);
    }

    [Fact]
    public void WhitespaceAccumulatesInBuffer()
    {
        _h.Keys(":set ");
        Assert.Equal(VimMode.CommandLine(":set "), _h.Mode);
    }

    [Fact]
    public void SearchPatternAccumulates()
    {
        _h.Keys("/hello");
        Assert.Equal(VimMode.CommandLine("/hello"), _h.Mode);
    }

    [Fact]
    public void BackspaceRemovesLastChar()
    {
        _h.Keys(":wq");
        Backspace();
        Assert.Equal(VimMode.CommandLine(":w"), _h.Mode);
    }

    [Fact]
    public void BackspaceOnLonePromptExitsToNormal()
    {
        _h.Keys(":");
        Backspace();
        Assert.Equal(VimMode.Normal, _h.Mode);
    }

    [Fact]
    public void BackspaceOnSearchPromptExitsToNormal()
    {
        _h.Keys("/");
        Backspace();
        Assert.Equal(VimMode.Normal, _h.Mode);
    }

    [Fact]
    public void EscapeCancelsCommand()
    {
        _h.Keys(":wq");
        _h.Key('\u001B');
        Assert.Equal(VimMode.Normal, _h.Mode);
        Assert.Null(_dispatched);
    }

    [Fact]
    public void EnterDispatchesColonCommand()
    {
        _h.Keys(":w");
        Enter();
        Assert.Equal("w", _dispatched);
        Assert.Equal(VimMode.Normal, _h.Mode);
    }

    [Fact]
    public void EnterDispatchesMultiCharCommand()
    {
        _h.Keys(":write file.sql");
        Enter();
        Assert.Equal("write file.sql", _dispatched);
    }

    [Fact]
    public void SearchDoesNotDispatchToOnCommand()
    {
        // The engine runs searches itself; CommandEntered is only for Ex commands.
        _h.Keys("/hello");
        Enter();
        Assert.Null(_dispatched);
    }

    [Fact]
    public void EnterOnEmptyCommandDispatchesEmptyString()
    {
        // Enter on the bare prompt cancels, as in Vim.
        _h.Keys(":");
        Enter();
        Assert.Equal(VimMode.Normal, _h.Mode);
    }

    [Theory]
    [InlineData("w")]
    [InlineData("q")]
    [InlineData("wq")]
    [InlineData("x")]
    public void StandardCommandsDispatch(string command)
    {
        _h.Keys(":" + command);
        Enter();
        Assert.Equal(command, _dispatched);
    }

    [Fact]
    public void CanReEnterAfterDispatch()
    {
        _h.Keys(":w");
        Enter();
        Assert.Equal(VimMode.Normal, _h.Mode);
        _dispatched = null;
        _h.Keys(":q");
        Enter();
        Assert.Equal("q", _dispatched);
    }

    [Fact]
    public void DisplayLabelShowsBufferInCommandLineMode()
    {
        _h.Keys(":wq");
        Assert.Equal(":wq", _h.Mode.DisplayLabel);
    }
}
