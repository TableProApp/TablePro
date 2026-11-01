using Microsoft.Data.Sqlite;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.LibSql;
using TablePro.Drivers.Sqlite;
using static TablePro.Drivers.Services.Tests.Requests;

namespace TablePro.Drivers.Services.Tests;

public sealed class LibSqlStructureTests
{
    private static readonly ObjectName Notes = new(null, "notes");

    private static IReadOnlyList<string> Build(SchemaChange change) => LibSqlDdl.Build(Notes, change);

    [Theory]
    [InlineData("file:C:\\data\\app.db", "C:\\data\\app.db")]
    [InlineData("file:local.db", "local.db")]
    [InlineData("file:///C:/data/app.db", "C:\\data\\app.db")]
    [InlineData("libsql://db-acme.turso.io", null)]
    [InlineData("localhost", null)]
    public void FileUrlsNameALocalDatabase(string url, string? expected)
    {
        Assert.Equal(expected, LibSqlSettings.FilePathFromUrl(url));
    }

    [Fact]
    public void MacLocalModeReadsItsFilePathOption()
    {
        var options = new Dictionary<string, string> { [LibSqlSettings.ModeOption] = "local", [LibSqlSettings.FilePathOption] = "C:\\db\\a.db" };

        Assert.Equal("C:\\db\\a.db", LibSqlSettings.LocalFile(For(DatabaseEngine.LibSql, "", options: options).Profile));
        Assert.Throws<LibSqlException>(() => LibSqlSettings.LocalFile(For(DatabaseEngine.LibSql, "", options: new() { [LibSqlSettings.ModeOption] = "local" }).Profile));
        Assert.Null(LibSqlSettings.LocalFile(For(DatabaseEngine.Turso, "libsql://db-acme.turso.io", options: new() { [LibSqlSettings.ModeOption] = "remote" }).Profile));
    }

    [Fact]
    public void LocalRequestKeepsTheConnectionAndDropsLibSqlOptions()
    {
        var options = new Dictionary<string, string> { [LibSqlSettings.ModeOption] = "local", ["databaseUrl"] = "x", ["Cache"] = "Shared" };
        var profile = For(DatabaseEngine.Turso, "file:a.db", options: options).Profile;

        var local = LibSqlDriver.LocalRequest(profile, "C:\\db\\a.db");

        Assert.Equal(profile.Id, local.Profile.Id);
        Assert.Equal(DatabaseEngine.Turso, local.Profile.Engine);
        Assert.Equal("C:\\db\\a.db", local.Profile.FilePath);
        Assert.Equal(["Cache"], local.Profile.AdditionalOptions.Keys);
        Assert.Null(local.Password);
    }

    [Fact]
    public async Task LocalFileOpensThroughTheSqliteDriverWithItsStructureEditor()
    {
        var path = Path.Combine(Path.GetTempPath(), $"tablepro-libsql-{Guid.NewGuid():N}.db");
        try
        {
            var ct = TestContext.Current.CancellationToken;
            await using (var session = await new LibSqlDriver(new SqliteDriver()).ConnectAsync(For(DatabaseEngine.LibSql, "file:" + path), ct))
            {
                Assert.Equal(DatabaseEngine.LibSql, session.Profile.Engine);
                var ddl = Assert.IsAssignableFrom<ISchemaDdlProvider>(session);

                await using (var channel = await session.OpenChannelAsync(ct))
                {
                    var statements = ddl.BuildDdl(Notes, new CreateTable(Notes, [new ColumnDefinition("id", "INTEGER", false, IsPrimaryKey: true), new ColumnDefinition("body", "TEXT")]));
                    await foreach (var result in channel.ExecuteAsync([.. statements, "INSERT INTO notes (body) VALUES ('hi')"], new ExecuteOptions(), ct))
                    {
                        Assert.True(result.Succeeded, result.Error);
                    }

                    // A type change rebuilds the table, which only a local file can do.
                    var alter = ddl.BuildDdl(new ObjectName("main", "notes"), new AlterColumn(new ColumnDefinition("body", "TEXT"), new ColumnDefinition("body", "TEXT", false, "'x'")));
                    Assert.NotEmpty(alter);
                    await foreach (var result in channel.ExecuteAsync(alter, new ExecuteOptions(), ct))
                    {
                        Assert.True(result.Succeeded, result.Error);
                    }
                }

                var objects = await session.GetObjectsAsync(null, ct);
                Assert.Contains(objects, o => o.Name.Name == "notes");
                var structure = await session.GetStructureAsync(new ObjectName("main", "notes"), ct);
                Assert.False(structure.Columns.Single(c => c.Name == "body").IsNullable);
            }
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            File.Delete(path);
        }
    }

