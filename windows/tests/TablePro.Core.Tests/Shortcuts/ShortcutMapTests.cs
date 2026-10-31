using TablePro.Core.Shortcuts;

namespace TablePro.Core.Tests.Shortcuts;

public sealed class ShortcutMapTests
{
    private static readonly KeyChord CtrlShiftT = KeyChord.CtrlShift(ShortcutKey.T);

    private static ShortcutMap With(params (string Id, string Value)[] overrides) =>
        new(overrides.ToDictionary(o => o.Id, o => o.Value, StringComparer.Ordinal));

    [Fact]
    public void WithoutOverridesEveryCommandHasItsDefault()
    {
        var map = new ShortcutMap(null);
        foreach (var command in ShortcutCatalog.All)
        {
            Assert.Equal(command.DefaultChord, map.ChordFor(command));
            Assert.False(map.IsCustomized(command.Id));
        }

        Assert.Empty(map.Overrides);
    }

    [Fact]
    public void AnOverrideReplacesTheDefaultAndIsStoredAsText()
    {
        var map = ShortcutMap.Default.WithChord(ShortcutIds.NewTab, CtrlShiftT);
        Assert.Equal(CtrlShiftT, map.ChordFor(ShortcutIds.NewTab));
        Assert.Equal("Ctrl+Shift+T", map.TextFor(ShortcutIds.NewTab));
        Assert.True(map.IsCustomized(ShortcutIds.NewTab));
        Assert.Equal("Ctrl+Shift+T", map.Overrides[ShortcutIds.NewTab]);
        Assert.Empty(ShortcutMap.Default.Overrides);
    }

    [Fact]
    public void ClearingStoresAnEmptyValueAndLeavesTheCommandUnbound()
    {
        var map = ShortcutMap.Default.WithCleared(ShortcutIds.NewTab);
        Assert.True(map.ChordFor(ShortcutIds.NewTab).IsEmpty);
        Assert.Equal(string.Empty, map.TextFor(ShortcutIds.NewTab));
        Assert.Equal(ShortcutMap.ClearedValue, map.Overrides[ShortcutIds.NewTab]);
        Assert.True(map.IsCustomized(ShortcutIds.NewTab));
        Assert.Null(map.CommandFor(KeyChord.Ctrl(ShortcutKey.T), ShortcutContext.Global));
    }

    [Fact]
    public void ResetRemovesTheOverride()
    {
        var map = ShortcutMap.Default.WithChord(ShortcutIds.NewTab, CtrlShiftT).WithDefault(ShortcutIds.NewTab);
        Assert.False(map.IsCustomized(ShortcutIds.NewTab));
        Assert.Equal(KeyChord.Ctrl(ShortcutKey.T), map.ChordFor(ShortcutIds.NewTab));
        Assert.Same(ShortcutMap.Default, ShortcutMap.Default.WithDefault(ShortcutIds.NewTab));
    }

    [Fact]
    public void RecordingTheDefaultChordIsNotACustomization()
    {
        var map = ShortcutMap.Default.WithCleared(ShortcutIds.NewTab).WithChord(ShortcutIds.NewTab, KeyChord.Ctrl(ShortcutKey.T));
        Assert.False(map.IsCustomized(ShortcutIds.NewTab));
        Assert.Equal(KeyChord.Ctrl(ShortcutKey.T), map.ChordFor(ShortcutIds.NewTab));
    }

    [Fact]
    public void CommandForMatchesOnlyItsOwnContext()
    {
        var map = ShortcutMap.Default;
        Assert.Equal(ShortcutIds.ExecuteQuery, map.CommandFor(KeyChord.Ctrl(ShortcutKey.Enter), ShortcutContext.Editor)?.Id);
        Assert.Null(map.CommandFor(KeyChord.Ctrl(ShortcutKey.Enter), ShortcutContext.Global));
        Assert.Equal(ShortcutIds.NewTab, map.CommandFor(KeyChord.Ctrl(ShortcutKey.T), ShortcutContext.Global)?.Id);
        Assert.Null(map.CommandFor(KeyChord.None, ShortcutContext.Global));
    }

