using System.Text;
using TablePro.Storage.Library.Folders;

namespace TablePro.Storage.Tests.Library;

public sealed class LinkedFolderTests
{
    [Fact]
    public async Task LinkingTheSameFolderTwiceIsRefusedAndATurnedOffOneTurnsBackOn()
    {
        using var temp = new TempDirectory();
        var folder = Directory.CreateDirectory(temp.File("queries")).FullName;
        using var store = new LinkedSqlFolderStore(temp.Paths);
        await store.LoadAsync(TestContext.Current.CancellationToken);

        Assert.Equal(LinkFolderOutcome.Added, await store.AddAsync(folder, cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(LinkFolderOutcome.AlreadyLinked, await store.AddAsync(folder.ToUpperInvariant() + "\\", cancellationToken: TestContext.Current.CancellationToken));

        await store.SetEnabledAsync(store.Folders[0].Id, false, TestContext.Current.CancellationToken);
        Assert.Empty(store.VisibleTo(null));
        Assert.Equal(LinkFolderOutcome.ReEnabled, await store.AddAsync(folder, cancellationToken: TestContext.Current.CancellationToken));
        Assert.Single(store.VisibleTo(null));
    }

    [Fact]
    public async Task FoldersSurviveAReloadAndAFolderScopedToAConnectionShowsOnlyThere()
    {
        using var temp = new TempDirectory();
        var connection = Guid.NewGuid();
        using (var store = new LinkedSqlFolderStore(temp.Paths))
        {
            await store.AddAsync(Directory.CreateDirectory(temp.File("global")).FullName, cancellationToken: TestContext.Current.CancellationToken);
            await store.AddAsync(Directory.CreateDirectory(temp.File("scoped")).FullName, connection, TestContext.Current.CancellationToken);
        }

        using var reloaded = new LinkedSqlFolderStore(temp.Paths);
        await reloaded.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(2, reloaded.VisibleTo(connection).Count);
        Assert.Equal(["global"], reloaded.VisibleTo(Guid.NewGuid()).Select(f => f.Name));
        Assert.All(reloaded.Folders, f => Assert.True(f.IsEnabled));
    }

    [Fact]
    public async Task AFolderEntryWithoutIsEnabledLoadsEnabled()
    {
        using var temp = new TempDirectory();
        await File.WriteAllTextAsync(temp.File("linked_sql_folders.json"), """{ "folders": [ { "id": "6f1c1a52-2f63-4b49-9b0e-5d6f1d2b0f11", "path": "~/queries" } ] }""", TestContext.Current.CancellationToken);
        using var store = new LinkedSqlFolderStore(temp.Paths);
        await store.LoadAsync(TestContext.Current.CancellationToken);

        var folder = Assert.Single(store.Folders);
        Assert.True(folder.IsEnabled);
        Assert.Equal(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "queries"), folder.ExpandedPath);
    }

    [Fact]
    public void AScanListsSqlFilesWithTheirHeaderAndSkipsDotFoldersAndOtherFiles()
    {
        using var temp = new TempDirectory();
        var root = Directory.CreateDirectory(temp.File("q")).FullName;
        Directory.CreateDirectory(Path.Combine(root, "reports"));
        Directory.CreateDirectory(Path.Combine(root, ".git"));
        File.WriteAllText(Path.Combine(root, "reports", "monthly.sql"), "-- @name: Monthly revenue\n-- @keyword: rev\nSELECT 1;");
        File.WriteAllText(Path.Combine(root, "plain.PSQL"), "SELECT 2;");
        File.WriteAllText(Path.Combine(root, ".git", "x.sql"), "SELECT 3;");
        File.WriteAllText(Path.Combine(root, "notes.txt"), "not sql");
        var folder = new LinkedSqlFolder { Path = root };

        var scan = SqlFolderScanner.Scan(folder, TestContext.Current.CancellationToken);

        Assert.True(scan.Exists);
        Assert.Equal(["plain.PSQL", "reports/monthly.sql"], scan.Files.Select(f => f.RelativePath));
        var monthly = scan.Files[1];
        Assert.Equal("Monthly revenue", monthly.Name);
        Assert.Equal("rev", monthly.Keyword);
        Assert.Equal("reports", monthly.Directory);
        Assert.Equal("plain", scan.Files[0].Name);
        Assert.Equal(LinkedSqlFile.StableId(folder.Id, "reports/monthly.sql"), monthly.Id);
    }

    [Fact]
    public void AMissingFolderScansAsGone()
    {
        var scan = SqlFolderScanner.Scan(new LinkedSqlFolder { Path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N")) }, TestContext.Current.CancellationToken);
        Assert.False(scan.Exists);
        Assert.Empty(scan.Files);
    }

    [Fact]
    public void StableIdsMatchTheMacAppsDerivation()
    {
        // SHA-256 of "6F1C1A52-2F63-4B49-9B0E-5D6F1D2B0F11|a/b.sql", first 16 bytes, version 5 and RFC 4122 variant bits.
        var id = LinkedSqlFile.StableId(Guid.Parse("6f1c1a52-2f63-4b49-9b0e-5d6f1d2b0f11"), "a/b.sql");
        var text = id.ToString("D");
        Assert.Equal('5', text[14]);
        Assert.Contains(text[19], "89ab");
        Assert.Equal(id, LinkedSqlFile.StableId(Guid.Parse("6f1c1a52-2f63-4b49-9b0e-5d6f1d2b0f11"), "a/b.sql"));
        Assert.NotEqual(id, LinkedSqlFile.StableId(Guid.Parse("6f1c1a52-2f63-4b49-9b0e-5d6f1d2b0f11"), "a/c.sql"));
    }

    [Fact]
    public async Task NewFilesGetTheFirstFreeUntitledNameAndAreNeverOverwritten()
    {
        using var temp = new TempDirectory();
        var first = await SqlFileOperations.CreateAsync(temp.Path, cancellationToken: TestContext.Current.CancellationToken);
        var second = await SqlFileOperations.CreateAsync(temp.Path, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal("Untitled.sql", Path.GetFileName(first));
        Assert.Equal("Untitled 2.sql", Path.GetFileName(second));
        await Assert.ThrowsAsync<IOException>(() => SqlFileOperations.CreateAsync(temp.Path, "Untitled", cancellationToken: TestContext.Current.CancellationToken));
    }

    [Fact]
    public void RenamingAddsTheExtensionRefusesClashesAndBadNamesAndAllowsACaseChange()
    {
        using var temp = new TempDirectory();
        var path = temp.File("report.sql");
        File.WriteAllText(path, "SELECT 1;");
        File.WriteAllText(temp.File("taken.sql"), "SELECT 2;");

        Assert.Equal(SqlFileNameProblem.AlreadyExists, SqlFileOperations.Validate(temp.Path, "taken", path));
        Assert.Equal(SqlFileNameProblem.InvalidCharacters, SqlFileOperations.Validate(temp.Path, "a/b", path));
        Assert.Equal(SqlFileNameProblem.Reserved, SqlFileOperations.Validate(temp.Path, "con", path));
        Assert.Equal(SqlFileNameProblem.Empty, SqlFileOperations.Validate(temp.Path, " . ", path));

        var cased = SqlFileOperations.Rename(path, "Report");
        Assert.Equal("Report.sql", Path.GetFileName(cased));
        var renamed = SqlFileOperations.Rename(cased, "monthly.pgsql");
        Assert.Equal("monthly.pgsql", Path.GetFileName(renamed));
        Assert.Equal("SELECT 1;", File.ReadAllText(renamed));
    }

    [Fact]
    public async Task WritingMetadataKeepsTheFilesEncodingAndRefusesWhatItCannotHold()
    {
        using var temp = new TempDirectory();
        var utf16 = temp.File("wide.sql");
        await File.WriteAllBytesAsync(utf16, [.. Encoding.Unicode.GetPreamble(), .. Encoding.Unicode.GetBytes("SELECT 1;\r\n")], TestContext.Current.CancellationToken);
        await SqlFileOperations.WriteMetadataAsync(utf16, new SqlFileMetadata("Ünïcode"), TestContext.Current.CancellationToken);
        var bytes = await File.ReadAllBytesAsync(utf16, TestContext.Current.CancellationToken);
        Assert.Equal([0xFF, 0xFE], bytes[..2]);
        Assert.Equal("-- @name: Ünïcode\r\n\r\nSELECT 1;\r\n", Encoding.Unicode.GetString(bytes[2..]));

        var latin = temp.File("latin.sql");
        await File.WriteAllBytesAsync(latin, Encoding.Latin1.GetBytes("-- @name: caf\u00e9\nSELECT 1;"), TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<IOException>(() => SqlFileOperations.WriteMetadataAsync(latin, new SqlFileMetadata("日本"), TestContext.Current.CancellationToken));
        Assert.Equal("-- @name: caf\u00e9\nSELECT 1;", Encoding.Latin1.GetString(await File.ReadAllBytesAsync(latin, TestContext.Current.CancellationToken)));
    }

    [Fact]
    public void RepositoryBookkeepingAloneDoesNotTriggerARescan()
    {
        Assert.True(SqlFolderWatcher.TouchesOnlyRepositoryMetadata([@"C:\q\.git\index", @"C:\q\.git\refs\heads\main"]));
        Assert.False(SqlFolderWatcher.TouchesOnlyRepositoryMetadata([@"C:\q\.git\index", @"C:\q\a.sql"]));
        Assert.False(SqlFolderWatcher.TouchesOnlyRepositoryMetadata([]));
    }

    [Fact]
    public async Task TheWatcherRescansAfterAFileAppears()
    {
        using var temp = new TempDirectory();
        var root = Directory.CreateDirectory(temp.File("watched")).FullName;
        using var watcher = new SqlFolderWatcher(TimeSpan.FromMilliseconds(100));
        await watcher.WatchAsync([new LinkedSqlFolder { Path = root }], TestContext.Current.CancellationToken);
        Assert.Empty(watcher.Current.Single().Files);

        var scanned = new TaskCompletionSource();
        watcher.Scanned += (_, _) =>
        {
            if (watcher.Current.Single().Files.Count == 1)
            {
                scanned.TrySetResult();
            }
        };
        await File.WriteAllTextAsync(Path.Combine(root, "new.sql"), "SELECT 1;", TestContext.Current.CancellationToken);

        await scanned.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.Equal("new.sql", watcher.Current.Single().Files.Single().RelativePath);
    }

    [Fact]
    public void TextFilesDecodeByByteOrderMarkThenUtf8ThenLatin1()
    {
        Assert.Equal("é", SqlTextFile.Decode([0xC3, 0xA9]).Text);
        Assert.Equal("é", SqlTextFile.Decode([0xE9]).Text);
        Assert.Equal("iso-8859-1", SqlTextFile.Decode([0xE9]).EncodingName);
        var bom = SqlTextFile.Decode([0xEF, 0xBB, 0xBF, 0x41]);
        Assert.True(bom.HasByteOrderMark);
        Assert.Equal("A", bom.Text);
        Assert.Equal([0xEF, 0xBB, 0xBF, 0x42], SqlTextFile.Encode("B", bom.Encoding, bom.HasByteOrderMark));
    }
}
