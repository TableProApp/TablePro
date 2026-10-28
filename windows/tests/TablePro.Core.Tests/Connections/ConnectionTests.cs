using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Connections;

public sealed class ConnectionTests
{
    [Theory]
    [InlineData(SslMode.Preferred, 0, 8123)]
    [InlineData(SslMode.Required, 0, 8443)]
    [InlineData(SslMode.VerifyIdentity, 0, 8443)]
    [InlineData(SslMode.Required, 9440, 9440)]
    public void ClickHouseDefaultsToItsTlsPortWhenTlsIsRequired(SslMode ssl, int port, int expected)
    {
        var profile = new ConnectionProfile { Name = "ch", Engine = DatabaseEngine.ClickHouse, SslMode = ssl, Port = port };

        Assert.Equal(expected, profile.EffectivePort);
    }

    [Theory]
    [InlineData(DatabaseEngine.PostgreSql, "PostgreSQL", 5432, false, true, "postgres")]
    [InlineData(DatabaseEngine.MySql, "MySQL", 3306, false, false, "root")]
    [InlineData(DatabaseEngine.MariaDb, "MariaDB", 3306, false, false, "root")]
    [InlineData(DatabaseEngine.SqlServer, "SQL Server", 1433, false, true, "sa")]
    [InlineData(DatabaseEngine.Sqlite, "SQLite", 0, true, false, "")]
    [InlineData(DatabaseEngine.DuckDb, "DuckDB", 0, true, true, "")]
    public void EngineDescriptors(DatabaseEngine engine, string name, int port, bool fileBased, bool hasSchemas, string user)
    {
        var descriptor = EngineDescriptor.For(engine);

        Assert.Equal(engine, descriptor.Engine);
        Assert.Equal(name, descriptor.DisplayName);
        Assert.Equal(port, descriptor.DefaultPort);
        Assert.Equal(fileBased, descriptor.IsFileBased);
        Assert.Equal(hasSchemas, descriptor.HasSchemas);
        Assert.Equal(user, descriptor.DefaultUser);
        Assert.Equal(fileBased, descriptor.FileExtensions.Length > 0);
    }

    [Fact]
    public void FileExtensionsAreDotPrefixedAndSemicolonSeparated()
    {
        Assert.Equal([".sqlite", ".sqlite3", ".db", ".db3"], EngineDescriptor.For(DatabaseEngine.Sqlite).FileExtensions.Split(';'));
        Assert.Equal([".duckdb", ".ddb"], EngineDescriptor.For(DatabaseEngine.DuckDb).FileExtensions.Split(';'));
    }

    [Fact]
    public void EnginesListsEveryEngineGroupedByFamilyThenInEnumOrder()
    {
        var engines = EngineDescriptor.Engines.ToArray();

        Assert.Equal(Enum.GetValues<DatabaseEngine>().Order(), engines.Select(d => d.Engine).Order());
        Assert.Equal(engines.OrderBy(d => d.Family).ThenBy(d => d.Engine), engines);
    }

    [Fact]
    public void EveryEngineHasADialect()
    {
        foreach (var engine in Enum.GetValues<DatabaseEngine>())
        {
            Assert.NotNull(SqlDialects.For(engine));
        }
    }

    [Fact]
    public void UnknownEngineHasNoDescriptor() =>
        Assert.Throws<KeyNotFoundException>(() => EngineDescriptor.For((DatabaseEngine)99));

    [Fact]
    public void ProfileDefaults()
    {
        var profile = new ConnectionProfile { Name = "local", Engine = DatabaseEngine.PostgreSql };

        Assert.NotEqual(Guid.Empty, profile.Id);
        Assert.Equal("localhost", profile.Host);
        Assert.Equal(0, profile.Port);
        Assert.Equal(SslMode.Preferred, profile.SslMode);
        Assert.Equal(SafeModeLevel.Silent, profile.SafeMode);
        Assert.Equal(ConnectionColor.None, profile.Color);
        Assert.Equal(ExternalAccessLevel.ReadOnly, profile.ExternalAccess);
        Assert.Equal(AiPolicy.AskEachTime, profile.AiPolicy);
        Assert.True(profile.SavePassword);
        Assert.Equal(15, profile.ConnectTimeoutSeconds);
        Assert.Empty(profile.AdditionalOptions);
        Assert.False(profile.IsReadOnly);
        Assert.Same(EngineDescriptor.For(DatabaseEngine.PostgreSql), profile.Descriptor);
    }

    [Fact]
    public void EachProfileGetsItsOwnId()
    {
        var a = new ConnectionProfile { Name = "a", Engine = DatabaseEngine.MySql };
        var b = new ConnectionProfile { Name = "a", Engine = DatabaseEngine.MySql };

        Assert.NotEqual(a.Id, b.Id);
    }

    [Theory]
    [InlineData(DatabaseEngine.PostgreSql, 0, 5432)]
    [InlineData(DatabaseEngine.PostgreSql, 6543, 6543)]
    [InlineData(DatabaseEngine.SqlServer, 0, 1433)]
    [InlineData(DatabaseEngine.MySql, -1, 3306)]
    [InlineData(DatabaseEngine.Sqlite, 0, 0)]
    public void EffectivePortFallsBackToTheEngineDefault(DatabaseEngine engine, int port, int expected) =>
        Assert.Equal(expected, new ConnectionProfile { Name = "x", Engine = engine, Port = port }.EffectivePort);

