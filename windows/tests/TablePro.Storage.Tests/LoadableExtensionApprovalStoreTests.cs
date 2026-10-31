using TablePro.Core.Connections;
using TablePro.Storage.Connections;

namespace TablePro.Storage.Tests;

public sealed class LoadableExtensionApprovalStoreTests
{
    private static readonly LoadableExtension Vec = new(@"C:\Tools\vec0.dll");
    private static readonly LoadableExtension Spatialite = new(@"C:\Tools\mod_spatialite.dll", "sqlite3_modspatialite_init");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task ApprovalIsPerConnectionAndSurvivesARestart()
    {
        using var temp = new TempDirectory();
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        using (var store = new LoadableExtensionApprovalStore(temp.Paths))
        {
            await store.ApproveAsync([Vec], first, Ct);
        }

        using var reopened = new LoadableExtensionApprovalStore(temp.Paths);

        Assert.Empty(reopened.Unapproved([Vec], first));
        Assert.Equal([Vec], reopened.Unapproved([Vec], second));
    }

    [Fact]
    public async Task AnApprovalNamesTheFileAndTheEntryPoint()
    {
        using var temp = new TempDirectory();
        using var store = new LoadableExtensionApprovalStore(temp.Paths);
        var id = Guid.NewGuid();

        await store.ApproveAsync([new LoadableExtension(@"c:\tools\MOD_SPATIALITE.dll", "sqlite3_modspatialite_init")], id, Ct);

        Assert.Empty(store.Unapproved([Spatialite], id));
        Assert.Single(store.Unapproved([new LoadableExtension(Spatialite.Path, "other_init")], id));
    }

    [Fact]
    public async Task PendingAsksAboutEveryUnapprovedEntryOfADeclaredList()
    {
        using var temp = new TempDirectory();
        using var store = new LoadableExtensionApprovalStore(temp.Paths);
        var profile = Profile(DatabaseEngine.Sqlite, [Vec, Spatialite]);
        await store.ApproveAsync([Vec], profile.Id, Ct);

        Assert.Equal([Spatialite], store.Pending(profile));
        Assert.Empty(store.Pending(profile with { Engine = DatabaseEngine.LibSql, Host = "libsql://db.turso.io" }));
        Assert.Equal([Spatialite], store.Pending(profile with { Engine = DatabaseEngine.LibSql, Host = @"file:C:\data\app.db" }));
    }

    [Fact]
    public void AListThatFailsValidationIsNotAskedAboutSinceTheConnectRefusesIt()
    {
        using var temp = new TempDirectory();
        using var store = new LoadableExtensionApprovalStore(temp.Paths);

        Assert.Empty(store.Pending(Profile(DatabaseEngine.Sqlite, [new LoadableExtension("C:\\Tools\\a\nb.dll")])));
        Assert.Empty(store.Pending(Profile(DatabaseEngine.Sqlite, [new LoadableExtension("relative.dll")])));
    }

    [Fact]
    public async Task RevokingForgetsTheConnectionAndAnUnreadableFileApprovesNothing()
    {
        using var temp = new TempDirectory();
        var id = Guid.NewGuid();
        using (var store = new LoadableExtensionApprovalStore(temp.Paths))
        {
            await store.ApproveAsync([Vec], id, Ct);
            await store.RevokeAsync([id], Ct);
            Assert.Single(store.Unapproved([Vec], id));
        }

        Assert.False(File.Exists(temp.File("loadable_extension_approvals.json")));
        await File.WriteAllTextAsync(temp.File("loadable_extension_approvals.json"), "{ broken", Ct);
        using var damaged = new LoadableExtensionApprovalStore(temp.Paths);
        Assert.Single(damaged.Unapproved([Vec], id));
    }

    private static ConnectionProfile Profile(DatabaseEngine engine, IReadOnlyList<LoadableExtension> extensions) => new()
    {
        Name = "ext",
        Engine = engine,
        FilePath = @"C:\data\app.db",
        AdditionalOptions = new Dictionary<string, string> { [LoadableExtensionList.OptionKey] = LoadableExtensionList.Encode(extensions) },
    };
}
