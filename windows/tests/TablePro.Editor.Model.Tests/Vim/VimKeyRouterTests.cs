using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

// Ctrl is the Windows shortcut key and Alt the menus', so Vim takes only the chords it defines.
public sealed class VimKeyRouterTests
{
    private static VimRoute Route(VimKeyDown key, VimMode mode, bool pending = false) =>
        VimKeyRouter.Route(key, mode, pending);

    private static VimKeyDown Chord(char letter) => new(VimKey.Letter, letter, Control: true);

    [Theory]
    [InlineData(VimKey.Left, "h")]
    [InlineData(VimKey.Right, "l")]
    [InlineData(VimKey.Up, "k")]
    [InlineData(VimKey.Down, "j")]
    [InlineData(VimKey.Home, "0")]
    [InlineData(VimKey.End, "$")]
    [InlineData(VimKey.PageUp, "\u0002")]
    [InlineData(VimKey.PageDown, "\u0006")]
    [InlineData(VimKey.Delete, "x")]
    [InlineData(VimKey.Backspace, "\b")]
    [InlineData(VimKey.Enter, "\r")]
    public void NormalModeKeysAreVimMotions(VimKey key, string expected)
    {
        Assert.Equal(VimRoute.Engine(expected), Route(new VimKeyDown(key), VimMode.Normal));
        Assert.Equal(VimRoute.Engine(expected), Route(new VimKeyDown(key), VimMode.VisualLine));
    }

    [Theory]
    [InlineData('A')]
    [InlineData('B')]
    [InlineData('D')]
    [InlineData('E')]
    [InlineData('F')]
    [InlineData('H')]
    [InlineData('N')]
    [InlineData('P')]
    [InlineData('R')]
    [InlineData('U')]
    [InlineData('X')]
    [InlineData('Y')]
    public void VimTakesTheChordsItDefinesInNormalMode(char letter)
    {
        Assert.Equal(VimRoute.Engine(((char)(letter - 'A' + 1)).ToString()), Route(Chord(letter), VimMode.Normal));
    }

    [Theory]
    [InlineData('C')]
    [InlineData('V')]
    [InlineData('Z')]
    [InlineData('S')]
    [InlineData('W')]
    [InlineData('T')]
    public void OtherChordsStayWithTheEditorAndTheApp(char letter)
    {
        Assert.Equal(VimRoute.Editor, Route(Chord(letter), VimMode.Normal));
    }

    [Fact]
    public void ShiftedAndAltChordsStayWithTheEditor()
    {
        Assert.Equal(VimRoute.Editor, Route(new VimKeyDown(VimKey.Letter, 'D', Control: true, Shift: true), VimMode.Normal));
        Assert.Equal(VimRoute.Editor, Route(new VimKeyDown(VimKey.Letter, 'D', Control: true, Alt: true), VimMode.Normal));
        Assert.Equal(VimRoute.Editor, Route(new VimKeyDown(VimKey.Letter, 'F', Alt: true), VimMode.Normal));
    }

    [Theory]
    [InlineData('W', "\u0017")]
    [InlineData('U', "\u0015")]
    [InlineData('T', "\u0014")]
    [InlineData('D', "\u0004")]
    public void InsertModeTakesItsOwnChords(char letter, string expected)
    {
        Assert.Equal(VimRoute.Engine(expected), Route(Chord(letter), VimMode.Insert));
        Assert.Equal(VimRoute.Engine(expected), Route(Chord(letter), VimMode.Replace));
    }

    [Theory]
    [InlineData('A')]
    [InlineData('C')]
    [InlineData('V')]
    [InlineData('Z')]
    [InlineData('R')]
    public void InsertModeLeavesShortcutsToTheEditor(char letter)
    {
        Assert.Equal(VimRoute.Editor, Route(Chord(letter), VimMode.Insert));
    }

    [Theory]
    [InlineData(VimMode.Normal)]
    [InlineData(VimMode.Insert)]
    [InlineData(VimMode.Visual)]
    [InlineData(VimMode.CommandLine)]
    public void ControlBracketIsEscape(VimMode mode)
    {
        Assert.Equal(VimRoute.Engine(VimEngine.Escape), Route(new VimKeyDown(VimKey.OpenBracket, Control: true), mode));
    }

    [Fact]
    public void EscapeWithNothingPendingInNormalModeIsTheEditors()
    {
        var escape = new VimKeyDown(VimKey.Escape);
        Assert.Equal(VimRoute.Editor, Route(escape, VimMode.Normal));
        Assert.Equal(VimRoute.Engine(VimEngine.Escape), Route(escape, VimMode.Normal, pending: true));
        Assert.Equal(VimRoute.Engine(VimEngine.Escape), Route(escape, VimMode.Insert));
        Assert.Equal(VimRoute.Engine(VimEngine.Escape), Route(escape, VimMode.Visual));
    }

    [Theory]
    [InlineData(VimKey.Left)]
    [InlineData(VimKey.Delete)]
    [InlineData(VimKey.Home)]
    [InlineData(VimKey.Up)]
    public void InsertModeKeepsTheEditorsMovementKeys(VimKey key)
    {
        Assert.Equal(VimRoute.Editor, Route(new VimKeyDown(key), VimMode.Insert));
    }

    [Fact]
    public void InsertModeShowsVimTheKeysAMacroReplays()
    {
        Assert.Equal(VimRoute.Engine("\r"), Route(new VimKeyDown(VimKey.Enter), VimMode.Insert));
        Assert.Equal(VimRoute.Engine("\b"), Route(new VimKeyDown(VimKey.Backspace), VimMode.Insert));
        Assert.Equal(VimRoute.Engine("\t"), Route(new VimKeyDown(VimKey.Tab), VimMode.Insert));
        Assert.Equal(VimRoute.Editor, Route(new VimKeyDown(VimKey.Tab, Shift: true), VimMode.Insert));
    }

    [Fact]
    public void TheCommandLineTakesEnterAndBackspaceAndDropsMovement()
    {
        Assert.Equal(VimRoute.Engine("\r"), Route(new VimKeyDown(VimKey.Enter), VimMode.CommandLine));
        Assert.Equal(VimRoute.Engine("\b"), Route(new VimKeyDown(VimKey.Backspace), VimMode.CommandLine));
        Assert.Equal(VimRoute.Discard, Route(new VimKeyDown(VimKey.Left), VimMode.CommandLine));
        Assert.Equal(VimRoute.Discard, Route(Chord('V'), VimMode.CommandLine));
        Assert.Equal(VimRoute.Engine("\b"), Route(Chord('H'), VimMode.CommandLine));
        Assert.Equal(VimRoute.Editor, Route(new VimKeyDown(VimKey.Letter, 'W'), VimMode.CommandLine));
    }

    [Fact]
    public void TabInNormalModeTypesNothing()
    {
        Assert.Equal(VimRoute.Discard, Route(new VimKeyDown(VimKey.Tab), VimMode.Normal));
    }

    [Fact]
    public void ControlEnterStaysWithTheApp()
    {
        Assert.Equal(VimRoute.Editor, Route(new VimKeyDown(VimKey.Enter, Control: true), VimMode.Normal));
        Assert.Equal(VimRoute.Editor, Route(new VimKeyDown(VimKey.Enter, Control: true), VimMode.Insert));
    }
}
