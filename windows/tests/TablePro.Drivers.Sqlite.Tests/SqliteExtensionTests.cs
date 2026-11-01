using System.Diagnostics;
using Microsoft.Data.Sqlite;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;

namespace TablePro.Drivers.Sqlite.Tests;

public sealed class SqliteExtensionTests : IDisposable
{
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "tablepro-ext-" + Guid.NewGuid().ToString("N"));

    public SqliteExtensionTests()
    {
        Directory.CreateDirectory(_folder);
    }

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        try
        {
            Directory.Delete(_folder, recursive: true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    [Fact]
    public void TheListRoundTripsInTheMacFormatAndAnEmptyListIsNoValue()
    {
        var list = new[] { new LoadableExtension(@" C:\Tools\vec0.dll "), new LoadableExtension(@"C:\Tools\mod_spatialite.dll", " sqlite3_modspatialite_init ") };

        var encoded = LoadableExtensionList.Encode(list);

        Assert.Equal("""[{"path":"C:\\Tools\\vec0.dll"},{"entryPoint":"sqlite3_modspatialite_init","path":"C:\\Tools\\mod_spatialite.dll"}]""", encoded);
        Assert.Equal(list, LoadableExtensionList.Decode(encoded));
        Assert.Equal(string.Empty, LoadableExtensionList.Encode([]));
        Assert.Empty(LoadableExtensionList.Decode("  "));
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("{\"path\":\"x\"}")]
    [InlineData("[{\"entryPoint\":\"x\"}]")]
    [InlineData("[{\"path\":3}]")]
    public void AListThatDoesNotDecodeIsRefused(string value)
    {
        var error = Assert.Throws<LoadableExtensionException>(() => LoadableExtensionList.Decode(value));
        Assert.Equal(LoadableExtensionFailure.MalformedList, error.Failure);
    }

    [Fact]
    public void OnlySqliteAndALocalLibSqlFileDeclareAList()
    {
        var options = new Dictionary<string, string> { [LoadableExtensionList.OptionKey] = """[{"path":"C:\\x.dll"}]""" };

        Assert.Single(LoadableExtensionList.Declared(new ConnectionProfile { Name = "s", Engine = DatabaseEngine.Sqlite, AdditionalOptions = options }));
        Assert.Empty(LoadableExtensionList.Declared(new ConnectionProfile { Name = "r", Engine = DatabaseEngine.LibSql, Host = "libsql://db.turso.io", AdditionalOptions = options }));
        Assert.Single(LoadableExtensionList.Declared(new ConnectionProfile { Name = "f", Engine = DatabaseEngine.LibSql, Host = @"file:C:\data\app.db", AdditionalOptions = options }));
        Assert.Single(LoadableExtensionList.Declared(new ConnectionProfile { Name = "m", Engine = DatabaseEngine.Turso, AdditionalOptions = new Dictionary<string, string>(options) { ["libsqlMode"] = "local" } }));
        Assert.Empty(LoadableExtensionList.Declared(new ConnectionProfile { Name = "p", Engine = DatabaseEngine.PostgreSql, AdditionalOptions = options }));
    }

    [Theory]
    [InlineData("", null, LoadableExtensionFailure.MissingPath)]
    [InlineData("C:\\Tools\\a\nb.dll", null, LoadableExtensionFailure.ControlCharacterInPath)]
    [InlineData("C:\\Tools\\a\x2028b.dll", null, LoadableExtensionFailure.ControlCharacterInPath)]
    [InlineData("tools\\vec0.dll", null, LoadableExtensionFailure.RelativePath)]
    [InlineData("\\tools\\vec0.dll", null, LoadableExtensionFailure.RelativePath)]
    [InlineData("C:\\Tools\\vec0.dll", "1init", LoadableExtensionFailure.InvalidEntryPoint)]
    [InlineData("C:\\Tools\\vec0.dll", "init; DROP", LoadableExtensionFailure.InvalidEntryPoint)]
    public void PreflightRefusesWhatSqliteShouldNeverBeHanded(string path, string? entryPoint, LoadableExtensionFailure failure)
    {
        var error = Assert.Throws<LoadableExtensionException>(() => LoadableExtensionPreflight.Validate([new LoadableExtension(path, entryPoint)]));
        Assert.Equal(failure, error.Failure);
    }

    [Fact]
    public void TheSameFileListedTwiceUnderAnotherCaseIsADuplicate()
    {
        var error = Assert.Throws<LoadableExtensionException>(() => LoadableExtensionPreflight.Validate([new LoadableExtension(@"C:\Tools\vec0.dll"), new LoadableExtension(@"c:\tools\.\VEC0.dll")]));

        Assert.Equal(LoadableExtensionFailure.Duplicate, error.Failure);
        LoadableExtensionPreflight.Validate([new LoadableExtension(@"C:\Tools\vec0.dll"), new LoadableExtension(@"C:\Tools\vec0.dll", "sqlite3_vec_init")]);
    }

    [Fact]
    public void ATildeNamesTheUserProfileAsAMacListWritesIt()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        Assert.Equal(Path.Join(home, "lib/vec0.dll"), new LoadableExtension("~/lib/vec0.dll").ExpandedPath);
        LoadableExtensionPreflight.Validate([new LoadableExtension("~/lib/vec0.dll"), new LoadableExtension("%USERPROFILE%\\vec1.dll")]);
    }

    [Fact]
    public void TheConnectionStringLeavesTheListToTheSession()
    {
        var profile = Profile(Path.Combine(_folder, "a.db"), [new LoadableExtension(@"C:\Tools\vec0.dll")]);

        var connectionString = SqliteConnectionStringFactory.Build(ConnectionRequest.Direct(profile, null));

        Assert.DoesNotContain("sqliteExtensions", connectionString, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task AMissingFileFailsTheConnectWithTheFileNamed()
    {
        var missing = Path.Combine(_folder, "missing.dll");

        var error = await Assert.ThrowsAsync<LoadableExtensionException>(() => ConnectAsync([new LoadableExtension(missing)]));

        Assert.Equal(LoadableExtensionFailure.FileNotFound, error.Failure);
        Assert.Equal(missing, error.Extension!.Path);
        Assert.Contains("missing.dll", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AFolderIsNotAFile()
    {
        var error = await Assert.ThrowsAsync<LoadableExtensionException>(() => ConnectAsync([new LoadableExtension(_folder)]));

        Assert.Equal(LoadableExtensionFailure.NotAFile, error.Failure);
    }

    [Fact]
    public async Task AMalformedListFailsTheConnectBeforeAnythingOpens()
    {
        var profile = new ConnectionProfile
        {
            Name = "bad",
            Engine = DatabaseEngine.Sqlite,
            FilePath = Path.Combine(_folder, "never.db"),
            AdditionalOptions = new Dictionary<string, string> { [LoadableExtensionList.OptionKey] = "nope" },
        };

        var error = await Assert.ThrowsAsync<LoadableExtensionException>(() => new SqliteDriver().ConnectAsync(ConnectionRequest.Direct(profile, null), Ct));

        Assert.Equal(LoadableExtensionFailure.MalformedList, error.Failure);
        Assert.False(File.Exists(profile.FilePath));
    }

    [Fact]
    public async Task AFileThatIsNotALibraryIsReportedWithWindowsReason()
    {
        var fake = Path.Combine(_folder, "fake.dll");
        await File.WriteAllTextAsync(fake, "not a library", Ct);

        var error = await Assert.ThrowsAsync<LoadableExtensionException>(() => ConnectAsync([new LoadableExtension(fake)]));

        Assert.Equal(LoadableExtensionFailure.LibraryNotLoaded, error.Failure);
        Assert.True(error.IsWrongArchitecture);
        Assert.False(string.IsNullOrWhiteSpace(error.Detail));
    }

    [Fact]
    public async Task ALibraryWithoutTheEntryPointNamesTheMissingFunction()
    {
        // kernel32 is in every process already, so opening it runs nothing new; it has no SQLite entry point.
        var kernel32 = Path.Combine(Environment.SystemDirectory, "kernel32.dll");

        var error = await Assert.ThrowsAsync<LoadableExtensionException>(() => ConnectAsync([new LoadableExtension(kernel32, "sqlite3_tablepro_init")]));

        Assert.Equal(LoadableExtensionFailure.EntryPointNotFound, error.Failure);
        Assert.Equal("sqlite3_tablepro_init", error.Detail);
    }

    [Fact]
    public async Task ALibraryLoadsOncePerHandleAndTheSqlFunctionStaysRefused()
    {
        // No extension DLL ships with the tests, so the bundled SQLite library stands in: sqlite3_initialize takes no
        // arguments, ignores the three an entry point receives and returns SQLITE_OK, so it loads as an extension
        // that registers nothing.
        var sqlite = SqliteLibraryPath();
        var extensions = new[] { new LoadableExtension(sqlite, "sqlite3_initialize") };
        var path = Path.Combine(_folder, "loaded.db");
        await using var session = await new SqliteDriver().ConnectAsync(ConnectionRequest.Direct(Profile(path, extensions), null), Ct);
        await using var channel = await session.OpenChannelAsync(Ct);

        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(["SELECT 1", "SELECT load_extension('kernel32')"], new ExecuteOptions(), Ct))
        {
            results.Add(result);
        }

        Assert.Null(results[0].Error);
        Assert.Contains("not authorized", results[1].Error, StringComparison.OrdinalIgnoreCase);

        // The pool hands the same handle back; loading it again would run the entry point a second time.
        await session.PingAsync(Ct);
        await session.PingAsync(Ct);
    }

    [Fact]
    public void LoadingIntoAHandleThatHoldsTheLibrarySkipsIt()
    {
        var path = Path.Combine(_folder, "twice.db");
        using var connection = new SqliteConnection($"Data Source={path}");
        connection.Open();
        var extension = new LoadableExtension(SqliteLibraryPath(), "sqlite3_initialize");

        SqliteExtensionLoader.Load(connection, [extension]);

        // A second list naming the same file through another spelling finds it already held and loads nothing.
        SqliteExtensionLoader.Load(connection, [new LoadableExtension(extension.Path.ToUpperInvariant(), "sqlite3_initialize")]);
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1";
        Assert.Equal(1L, command.ExecuteScalar());
    }

    [Theory]
    [InlineData(@"C:\Tools\mod_spatialite.dll", "sqlite3_modspatialite_init")]
    [InlineData(@"C:\Tools\libvec0.so.1", "sqlite3_vec_init")]
    [InlineData(@"C:\Tools\Crypto-2.DLL", "sqlite3_crypto_init")]
    public void TheDefaultEntryPointFollowsSqlitesRule(string file, string entryPoint) =>
        Assert.Equal(entryPoint, SqliteExtensionLoader.DerivedEntryPoint(file));

    [Fact]
    public async Task WithoutANamedEntryPointTheDerivedOneIsReported()
    {
        var copy = Path.Combine(_folder, "kernel_copy.dll");
        File.Copy(Path.Combine(Environment.SystemDirectory, "version.dll"), copy);

        var error = await Assert.ThrowsAsync<LoadableExtensionException>(() => ConnectAsync([new LoadableExtension(copy)]));

        Assert.Equal(LoadableExtensionFailure.EntryPointNotFound, error.Failure);
        Assert.Equal("sqlite3_kernelcopy_init", error.Detail);
    }

    [Theory]
    [InlineData("no entry point [sqlite3_x_init] in shared library [C:\\x.dll]", LoadableExtensionFailure.EntryPointNotFound, "sqlite3_x_init")]
    [InlineData("error during initialization: out of memory", LoadableExtensionFailure.InitializationFailed, "out of memory")]
    [InlineData("The specified module could not be found.", LoadableExtensionFailure.LibraryNotLoaded, "The specified module could not be found.")]
    public void SqliteMessagesBecomeTheReasonTheUserCanActOn(string message, LoadableExtensionFailure failure, string detail)
    {
        var error = SqliteExtensionLoader.Diagnose(new LoadableExtension(@"C:\x.dll"), message);

        Assert.Equal(failure, error.Failure);
        Assert.Equal(detail, error.Detail);
    }

    private static ConnectionProfile Profile(string path, IReadOnlyList<LoadableExtension> extensions) => new()
    {
        Name = "ext",
        Engine = DatabaseEngine.Sqlite,
        FilePath = path,
        AdditionalOptions = new Dictionary<string, string> { [LoadableExtensionList.OptionKey] = LoadableExtensionList.Encode(extensions) },
    };

    private async Task ConnectAsync(IReadOnlyList<LoadableExtension> extensions)
    {
        var session = await new SqliteDriver().ConnectAsync(ConnectionRequest.Direct(Profile(Path.Combine(_folder, Guid.NewGuid().ToString("N") + ".db"), extensions), null), Ct);
        await session.DisposeAsync();
    }

    private static string SqliteLibraryPath()
    {
        // Opening a connection loads the provider's native library, whose path the process then knows.
        using (var connection = new SqliteConnection("Data Source=:memory:"))
        {
            connection.Open();
        }

        foreach (ProcessModule module in Process.GetCurrentProcess().Modules)
        {
            if (string.Equals(module.ModuleName, "e_sqlite3.dll", StringComparison.OrdinalIgnoreCase))
            {
                return module.FileName;
            }
        }

        throw new InvalidOperationException("The bundled SQLite library is not loaded.");
    }
}
