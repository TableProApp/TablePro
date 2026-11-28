using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class SyncSettingsTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-sync-").FullName;

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    [Fact]
    public void ANewPcIsOffAndSyncsEveryCategoryPasswordsIncluded()
    {
        var sync = new AppSettings().Sync;

        Assert.Equal(SyncProvider.Off, sync.Provider);
        Assert.Empty(sync.Categories().OffKinds);
        Assert.True(sync.Categories().Passwords);
    }

    [Fact]
    public void PasswordsStartOnButAStoredChoiceIsKept()
    {
        var unset = Path.Combine(_directory, "unset.json");
        var off = Path.Combine(_directory, "off.json");
        File.WriteAllText(unset, """{ "sync": { "provider": "tableProSync" } }""");
        File.WriteAllText(off, """{ "sync": { "provider": "tableProSync", "passwords": false } }""");

        Assert.True(new SettingsStore(unset).Load().Sync.Passwords);
        Assert.False(new SettingsStore(off).Load().Sync.Passwords);
    }

    [Fact]
    public void PasswordsRideOnConnectionsSoTurningConnectionsOffTurnsThemOff()
    {
        var sync = new SyncSettings { Passwords = true };

        var off = sync.WithConnections(false);
        var on = off.WithConnections(true);

        Assert.True(sync.Categories().Passwords);
        Assert.False(off.Passwords);
        Assert.False(on.Passwords);
        Assert.False((sync with { Connections = false }).Normalized().Passwords);
    }

    [Fact]
    public void EachSwitchLeavesOutTheKindsItHolds()
    {
        var sync = new SyncSettings
        {
            GroupsAndTags = false,
            TableFavorites = false,
            DatabaseFavorites = false,
        };

        Assert.Equal(
            ["group", "tag", "favourite_table", "table_folder", "table_folder_item", "favourite_database"],
            sync.Categories().OffKinds);
    }

    [Fact]
    public void TheSyncSettingsComeBackAsSavedAndABlankSignInReadsAsNone()
    {
        var store = new SettingsStore(Path.Combine(_directory, "settings.json"));
        var saved = new AppSettings
        {
            Sync = new SyncSettings
            {
                Provider = SyncProvider.TableProSync,
                SavedQueries = false,
                Passwords = true,
                ServiceAccount = "https://api.tablepro.app/v2#account",
            },
        };

        store.Save(saved);
        var loaded = store.Load();
        store.Save(loaded with { Sync = loaded.Sync with { ServiceAccount = " " } });

        Assert.Equal(saved, loaded);
        Assert.Contains("\"tableProSync\"", File.ReadAllText(store.Path), StringComparison.OrdinalIgnoreCase);
        Assert.Null(store.Load().Sync.ServiceAccount);
    }
}
