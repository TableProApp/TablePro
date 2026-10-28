using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

public sealed class VimKeyRouterTests
{
    private static readonly VimMode[] OutsideInsertModes = [VimMode.Normal, VimMode.Visual(false), VimMode.Visual(true), VimMode.CommandLine(":")];
    private static readonly VimMode[] EveryMode = [.. OutsideInsertModes, VimMode.Insert, VimMode.Replace];

    private static VimKeyRoute Route(VimKeystroke keystroke, VimMode mode) => VimKeyRouter.Route(keystroke, mode);

    private static VimKeystroke Char(char c, bool control = false, bool alt = false, bool shift = false) =>
        new(VimKeyKind.Character, c, control, alt, shift);

    [Fact]
    public void EscapeReachesTheEngineInEveryMode()
    {
        foreach (var mode in EveryMode)
        {
            Assert.Equal(VimKeyRoute.Engine('\u001B'), Route(new VimKeystroke(VimKeyKind.Escape), mode));
            Assert.Equal(VimKeyRoute.Engine('\u001B'), Route(Char('\u001B', control: true), mode));
        }
    }

    [Fact]
    public void PrintableKeysReachTheEngineInEveryMode()
    {
        foreach (var mode in EveryMode)
        {
            Assert.Equal(VimKeyRoute.Engine('d'), Route(Char('d'), mode));
            Assert.Equal(VimKeyRoute.Engine('$'), Route(Char('$', shift: true), mode));
        }
    }

    [Fact]
    public void AltGrCharactersReachTheEngine()
    {
        foreach (var mode in EveryMode)
        {
            Assert.Equal(VimKeyRoute.Engine('['), Route(Char('[', control: true, alt: true), mode));
        }
    }

    [Fact]
    public void DeadKeysTypeNothingOutsideInsertMode()
    {
        Assert.Equal(VimKeyRoute.Discard, Route(Char('\0'), VimMode.Normal));
        Assert.Equal(VimKeyRoute.Editor, Route(Char('\0'), VimMode.Insert));
    }

    [Fact]
    public void WindowsShortcutsStayWithTheEditorInEveryMode()
    {
        // Ctrl+C, V, Z, Y, S, F, H and Ctrl+/ as a keyboard layout types them.
        char[] shortcuts = ['\u0003', '\u0016', '\u001A', '\u0019', '\u0013', '\u0006', '\b', '/'];
        foreach (var mode in EveryMode)
        {
            foreach (var c in shortcuts)
            {
                Assert.Equal(VimKeyRoute.Editor, Route(Char(c, control: true), mode));
            }

            Assert.Equal(VimKeyRoute.Editor, Route(new VimKeystroke(VimKeyKind.Enter, '\n', Control: true), mode));
            Assert.Equal(VimKeyRoute.Editor, Route(new VimKeystroke(VimKeyKind.Other), mode));
        }
    }

    [Theory]
    [InlineData('\u0002')]
    [InlineData('\u0004')]
    [InlineData('\u0015')]
    [InlineData('\u000E')]
    [InlineData('\u0010')]
    public void ScrollAndLineChordsReachTheEngineInNormalAndVisual(char control)
    {
        Assert.Equal(VimKeyRoute.Engine(control), Route(Char(control, control: true), VimMode.Normal));
        Assert.Equal(VimKeyRoute.Engine(control), Route(Char(control, control: true), VimMode.Visual(false)));
        Assert.Equal(VimKeyRoute.Editor, Route(Char(control, control: true), VimMode.CommandLine(":")));
    }

    [Theory]
    [InlineData('\u0001')]
    [InlineData('\u0012')]
    [InlineData('\u0018')]
    public void IncrementRedoAndDecrementOnlyReplaceShortcutsInNormalMode(char control)
    {
        Assert.Equal(VimKeyRoute.Engine(control), Route(Char(control, control: true), VimMode.Normal));
        Assert.Equal(VimKeyRoute.Editor, Route(Char(control, control: true), VimMode.Visual(false)));
        Assert.Equal(VimKeyRoute.Editor, Route(Char(control, control: true), VimMode.Insert));
    }