    [Fact]
    public void BindingsListEachBoundCommandOfAContextOnce()
    {
        var map = ShortcutMap.Default.WithCleared(ShortcutIds.CloseTab).WithChord(ShortcutIds.CloseAllTabs, KeyChord.CtrlShift(ShortcutKey.W));
        var global = map.Bindings(ShortcutContext.Global).ToList();
        Assert.DoesNotContain(global, b => b.Command.Id == ShortcutIds.CloseTab);
        Assert.Contains(global, b => b.Command.Id == ShortcutIds.CloseAllTabs && b.Chord == KeyChord.CtrlShift(ShortcutKey.W));
        Assert.DoesNotContain(global, b => b.Command.Id == ShortcutIds.CloseOtherTabs);
        Assert.All(global, b => Assert.Equal(ShortcutContext.Global, b.Command.Context));
        Assert.Equal(global.Count, global.Select(b => b.Chord).Distinct().Count());
        Assert.Equal(10, map.Bindings(ShortcutContext.Editor).Count());
    }

    [Fact]
    public void AChordTheUserAssignedStandsDownTheDefaultThatWouldFightIt()
    {
        var map = ShortcutMap.Default.WithChord(ShortcutIds.ManageConnections, KeyChord.Ctrl(ShortcutKey.T));
        Assert.Equal(KeyChord.Ctrl(ShortcutKey.T), map.ChordFor(ShortcutIds.ManageConnections));
        Assert.True(map.ChordFor(ShortcutIds.NewTab).IsEmpty);
        Assert.False(map.IsCustomized(ShortcutIds.NewTab));
        Assert.Equal(ShortcutIds.ManageConnections, map.CommandFor(KeyChord.Ctrl(ShortcutKey.T), ShortcutContext.Global)?.Id);

        // The other defaults are untouched, and releasing the chord re-arms the default on its own.
        Assert.Equal(KeyChord.Ctrl(ShortcutKey.W), map.ChordFor(ShortcutIds.CloseTab));
        Assert.Equal(KeyChord.Ctrl(ShortcutKey.T), map.WithDefault(ShortcutIds.ManageConnections).ChordFor(ShortcutIds.NewTab));
    }

    [Fact]
    public void AnOverrideStandsDownTheDefaultsOfEveryContextItCanMeet()
    {
        // F9 is the global sidebar toggle, so an editor override on it does stand it down: global overlaps the editor.
        var map = ShortcutMap.Default.WithChord(ShortcutIds.Find, new KeyChord(ShortcutKey.F9));
        Assert.True(map.ChordFor(ShortcutIds.ToggleTableBrowser).IsEmpty);

        // Two editor commands meet; the editor's Find default yields to Toggle Comment taking Ctrl+F.
        var editor = ShortcutMap.Default.WithChord(ShortcutIds.ToggleComment, KeyChord.Ctrl(ShortcutKey.F));
        Assert.True(editor.ChordFor(ShortcutIds.Find).IsEmpty);
        Assert.Equal(ShortcutIds.ToggleComment, editor.CommandFor(KeyChord.Ctrl(ShortcutKey.F), ShortcutContext.Editor)?.Id);
    }

    [Fact]
    public void FindConflictLooksOnlyAtOverlappingContexts()
    {
        var map = ShortcutMap.Default;
        var newTab = ShortcutCatalog.Get(ShortcutIds.NewTab);
        var find = ShortcutCatalog.Get(ShortcutIds.Find);
        Assert.Equal(ShortcutIds.CloseTab, map.FindConflict(KeyChord.Ctrl(ShortcutKey.W), newTab)?.Id);
        Assert.Equal(ShortcutIds.ExecuteQuery, map.FindConflict(KeyChord.Ctrl(ShortcutKey.Enter), newTab)?.Id);
        Assert.Equal(ShortcutIds.NewTab, map.FindConflict(KeyChord.Ctrl(ShortcutKey.T), find)?.Id);
        Assert.Null(map.FindConflict(KeyChord.Ctrl(ShortcutKey.T), newTab));
        Assert.Null(map.FindConflict(KeyChord.None, newTab));
    }

    [Fact]
    public void ReassignMovesTheChordAndClearsACustomizedLoser()
    {
        var newTab = ShortcutCatalog.Get(ShortcutIds.NewTab);
        var closeAll = ShortcutCatalog.Get(ShortcutIds.CloseAllTabs);
        var map = ShortcutMap.Default.WithChord(closeAll.Id, CtrlShiftT).Reassign(newTab, CtrlShiftT, closeAll);
        Assert.Equal(CtrlShiftT, map.ChordFor(newTab));
        Assert.True(map.ChordFor(closeAll).IsEmpty);
        Assert.Equal(ShortcutMap.ClearedValue, map.Overrides[closeAll.Id]);
    }

