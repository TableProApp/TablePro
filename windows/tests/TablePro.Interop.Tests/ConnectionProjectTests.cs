namespace TablePro.Interop.Tests;

public sealed class ConnectionProjectTests : IDisposable
{
    private static readonly DateTimeOffset At = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-projects-").FullName;
    private readonly TableProCore _core;

    public ConnectionProjectTests()
    {
        _core = TableProCore.Create(new HostConfiguration("test", _directory), new MemorySecretStore());
    }

    public void Dispose()
    {
        _core.Dispose();
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
            // The history database closes on the core's own threads, which can still hold it here on Windows.
        }
    }

    private static SavedConnection Network(string name, Guid? project = null, Guid? group = null) =>
        new(null, name, "postgres", "db.example.com", 5432, "shop", "app", TlsSettings.Disabled, GroupId: group)
        {
            ProjectId = project,
        };

    private async Task<Guid> SaveAsync(string name, Guid? project = null, Guid? group = null) =>
        (await _core.Library.SaveAsync(Network(name, project, group), ConnectionSecrets.None)).Id!.Value;

    private static string[] Names(LibrarySnapshot snapshot) =>
        [.. snapshot.Connections.Select(connection => connection.Name).Order(StringComparer.Ordinal)];

    [Fact]
    public async Task ProjectsAreMadeRenamedRecolouredReorderedAndDeleted()
    {
        var library = _core.Library;

        var acme = await library.CreateProjectAsync(" Acme ");
        var globex = await library.CreateProjectAsync("Globex", "red");
        var taken = await Assert.ThrowsAsync<TableProException>(() => library.CreateProjectAsync("ACME"));
        var empty = await Assert.ThrowsAsync<TableProException>(() => library.CreateProjectAsync("  "));
        var onto = await Assert.ThrowsAsync<TableProException>(() => library.RenameProjectAsync(globex.Id, "acme"));
        await library.RenameProjectAsync(acme.Id, "Acme Corp");
        await library.SetProjectColorAsync(acme.Id, "blue");
        await library.SetProjectColorAsync(globex.Id, null);
        await library.MoveProjectsAsync([globex.Id], acme.Id);
        var ordered = (await library.GetSnapshotAsync()).Projects;
        await library.DeleteProjectAsync(acme.Id);
        var left = (await library.GetSnapshotAsync()).Projects;
        var gone = await Assert.ThrowsAsync<TableProException>(() => library.RenameProjectAsync(acme.Id, "Again"));

        Assert.Equal(new ConnectionProject(acme.Id, "Acme", 0, null), acme);
        Assert.Equal(("Globex", 1, "red"), (globex.Name, globex.Order, globex.Color));
        Assert.Equal("storage.project_name_taken", taken.Code);
        Assert.Equal("project_name.empty", empty.Code);
        Assert.Equal("storage.project_name_taken", onto.Code);
        Assert.Equal(
            [new ConnectionProject(globex.Id, "Globex", 0, null), new ConnectionProject(acme.Id, "Acme Corp", 1, "blue")],
            ordered);
        Assert.Equal(globex.Id, Assert.Single(left).Id);
        Assert.Equal("storage.project_not_found", gone.Code);
    }

    [Fact]
    public async Task AScopedSnapshotShowsOneProjectAndAnUnknownOneShowsEverything()
    {
        var library = _core.Library;
        var acme = await library.CreateProjectAsync("Acme");
        var globex = await library.CreateProjectAsync("Globex");
        var production = await library.CreateGroupAsync("Production", null, acme.Id);
        var eu = await library.CreateGroupAsync("EU", production.Id);
        var sameName = await library.CreateGroupAsync("Production", null, globex.Id);
        var prod = await SaveAsync("prod", group: eu.Id);
        var loose = await SaveAsync("loose", acme.Id);
        var other = await SaveAsync("other", globex.Id);
        await SaveAsync("stray");
        await library.SetFavoriteAsync(prod, true);
        await library.SetFavoriteAsync(other, true);

        var whole = await library.GetSnapshotAsync();
        var inAcme = await library.GetSnapshotAsync(acme.Id);
        var inGlobex = await library.GetSnapshotAsync(globex.Id);
        var unknown = await library.GetSnapshotAsync(Guid.NewGuid());

        Assert.Equal(acme.Id, eu.ProjectId);
        Assert.Equal(globex.Id, sameName.ProjectId);
        Assert.Equal(["loose", "other", "prod", "stray"], Names(whole));
        Assert.Null(whole.Scope);
        Assert.Equal(acme.Id, whole.Connections.Single(connection => connection.Id == prod).ProjectId);
        Assert.Equal(acme.Id, whole.Connections.Single(connection => connection.Id == loose).ProjectId);
        Assert.Equal(["loose", "prod"], Names(inAcme));
        Assert.Equal(acme.Id, inAcme.Scope);
        Assert.Equal([prod], inAcme.Favorites);
        Assert.Equal(["Production", "EU"], inAcme.Groups.Select(group => group.Name));
        Assert.Equal([acme.Id, globex.Id], inAcme.Projects.Select(project => project.Id));
        Assert.Equal(["other"], Names(inGlobex));
        Assert.Equal(sameName.Id, Assert.Single(inGlobex.Groups).Id);
        Assert.Equal(Names(whole), Names(unknown));
        Assert.Null(unknown.Scope);
        Assert.Equal(Names(whole), Names(await library.GetSnapshotAsync(null)));
    }

    [Fact]
    public async Task ConnectionsAndTopLevelGroupsMoveBetweenProjects()
    {
        var library = _core.Library;
        var acme = await library.CreateProjectAsync("Acme");
        var globex = await library.CreateProjectAsync("Globex");
        var work = await library.CreateGroupAsync("Work", null);
        var nested = await library.CreateGroupAsync("Nested", work.Id);
        var grouped = await SaveAsync("grouped", group: nested.Id);
        var loose = await SaveAsync("loose");

        await library.MoveToProjectAsync([loose], acme.Id);
        await library.MoveGroupsToProjectAsync([work.Id], globex.Id);
        var refusedConnection = await Assert.ThrowsAsync<TableProException>(
            () => library.MoveToProjectAsync([grouped], acme.Id));
        var refusedGroup = await Assert.ThrowsAsync<TableProException>(
            () => library.MoveGroupsToProjectAsync([nested.Id], acme.Id));
        var moved = await library.GetSnapshotAsync();
        await library.MoveToProjectAsync([loose], null);
        await library.DeleteProjectAsync(globex.Id);
        var after = await library.GetSnapshotAsync();

        Assert.Equal("storage.connection_grouped", refusedConnection.Code);
        Assert.Equal("storage.group_not_top_level", refusedGroup.Code);
        Assert.Equal(acme.Id, moved.Connections.Single(connection => connection.Id == loose).ProjectId);
        Assert.Equal(globex.Id, moved.Connections.Single(connection => connection.Id == grouped).ProjectId);
        Assert.All(moved.Groups, group => Assert.Equal(globex.Id, group.ProjectId));
        Assert.All(after.Connections, connection => Assert.Null(connection.ProjectId));
        Assert.Equal(2, after.Connections.Count);
        Assert.Equal(2, after.Groups.Count);
    }

    [Fact]
    public async Task ANewConnectionLandsInItsProjectAndAnEditOrACopyKeepsIt()
    {
        var library = _core.Library;
        var acme = await library.CreateProjectAsync("Acme");
        var globex = await library.CreateProjectAsync("Globex");

        var created = await library.SaveAsync(Network("shop", acme.Id), ConnectionSecrets.None);
        var kept = await library.SaveAsync(created with { Name = "shop two", ProjectId = null }, ConnectionSecrets.None);
        var moved = await library.SaveAsync(kept with { ProjectId = globex.Id }, ConnectionSecrets.None);
        var copy = await library.DuplicateAsync(moved.Id!.Value, "shop copy");

        Assert.Equal(acme.Id, created.ProjectId);
        Assert.Equal(acme.Id, kept.ProjectId);
        Assert.Equal(globex.Id, moved.ProjectId);
        Assert.Equal(globex.Id, copy.ProjectId);
    }

    [Fact]
    public async Task AProjectsExportHoldsItsOwnAndAnImportLandsInTheProjectGiven()
    {
        var library = _core.Library;
        var acme = await library.CreateProjectAsync("Acme");
        await SaveAsync("inside", acme.Id);
        await SaveAsync("outside");
        var scoped = Path.Combine(_directory, "acme.json");
        var whole = Path.Combine(_directory, "all.json");

        var scopedCount = await library.ExportAsync(scoped, acme.Id);
        var wholeCount = await library.ExportAsync(whole);
        using var elsewhere = TableProCore.Create(
            new HostConfiguration("test", Path.Combine(_directory, "elsewhere")), new MemorySecretStore());
        var home = await elsewhere.Library.CreateProjectAsync("Home");
        await elsewhere.Library.ImportAsync(whole, home.Id);
        var landed = await elsewhere.Library.GetSnapshotAsync();

        Assert.Equal((1, 2), (scopedCount, wholeCount));
        var text = await File.ReadAllTextAsync(scoped, TestContext.Current.CancellationToken);
        Assert.Contains("inside", text, StringComparison.Ordinal);
        Assert.DoesNotContain("outside", text, StringComparison.Ordinal);
        string? ProjectOf(string name)
        {
            var id = landed.Connections.Single(connection => connection.Name == name).ProjectId;
            return landed.Projects.SingleOrDefault(project => project.Id == id)?.Name;
        }

        Assert.Equal("Acme", ProjectOf("inside"));
        Assert.Equal("Home", ProjectOf("outside"));
    }

    [Fact]
    public async Task RecentAndTheHistoryFollowTheProjectAndADeletedConnectionsRunsGoWithIt()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var library = _core.Library;
        var acme = await library.CreateProjectAsync("Acme");
        await using var first = await SqliteDatabase.CreateAsync();
        await using var second = await SqliteDatabase.CreateAsync();
        var inside = await library.SaveAsync(Sqlite("inside", first.Path) with { ProjectId = acme.Id }, ConnectionSecrets.None);
        var outside = await library.SaveAsync(Sqlite("outside", second.Path), ConnectionSecrets.None);
        await using var insideSession = await _core.ConnectAsync(inside.Id!.Value, cancellationToken: cancellationToken);
        await using var outsideSession = await _core.ConnectAsync(outside.Id!.Value, cancellationToken: cancellationToken);
        using var history = await _core.OpenHistoryAsync(cancellationToken);
        await history.RecordAsync(insideSession, Ran("SELECT 1", At), cancellationToken);
        await history.RecordAsync(outsideSession, Ran("SELECT 2", At.AddSeconds(1)), cancellationToken);

        async Task<string[]> SearchAsync(Guid? project) =>
            [.. (await history.SearchAsync(string.Empty, null, project, null, 50, cancellationToken)).Entries
                .Select(entry => entry.Sql)];

        var scopedRecent = (await library.GetSnapshotAsync(acme.Id)).Recent;
        var everyRecent = (await library.GetSnapshotAsync()).Recent;
        var scoped = await SearchAsync(acme.Id);
        var every = await SearchAsync(null);
        var unknown = await SearchAsync(Guid.NewGuid());
        var removed = await history.DeleteForConnectionAsync(inside.Id.Value, cancellationToken);
        var again = await history.DeleteForConnectionAsync(inside.Id.Value, cancellationToken);
        var after = await SearchAsync(null);

        Assert.Equal([inside.Id.Value], scopedRecent);
        Assert.Equal(2, everyRecent.Count);
        Assert.Equal(["SELECT 1"], scoped);
        Assert.Equal(["SELECT 2", "SELECT 1"], every);
        Assert.Equal(every, unknown);
        Assert.Equal((1L, 0L), (removed, again));
        Assert.Equal(["SELECT 2"], after);
    }

    private static SavedConnection Sqlite(string name, string path) =>
        new(null, name, "sqlite", string.Empty, 0, path, string.Empty, TlsSettings.Disabled);

    private static HistoryRun Ran(string sql, DateTimeOffset at) =>
        new(sql, at, TimeSpan.FromMilliseconds(12), 3, HistoryOutcome.Succeeded.Instance);
}