    [Fact]
    public async Task LocalFileWithoutALocalDriverIsRefused()
    {
        await Assert.ThrowsAsync<LibSqlException>(() => new LibSqlDriver().ConnectAsync(For(DatabaseEngine.LibSql, "file:a.db"), TestContext.Current.CancellationToken));
    }

    [Fact]
    public void RemoteCreateTableInlinesALoneKey()
    {
        var change = new CreateTable(Notes, [
            new ColumnDefinition("id", "INTEGER", false, IsPrimaryKey: true, IsIdentity: true),
            new ColumnDefinition("created", "TEXT", true, "datetime('now')"),
            new ColumnDefinition("state", "TEXT", true, "new"),
        ]);

        Assert.Equal(
            ["CREATE TABLE \"notes\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,\n  \"created\" TEXT DEFAULT (datetime('now')),\n  \"state\" TEXT DEFAULT 'new'\n)"],
            Build(change));
    }

    [Fact]
    public void RemoteCompositeKeyIsATableConstraint()
    {
        var change = new CreateTable(Notes, [new ColumnDefinition("a", "TEXT", IsPrimaryKey: true), new ColumnDefinition("b", "TEXT", IsPrimaryKey: true)]);

        Assert.Equal(["CREATE TABLE \"notes\" (\n  \"a\" TEXT,\n  \"b\" TEXT,\n  PRIMARY KEY (\"a\", \"b\")\n)"], Build(change));
    }

    [Fact]
    public void RemoteOneStatementChanges()
    {
        Assert.Equal(["ALTER TABLE \"notes\" ADD COLUMN \"tag\" TEXT NOT NULL DEFAULT ''"], Build(new AddColumn(new ColumnDefinition("tag", "TEXT", false, "''", IsPrimaryKey: true))));
        Assert.Equal(["ALTER TABLE \"notes\" DROP COLUMN \"tag\""], Build(new DropColumn("tag")));
        Assert.Equal(["ALTER TABLE \"notes\" RENAME COLUMN \"a\" TO \"b\""], Build(new RenameColumn("a", "b")));
        Assert.Equal(["CREATE UNIQUE INDEX \"ix\" ON \"notes\" (\"a\", \"b\")"], Build(new CreateIndex(new IndexDefinition("ix", ["a", "b"], IsUnique: true))));
        Assert.Equal(["DROP INDEX \"ix\""], Build(new DropIndex("ix")));
        Assert.Equal(["ALTER TABLE \"notes\" RENAME TO \"memos\""], Build(new RenameTable("memos")));
        Assert.Equal(["DELETE FROM \"notes\""], Build(new TruncateTable()));
        Assert.Equal(["DROP VIEW \"v\""], Build(new DropObject(new DatabaseObject(new ObjectName(null, "v"), ObjectKind.View))));
    }

    [Fact]
    public void RemoteAlterTakesARenameButNotARebuild()
    {
        Assert.Equal(["ALTER TABLE \"notes\" RENAME COLUMN \"a\" TO \"b\""], Build(new AlterColumn(new ColumnDefinition("a", "TEXT"), new ColumnDefinition("b", "TEXT"))));
        Assert.Empty(Build(new AlterColumn(new ColumnDefinition("a", "TEXT"), new ColumnDefinition("a", "INTEGER"))));
        Assert.Empty(Build(new AddForeignKey(new ForeignKeyDefinition("fk", ["a"], new ObjectName(null, "p"), ["id"]))));
        Assert.Empty(Build(new AddCheckConstraint(new CheckConstraintDefinition("ck", "a > 0"))));
    }

    [Theory]
    [InlineData("0", "0")]
    [InlineData("-1.5", "-1.5")]
    [InlineData("NULL", "NULL")]
    [InlineData("CURRENT_TIMESTAMP", "CURRENT_TIMESTAMP")]
    [InlineData("'it''s'", "'it''s'")]
    [InlineData("'a' || 'b'", "('a' || 'b')")]
    [InlineData("abc", "'abc'")]
    [InlineData("NaN", "'NaN'")]
    [InlineData("X'00ff'", "X'00ff'")]
    public void CatalogDefaultsAreWrittenBackAsSql(string value, string expected)
    {
        Assert.Equal(expected, LibSqlDdl.DefaultValue(value));
    }
}