    [Fact]
    public void ReassignLetsADefaultLoserYieldWithoutMarkingItCustomized()
    {
        var newTab = ShortcutCatalog.Get(ShortcutIds.NewTab);
        var closeTab = ShortcutCatalog.Get(ShortcutIds.CloseTab);
        var map = ShortcutMap.Default.Reassign(newTab, KeyChord.Ctrl(ShortcutKey.W), closeTab);
        Assert.Equal(KeyChord.Ctrl(ShortcutKey.W), map.ChordFor(newTab));
        Assert.True(map.ChordFor(closeTab).IsEmpty);
        Assert.False(map.IsCustomized(closeTab.Id));
    }

    [Fact]
    public void UnreadableAndUnknownOverridesAreIgnoredButUnknownOnesAreKept()
    {
        var map = With((ShortcutIds.NewTab, "Ctrl+Banana"), ("future.unknown.command", "Ctrl+Shift+X"));
        Assert.Equal(KeyChord.Ctrl(ShortcutKey.T), map.ChordFor(ShortcutIds.NewTab));
        Assert.True(map.ChordFor("future.unknown.command").IsEmpty);

        var sanitized = map.Sanitized();
        Assert.False(sanitized.IsCustomized(ShortcutIds.NewTab));
        Assert.Equal("Ctrl+Shift+X", sanitized.Overrides["future.unknown.command"]);
    }

    [Fact]
    public void SanitizeDropsBareKeysButKeepsFunctionKeysAndClears()
    {
        var map = With((ShortcutIds.NewTab, "T"), (ShortcutIds.CloseTab, "F8"), (ShortcutIds.Find, ""), (ShortcutIds.QuickSwitcher, "Shift+O"));
        var sanitized = map.Sanitized();
        Assert.False(sanitized.IsCustomized(ShortcutIds.NewTab));
        Assert.False(sanitized.IsCustomized(ShortcutIds.QuickSwitcher));
        Assert.Equal(new KeyChord(ShortcutKey.F8), sanitized.ChordFor(ShortcutIds.CloseTab));
        Assert.True(sanitized.IsCustomized(ShortcutIds.Find));
        Assert.True(sanitized.ChordFor(ShortcutIds.Find).IsEmpty);
        Assert.Same(ShortcutMap.Default, ShortcutMap.Default.Sanitized());
    }

    [Fact]
    public void AHandEditedDuplicateGoesToTheFirstCommandInCatalogueOrder()
    {
        var map = With((ShortcutIds.NewTab, "Ctrl+Shift+K"), (ShortcutIds.CloseTab, "ctrl+shift+k"));
        Assert.Equal(ShortcutIds.NewTab, map.CommandFor(KeyChord.CtrlShift(ShortcutKey.K), ShortcutContext.Global)?.Id);
        Assert.Equal(ShortcutConflictKind.Command, ShortcutConflictResolver.Current(ShortcutCatalog.Get(ShortcutIds.CloseTab), map).Kind);
    }

    [Fact]
    public void HintAppendsTheResolvedChord()
    {
        Assert.Equal("New tab (Ctrl+T)", ShortcutMap.Default.Hint("New tab", ShortcutIds.NewTab));
        Assert.Equal("New tab (Ctrl+Shift+T)", ShortcutMap.Default.WithChord(ShortcutIds.NewTab, CtrlShiftT).Hint("New tab", ShortcutIds.NewTab));
        Assert.Equal("New tab", ShortcutMap.Default.WithCleared(ShortcutIds.NewTab).Hint("New tab", ShortcutIds.NewTab));
        Assert.Equal("Favorites", ShortcutMap.Default.Hint("Favorites", ShortcutIds.ShowFavoritesList));
    }

    [Fact]
    public void SearchMatchesTitlesAndChords()
    {
        var map = ShortcutMap.Default;
        var newTab = ShortcutCatalog.Get(ShortcutIds.NewTab);
        Assert.True(map.Matches(newTab, null));
        Assert.True(map.Matches(newTab, "  new "));
        Assert.True(map.Matches(newTab, "ctrl+t"));
        Assert.False(map.Matches(newTab, "history"));
    }
}