    [Fact]
    public void SubtitleShowsHostPortAndDatabase()
    {
        var profile = new ConnectionProfile { Name = "x", Engine = DatabaseEngine.PostgreSql, Host = "db.internal" };

        Assert.Equal("db.internal:5432", profile.Subtitle);
        Assert.Equal("db.internal:5432/app", (profile with { Database = "app" }).Subtitle);
        Assert.Equal("db.internal:6000/app", (profile with { Database = "app", Port = 6000 }).Subtitle);
        Assert.Equal("db.internal:5432", (profile with { Database = "" }).Subtitle);
    }

    [Fact]
    public void SubtitleOfAFileDatabaseIsItsPath()
    {
        var profile = new ConnectionProfile { Name = "x", Engine = DatabaseEngine.Sqlite, Database = "ignored" };

        Assert.Equal(string.Empty, profile.Subtitle);
        Assert.Equal(@"C:\data\app.db", (profile with { FilePath = @"C:\data\app.db" }).Subtitle);
        Assert.Equal("f.duckdb", (profile with { Engine = DatabaseEngine.DuckDb, FilePath = "f.duckdb" }).Subtitle);
    }

    [Fact]
    public void ReadOnlySafeModeMakesTheProfileReadOnly() =>
        Assert.True(new ConnectionProfile { Name = "x", Engine = DatabaseEngine.MySql, SafeMode = SafeModeLevel.ReadOnly }.IsReadOnly);

    [Theory]
    [InlineData(SafeModeLevel.Silent, false, false, false)]
    [InlineData(SafeModeLevel.Alert, false, true, false)]
    [InlineData(SafeModeLevel.AlertFull, false, true, true)]
    [InlineData(SafeModeLevel.SafeMode, false, true, false)]
    [InlineData(SafeModeLevel.SafeModeFull, false, true, true)]
    [InlineData(SafeModeLevel.ReadOnly, true, false, false)]
    public void SafeModeLevelBehaviour(SafeModeLevel level, bool blocksWrites, bool confirms, bool confirmsReads)
    {
        Assert.Equal(blocksWrites, level.BlocksAllWrites());
        Assert.Equal(confirms, level.RequiresConfirmation());
        Assert.Equal(confirmsReads, level.ConfirmsReads());
    }

    [Fact]
    public void SafeModeLevelsAreOrderedFromLeastToMostStrict() =>
        Assert.Equal(
            [SafeModeLevel.Silent, SafeModeLevel.Alert, SafeModeLevel.AlertFull, SafeModeLevel.SafeMode, SafeModeLevel.SafeModeFull, SafeModeLevel.ReadOnly],
            Enum.GetValues<SafeModeLevel>().Order());

    [Fact]
    public void SshDefaults()
    {
        var ssh = new SshTunnelSettings();

        Assert.False(ssh.Enabled);
        Assert.Equal(22, ssh.Port);
        Assert.Equal(SshAuthMethod.Agent, ssh.AuthMethod);
        Assert.Equal(string.Empty, ssh.Host);
    }

    [Fact]
    public void DirectRequestDialsWhatTheProfileSays()
    {
        var profile = new ConnectionProfile { Name = "x", Engine = DatabaseEngine.SqlServer, Host = "sql", Database = "app" };

        var request = ConnectionRequest.Direct(profile, "secret");

        Assert.Equal(new ConnectionRequest(profile, "secret", "sql", 1433, "app"), request);
    }

    [Fact]
    public void RegistryResolvesEachEngineOfADriver()
    {
        var mysql = new FakeDriver(DatabaseEngine.MySql, DatabaseEngine.MariaDb);
        var registry = new DriverRegistry().Register(mysql);

        Assert.True(registry.Supports(DatabaseEngine.MySql));
        Assert.True(registry.Supports(DatabaseEngine.MariaDb));
        Assert.False(registry.Supports(DatabaseEngine.PostgreSql));
        Assert.Same(mysql, registry.Resolve(DatabaseEngine.MySql));
        Assert.Same(mysql, registry.Resolve(DatabaseEngine.MariaDb));
    }

    [Fact]
    public void RegistryReportsAMissingDriverByName()
    {
        var registry = new DriverRegistry();

        var ex = Assert.Throws<NotSupportedException>(() => registry.Resolve(DatabaseEngine.SqlServer));

        Assert.Contains("SQL Server", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void LaterRegistrationReplacesAnEarlierOne()
    {
        var first = new FakeDriver(DatabaseEngine.MySql, DatabaseEngine.MariaDb);
        var second = new FakeDriver(DatabaseEngine.MariaDb);

        var registry = new DriverRegistry().Register(first).Register(second);

        Assert.Same(first, registry.Resolve(DatabaseEngine.MySql));
        Assert.Same(second, registry.Resolve(DatabaseEngine.MariaDb));
    }

    private sealed class FakeDriver(params DatabaseEngine[] engines) : IDatabaseDriver
    {
        public IReadOnlyList<DatabaseEngine> Engines { get; } = engines;

        public Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken) =>
            throw new NotSupportedException();
    }
}
