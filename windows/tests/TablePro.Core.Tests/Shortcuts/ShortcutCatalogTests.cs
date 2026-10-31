using TablePro.Core.Shortcuts;

namespace TablePro.Core.Tests.Shortcuts;

/// <summary>Rules every default has to keep, so a new command cannot ship a chord that fights another or never fires.</summary>
public sealed class ShortcutCatalogTests
{
    [Fact]
    public void IdsAreUniqueAndFindable()
    {
        var ids = ShortcutCatalog.All.Select(c => c.Id).ToList();
        Assert.Equal(ids.Count, ids.Distinct(StringComparer.Ordinal).Count());
        foreach (var command in ShortcutCatalog.All)
        {
            Assert.Same(command, ShortcutCatalog.Find(command.Id));
        }

        Assert.Null(ShortcutCatalog.Find("future.unknown.command"));
        Assert.Throws<KeyNotFoundException>(() => ShortcutCatalog.Get("future.unknown.command"));
    }

    [Fact]
    public void NoTwoDefaultsCollideWithinOverlappingContexts()
    {
        var commands = ShortcutCatalog.All.Where(c => !c.DefaultChord.IsEmpty).ToArray();
        for (var i = 0; i < commands.Length; i++)
        {
            for (var j = i + 1; j < commands.Length; j++)
            {
                var (a, b) = (commands[i], commands[j]);
                Assert.False(
                    a.DefaultChord == b.DefaultChord && a.Context.Overlaps(b.Context),
                    $"{a.Id} and {b.Id} share {a.DefaultChord}");
            }
        }
    }

    [Fact]
    public void NoDefaultShadowsAReservedOrSystemKey()
    {
        foreach (var command in ShortcutCatalog.All.Where(c => !c.DefaultChord.IsEmpty))
        {
            Assert.False(ReservedShortcuts.IsSystemReserved(command.DefaultChord), $"{command.Id} default is reserved by Windows");
            Assert.Null(ReservedShortcuts.ConflictFor(command.DefaultChord, command.Context));
        }
    }

    [Fact]
    public void EveryDefaultIsAChordItsCommandAccepts()
    {
        foreach (var command in ShortcutCatalog.All.Where(c => !c.DefaultChord.IsEmpty))
        {
            Assert.True(command.Accepts(command.DefaultChord), $"{command.Id} ships {command.DefaultChord}, which it would refuse to record");
            Assert.Equal(ShortcutConflict.None, ShortcutConflictResolver.Current(command, ShortcutMap.Default));
        }
    }

    [Fact]
    public void EveryDefaultSurvivesAStoreAndReload()
    {
        foreach (var command in ShortcutCatalog.All.Where(c => !c.DefaultChord.IsEmpty))
        {
            Assert.Equal(command.DefaultChord, KeyChord.Parse(command.DefaultChord.ToString()));
        }
    }

    [Fact]
    public void TheEditorCommandsKeepTheKeysTheEditorHasAlwaysUsed()
    {
        Assert.Equal("Ctrl+Enter", Default(ShortcutIds.ExecuteQuery));
        Assert.Equal("F5", Default(ShortcutIds.ExecuteAllStatements));
        Assert.Equal("Ctrl+Shift+E", Default(ShortcutIds.ExplainQuery));
        Assert.Equal("Ctrl+Shift+F", Default(ShortcutIds.FormatQuery));
        Assert.Equal("Ctrl+S", Default(ShortcutIds.SaveFile));
        Assert.Equal("Ctrl+/", Default(ShortcutIds.ToggleComment));
        Assert.Equal("Ctrl+F", Default(ShortcutIds.Find));
        Assert.Equal("Ctrl+H", Default(ShortcutIds.FindAndReplace));
        Assert.Equal("F3", Default(ShortcutIds.FindNext));
        Assert.Equal("Shift+F3", Default(ShortcutIds.FindPrevious));
        Assert.All(ShortcutCatalog.InCategory(ShortcutCategory.Editor).Where(c => c.Id is not (ShortcutIds.RunSqlFile or ShortcutIds.ExportDatabase)),
            c => Assert.Equal(ShortcutContext.Editor, c.Context));
    }

    [Fact]
    public void TheWindowCommandsKeepTheKeysTheWindowHasAlwaysUsed()
    {
        Assert.Equal("Ctrl+T", Default(ShortcutIds.NewTab));
        Assert.Equal("Ctrl+W", Default(ShortcutIds.CloseTab));
        Assert.Equal("Ctrl+Tab", Default(ShortcutIds.ShowNextTab));
        Assert.Equal("Ctrl+Shift+Tab", Default(ShortcutIds.ShowPreviousTab));
        Assert.Equal("Ctrl+Shift+O", Default(ShortcutIds.QuickSwitcher));
        Assert.Equal("Ctrl+Alt+F", Default(ShortcutIds.SearchDatabase));
        Assert.Equal("Ctrl+P", Default(ShortcutIds.FocusSidebarSearch));
        Assert.Equal("F9", Default(ShortcutIds.ToggleTableBrowser));
        Assert.Equal("Ctrl+Shift+H", Default(ShortcutIds.ToggleHistory));
        Assert.Equal("Ctrl+Alt+A", Default(ShortcutIds.ToggleAssistant));
        Assert.Equal(string.Empty, Default(ShortcutIds.CloseAllTabs));
    }

    [Fact]
    public void CategoriesListOnlyTheirOwnCommandsInCatalogueOrder()
    {
        var navigation = ShortcutCatalog.InCategory(ShortcutCategory.Navigation).ToList();
        Assert.All(navigation, c => Assert.Equal(ShortcutCategory.Navigation, c.Category));
        Assert.Equal(ShortcutIds.NewTab, navigation[0].Id);
        Assert.Equal(ShortcutCatalog.All.Count, Enum.GetValues<ShortcutCategory>().Sum(c => ShortcutCatalog.InCategory(c).Count()));
        Assert.Equal("Editor & Query", ShortcutCategory.Editor.DisplayName());
    }

    [Fact]
    public void GlobalOverlapsEverythingButEditorAndGridDoNot()
    {
        Assert.True(ShortcutContext.Global.Overlaps(ShortcutContext.Editor));
        Assert.True(ShortcutContext.DataGrid.Overlaps(ShortcutContext.Global));
        Assert.True(ShortcutContext.Editor.Overlaps(ShortcutContext.Editor));
        Assert.False(ShortcutContext.Editor.Overlaps(ShortcutContext.DataGrid));
    }

    private static string Default(string id) => ShortcutCatalog.Get(id).DefaultChord.ToString();
}