    [Fact]
    public void ControlSpaceIsDiscardedOutsideInsertMode()
    {
        Assert.Equal(VimKeyRoute.Discard, Route(Char(' ', control: true), VimMode.Normal));
        Assert.Equal(VimKeyRoute.Editor, Route(Char(' ', control: true), VimMode.Insert));
    }

    [Theory]
    [InlineData('\u0017')]
    [InlineData('\u0015')]
    [InlineData('\u0014')]
    [InlineData('\u0004')]
    public void InsertControlsReachTheEngineInInsertModes(char control)
    {
        Assert.Equal(VimKeyRoute.Engine(control), Route(Char(control, control: true), VimMode.Insert));
        Assert.Equal(VimKeyRoute.Engine(control), Route(Char(control, control: true), VimMode.Replace));
    }

    [Fact]
    public void ArrowsAndDeleteAreMotionsOutsideInsertMode()
    {
        Assert.Equal(VimKeyRoute.Engine('h'), Route(new VimKeystroke(VimKeyKind.Left), VimMode.Normal));
        Assert.Equal(VimKeyRoute.Engine('l'), Route(new VimKeystroke(VimKeyKind.Right), VimMode.Visual(true)));
        Assert.Equal(VimKeyRoute.Engine('k'), Route(new VimKeystroke(VimKeyKind.Up), VimMode.Normal));
        Assert.Equal(VimKeyRoute.Engine('j'), Route(new VimKeystroke(VimKeyKind.Down), VimMode.Normal));
        Assert.Equal(VimKeyRoute.Engine('x'), Route(new VimKeystroke(VimKeyKind.Delete), VimMode.Normal));
        Assert.Equal(VimKeyRoute.Discard, Route(new VimKeystroke(VimKeyKind.Left), VimMode.CommandLine("/")));
        Assert.Equal(VimKeyRoute.Discard, Route(new VimKeystroke(VimKeyKind.Delete), VimMode.CommandLine("/")));
        Assert.Equal(VimKeyRoute.Editor, Route(new VimKeystroke(VimKeyKind.Left), VimMode.Insert));
        Assert.Equal(VimKeyRoute.Editor, Route(new VimKeystroke(VimKeyKind.Left, Control: true), VimMode.Normal));
    }

    [Fact]
    public void EnterTabAndBackspaceNeverEditOutsideInsertMode()
    {
        foreach (var mode in OutsideInsertModes)
        {
            Assert.Equal(VimKeyRoute.Engine('\r'), Route(new VimKeystroke(VimKeyKind.Enter), mode));
            Assert.Equal(VimKeyRoute.Engine('\b'), Route(new VimKeystroke(VimKeyKind.Backspace), mode));
            Assert.NotEqual(VimKeyRoute.Editor, Route(new VimKeystroke(VimKeyKind.Tab), mode));
        }
    }

    [Fact]
    public void InsertModeTypingGoesThroughTheEngineForMacros()
    {
        Assert.Equal(VimKeyRoute.Engine('\r'), Route(new VimKeystroke(VimKeyKind.Enter), VimMode.Insert));
        Assert.Equal(VimKeyRoute.Engine('\b'), Route(new VimKeystroke(VimKeyKind.Backspace), VimMode.Insert));
        Assert.Equal(VimKeyRoute.Engine('\t'), Route(new VimKeystroke(VimKeyKind.Tab), VimMode.Insert));
        Assert.Equal(VimKeyRoute.Editor, Route(new VimKeystroke(VimKeyKind.Tab, Shift: true), VimMode.Insert));
        Assert.Equal(VimKeyRoute.Editor, Route(new VimKeystroke(VimKeyKind.Tab), VimMode.Replace));
    }

    [Fact]
    public void AltChordsStayWithTheEditor()
    {
        foreach (var mode in EveryMode)
        {
            Assert.Equal(VimKeyRoute.Editor, Route(Char('f', alt: true), mode));
        }
    }

    [Fact]
    public void EngineDeclinesTypingInInsertModeSoTheEditorTypes()
    {
        var h = new VimHarness("ab\n");
        h.Keys("i");

        Assert.False(h.Key('x'));
        Assert.False(h.Key('\r'));
        Assert.False(h.Key('\b'));
        Assert.Equal("ab\n", h.Text);
    }
}
