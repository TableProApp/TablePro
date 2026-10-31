using TablePro.Core.Shortcuts;

namespace TablePro.Core.Tests.Shortcuts;

public sealed class ShortcutConflictResolverTests
{
    private static readonly ShortcutCommand NewTab = ShortcutCatalog.Get(ShortcutIds.NewTab);
    private static readonly ShortcutCommand Find = ShortcutCatalog.Get(ShortcutIds.Find);

    private static ShortcutConflict Resolve(KeyChord chord, ShortcutCommand command) =>
        ShortcutConflictResolver.Resolve(chord, command, ShortcutMap.Default);

    [Fact]
    public void AFreeChordHasNoConflict()
    {
        Assert.Equal(ShortcutConflict.None, Resolve(KeyChord.CtrlShift(ShortcutKey.K), NewTab));
        Assert.Equal(ShortcutConflict.None, Resolve(KeyChord.None, NewTab));
        Assert.False(ShortcutConflict.None.IsBlocking);
    }

    [Theory]
    [InlineData("Alt+F4")]
    [InlineData("Alt+Tab")]
    [InlineData("Ctrl+Esc")]
    [InlineData("Ctrl+Shift+Esc")]
    [InlineData("Alt+Space")]
    [InlineData("Win+E")]
    [InlineData("Win+Ctrl+D")]
    [InlineData("Shift+F10")]
    public void WindowsKeysAreSystemReserved(string text)
    {
        var conflict = Resolve(KeyChord.Parse(text), NewTab);
        Assert.Equal(ShortcutConflictKind.SystemReserved, conflict.Kind);
        Assert.True(conflict.IsBlocking);
        Assert.Contains("reserved by Windows", conflict.Describe(KeyChord.Parse(text)), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("T")]
    [InlineData("Shift+T")]
    [InlineData("Enter")]
    [InlineData("Shift+Delete")]
    public void AChordWithoutCtrlAltOrAFunctionKeyNeedsAModifier(string text) =>
        Assert.Equal(ShortcutConflictKind.NeedsModifier, Resolve(KeyChord.Parse(text), NewTab).Kind);

    [Fact]
    public void FunctionKeysNeedNoModifier()
    {
        Assert.Equal(ShortcutConflict.None, Resolve(new KeyChord(ShortcutKey.F7), NewTab));
        Assert.Equal(ShortcutConflict.None, Resolve(KeyChord.Shift(ShortcutKey.F7), NewTab));
    }

    [Fact]
    public void TabSelectionIsReservedInEveryContext()
    {
        var conflict = Resolve(KeyChord.Ctrl(ShortcutKey.D5), Find);
        Assert.Equal(ShortcutConflictKind.Reserved, conflict.Kind);
        Assert.Equal("Select Tab 5", conflict.Name);
        Assert.Equal("Ctrl+5 is reserved for \"Select Tab 5\" and cannot be assigned.", conflict.Describe(KeyChord.Ctrl(ShortcutKey.D5)));
        Assert.Equal("Select Tab 5", ReservedShortcuts.ConflictFor(KeyChord.Ctrl(ShortcutKey.D5), ShortcutContext.DataGrid));
    }

    [Fact]
    public void EditorBuiltInsAndTextEditingKeysBlockEditorAndGlobalCommandsOnly()
    {
        Assert.Equal("Show Completions", Resolve(KeyChord.Ctrl(ShortcutKey.Space), Find).Name);
        Assert.Equal("Copy", Resolve(KeyChord.Ctrl(ShortcutKey.C), NewTab).Name);
        Assert.Equal("Move Word Left", Resolve(KeyChord.Ctrl(ShortcutKey.Left), NewTab).Name);
        Assert.Null(ReservedShortcuts.ConflictFor(KeyChord.Ctrl(ShortcutKey.Space), ShortcutContext.DataGrid));
    }

    [Fact]
    public void GridKeysBlockGlobalCommandsButNotEditorCommands()
    {
        Assert.Equal("Refresh", Resolve(KeyChord.Ctrl(ShortcutKey.R), NewTab).Name);
        Assert.Equal(ShortcutConflict.None, Resolve(KeyChord.Ctrl(ShortcutKey.R), Find));
        Assert.Equal("Add Row", ReservedShortcuts.ConflictFor(KeyChord.Ctrl(ShortcutKey.I), ShortcutContext.DataGrid));
    }

    [Fact]
    public void AnotherCommandsChordCanBeReassigned()
    {
        var conflict = Resolve(KeyChord.Ctrl(ShortcutKey.W), NewTab);
        Assert.Equal(ShortcutConflictKind.Command, conflict.Kind);
        Assert.Equal(ShortcutIds.CloseTab, conflict.Command?.Id);
        Assert.False(conflict.IsBlocking);
        Assert.Equal("Ctrl+W is already used by \"Close Tab\" in Navigation.", conflict.Describe(KeyChord.Ctrl(ShortcutKey.W)));
    }

    [Fact]
    public void AGlobalChordConflictsWithAnEditorCommandAndTheOtherWayRound()
    {
        Assert.Equal(ShortcutIds.Find, Resolve(KeyChord.Ctrl(ShortcutKey.F), NewTab).Command?.Id);
        Assert.Equal(ShortcutIds.NewTab, Resolve(KeyChord.Ctrl(ShortcutKey.T), Find).Command?.Id);
    }

    [Fact]
    public void ACommandsOwnChordIsNoConflict() =>
        Assert.Equal(ShortcutConflict.None, Resolve(KeyChord.Ctrl(ShortcutKey.T), NewTab));

    [Fact]
    public void CurrentReportsAChordThatCanNeverWin()
    {
        var map = new ShortcutMap(new Dictionary<string, string> { [ShortcutIds.NewTab] = "Ctrl+C" });
        var conflict = ShortcutConflictResolver.Current(NewTab, map);
        Assert.Equal(ShortcutConflictKind.Reserved, conflict.Kind);
        Assert.Equal("Copy", conflict.Name);
        Assert.Equal(ShortcutConflict.None, ShortcutConflictResolver.Current(ShortcutCatalog.Get(ShortcutIds.CloseTab), map));
    }
}
