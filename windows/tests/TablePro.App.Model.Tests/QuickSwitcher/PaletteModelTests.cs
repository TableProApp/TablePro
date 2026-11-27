using TablePro.App.Model.QuickSwitcher;

namespace TablePro.App.Model.Tests.QuickSwitcher;

public sealed class PaletteModelTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), "tablepro-palette-" + Guid.NewGuid().ToString("N") + ".json");

    public void Dispose()
    {
        if (File.Exists(_path))
        {
            File.Delete(_path);
        }
    }

    private PaletteModel NewModel(out Guid connection)
    {
        connection = Guid.NewGuid();
        return new PaletteModel(connection, new PaletteFrecencyStore(_path)) { Debounce = TimeSpan.Zero };
    }

    private static PaletteItem Item(string name, PaletteItemKind kind, string? action = null) => new()
    {
        FrecencyKey = name,
        Name = name,
        Kind = kind,
        Action = action,
    };

    [Fact]
    public async Task ScopeNarrowsTheRowsToItsKinds()
    {
        var model = NewModel(out _);
        model.SetItems([Item("people", PaletteItemKind.Table), Item("Run", PaletteItemKind.Command, "run")]);
        model.SetScope(PaletteScope.Commands);
        await model.FlushAsync();

        Assert.All(model.FlatItems, item => Assert.Equal(PaletteItemKind.Command, item.Kind));
        Assert.Contains(model.FlatItems, item => item.Name == "Run");
    }

    [Fact]
    public async Task AQueryRanksAndSelectsTheFirstRow()
    {
        var model = NewModel(out _);
        model.SetItems([Item("users", PaletteItemKind.Table), Item("user_roles", PaletteItemKind.Table)]);
        model.SetSearchText("users");
        await model.FlushAsync();

        Assert.NotEmpty(model.FlatItems);
        Assert.Equal(model.FlatItems[0].Id, model.SelectedId);
        Assert.Equal("users", model.SelectedItem()!.Name);
    }

    [Fact]
    public async Task MovingSelectionWalksTheRows()
    {
        var model = NewModel(out _);
        model.SetItems([Item("alpha", PaletteItemKind.Table), Item("alnum", PaletteItemKind.Table)]);
        model.SetSearchText("al");
        await model.FlushAsync();
        var first = model.SelectedId;

        model.MoveSelection(1);
        Assert.NotEqual(first, model.SelectedId);
        model.MoveSelection(-1);
        Assert.Equal(first, model.SelectedId);
        // Clamped at the ends.
        model.MoveSelection(-1);
        Assert.Equal(first, model.SelectedId);
    }

    [Fact]
    public async Task ARefilterTheUserDidNotAskForKeepsTheSelection()
    {
        var model = NewModel(out _);
        var items = new[] { Item("alpha", PaletteItemKind.Table), Item("alnum", PaletteItemKind.Table) };
        model.SetItems(items);
        model.SetSearchText("al");
        await model.FlushAsync();
        model.MoveSelection(1);
        var chosen = model.SelectedId;

        // The same query again (a source refresh) must not move the highlight.
        model.SetItems(items);
        await model.FlushAsync();
        Assert.Equal(chosen, model.SelectedId);
    }

    [Fact]
    public async Task ANewQueryMovesTheSelectionToTheBestMatch()
    {
        var model = NewModel(out _);
        model.SetItems([Item("alpha", PaletteItemKind.Table), Item("beta", PaletteItemKind.Table)]);
        model.SetSearchText("al");
        await model.FlushAsync();
        model.SetSearchText("beta");
        await model.FlushAsync();

        Assert.Equal("beta", model.SelectedItem()!.Name);
    }

    [Fact]
    public async Task RecordingASelectionFeedsTheRecentGroup()
    {
        var model = NewModel(out _);
        var orders = Item("orders", PaletteItemKind.Table);
        model.SetItems([Item("users", PaletteItemKind.Table), orders]);
        model.RecordSelection(orders);

        // A fresh model over the same store shows the recorded row under Recent for the empty query.
        model.SetItems([Item("users", PaletteItemKind.Table), orders]);
        await model.FlushAsync();
        Assert.Equal(PaletteGroupHeader.Recent, model.Groups[0].Header);
        Assert.Equal("orders", model.Groups[0].Items[0].Name);
    }
}
