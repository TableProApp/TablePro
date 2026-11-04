namespace TablePro.App.Model.Tests;

public sealed class StoreTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-model-").FullName;

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    private string File(string name) => Path.Combine(_directory, name);

    [Fact]
    public void SettingsComeBackAsSaved()
    {
        var store = new SettingsStore(File("settings.json"));
        var saved = new AppSettings { Theme = AppTheme.Dark, ReopenSession = false, RowLimit = 500, QueryTimeoutSeconds = 30 };

        store.Save(saved);

        Assert.Equal(saved, store.Load());
    }

    [Fact]
    public void AMissingOrBrokenSettingsFileGivesTheDefaults()
    {
        var path = File("settings.json");
        var missing = new SettingsStore(path).Load();
        System.IO.File.WriteAllText(path, "{ not json");
        var broken = new SettingsStore(path).Load();

        Assert.Equal(new AppSettings(), missing);
        Assert.Equal(new AppSettings(), broken);
        Assert.True(missing.ReopenSession);
    }

    [Fact]
    public void AFileThatNamesSomeValuesKeepsTheDefaultsForTheRest()
    {
        var path = File("settings.json");
        System.IO.File.WriteAllText(path, """{ "theme": "Dark" }""");

        var settings = new SettingsStore(path).Load();

        Assert.Equal(new AppSettings { Theme = AppTheme.Dark }, settings);
    }

    [Fact]
    public void ValuesOutOfRangeAreBroughtBackIn()
    {
        var path = File("settings.json");
        System.IO.File.WriteAllText(
            path,
            """{ "theme": "Dark", "rowLimit": 0, "editorFontSize": 400, "queryTimeoutSeconds": -5, "pageSize": 1 }""");

        var settings = new SettingsStore(path).Load();

        Assert.Equal(AppTheme.Dark, settings.Theme);
        Assert.Equal(1, settings.RowLimit);
        Assert.Equal(36, settings.EditorFontSize);
        Assert.Equal(0, settings.QueryTimeoutSeconds);
        Assert.Equal(10, settings.PageSize);
    }

    [Fact]
    public void ANewTableTabPagesByAThousandRowsAsOnMacOS()
    {
        var settings = new SettingsStore(File("settings.json")).Load();

        Assert.Equal(1_000, settings.PageSize);
        Assert.Contains(settings.PageSize, AppSettings.PageSizeChoices);
    }

    [Fact]
    public void TheSessionKeepsItsConnectionsTabsAndFront()
    {
        var store = new SessionStore(File("session.json"));
        var id = Guid.NewGuid();
        var state = new SessionState
        {
            Connections =
            [
                new SessionConnection { FilePath = @"C:\data\app.sqlite", Name = "app", EngineId = "sqlite" },
                new SessionConnection
                {
                    ConnectionId = id,
                    Name = "shop",
                    EngineId = "postgres",
                    SelectedTab = 1,
                    Tabs =
                    [
                        new SessionTab { Kind = TabKind.Query, Title = "Query 1", Sql = "SELECT 1" },
                        new SessionTab
                        {
                            Kind = TabKind.Table,
                            Title = "orders",
                            Schema = "public",
                            Table = "orders",
                            PageSize = 100,
                            Offset = 200,
                        },
                    ],
                },
            ],
            Front = 1,
        };

        store.Save(state);
        var loaded = store.Load();

        Assert.Equal(1, loaded.Front);
        Assert.Equal(id, loaded.Connections[1].ConnectionId);
        Assert.Equal(1, loaded.Connections[1].SelectedTab);
        Assert.Equal("SELECT 1", loaded.Connections[1].Tabs[0].Sql);
        Assert.Equal(TabKind.Table, loaded.Connections[1].Tabs[1].Kind);
        Assert.Equal("orders", loaded.Connections[1].Tabs[1].Table);
        Assert.Equal(100, loaded.Connections[1].Tabs[1].PageSize);
        Assert.Equal(200, loaded.Connections[1].Tabs[1].Offset);
        Assert.Null(loaded.Connections[1].Tabs[0].PageSize);
    }

    [Fact]
    public void AWindowATabMovedIntoComesBackWithItsTabsAndPlace()
    {
        var store = new SessionStore(File("session.json"));
        var placement = new WindowPlacement { X = 200, Y = 120, Width = 1000, Height = 700 };
        var connection = new SessionConnection
        {
            ConnectionId = Guid.NewGuid(),
            Name = "shop",
            Tabs = [new SessionTab { Kind = TabKind.Table, Title = "orders", Table = "orders" }],
        };

        store.Save(new SessionState { TabWindows = [new TabWindowState { Connection = connection, Placement = placement }] });
        var window = Assert.Single(store.Load().TabWindows);

        Assert.Equal(placement, window.Placement);
        Assert.Equal(connection.ConnectionId, window.Connection.ConnectionId);
        Assert.Equal("orders", Assert.Single(window.Connection.Tabs).Table);
    }

    [Fact]
    public void AWindowWithNoTabOrNoConnectionToReopenIsDropped()
    {
        var tab = new SessionTab { Kind = TabKind.Query, Title = "Query 1" };
        var state = new SessionState
        {
            TabWindows =
            [
                new TabWindowState { Connection = new SessionConnection { Name = "lost", Tabs = [tab] } },
                new TabWindowState { Connection = new SessionConnection { FilePath = @"C:.db", Name = "a" } },
                new TabWindowState
                {
                    Connection = new SessionConnection { FilePath = @"C:.db", Name = "b", Tabs = [tab] },
                    Placement = new WindowPlacement(),
                },
            ],
        };

        var window = Assert.Single(state.Restorable().TabWindows);

        Assert.Equal("b", window.Connection.Name);
        Assert.Null(window.Placement);
    }

    [Fact]
    public void TheWindowPlacementAndThePaneWidthComeBackFromTheFile()
    {
        var store = new SessionStore(File("session.json"));
        var window = new WindowPlacement { X = -1800, Y = 40, Width = 1600, Height = 1000, Maximized = true };

        store.Save(new SessionState { Window = window, ObjectPaneWidth = 344 });
        var loaded = store.Load();

        Assert.Equal(window, loaded.Window);
        Assert.Equal(344, loaded.ObjectPaneWidth);
        Assert.Empty(loaded.Connections);
    }

    [Fact]
    public void AConnectionThatCannotBeReopenedIsDroppedAndTheFrontFollows()
    {
        var kept = new SessionConnection { FilePath = @"C:\a.db", Name = "a" };
        var state = new SessionState
        {
            Connections = [new SessionConnection { Name = "lost" }, kept],
            Front = 1,
        };

        var restorable = state.Restorable();

        Assert.Equal([kept], restorable.Connections);
        Assert.Equal(0, restorable.Front);
    }

    [Fact]
    public void ABrokenSessionFileIsAnEmptySession()
    {
        var path = File("session.json");
        System.IO.File.WriteAllText(path, "[]");

        var loaded = new SessionStore(path).Load();

        Assert.Empty(loaded.Connections);
        Assert.Equal(-1, loaded.Front);
    }
}
