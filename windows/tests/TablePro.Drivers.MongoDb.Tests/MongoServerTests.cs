using System.Globalization;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.MongoDb.Tests;

/// <summary>Runs against a real server when TABLEPRO_MONGODB names one as host:port, without access control.</summary>
public sealed class MongoServerTests
{
    private static readonly string? Server = Environment.GetEnvironmentVariable("TABLEPRO_MONGODB");

    private static async Task<IDatabaseSession> ConnectAsync(string database, bool readOnly = false)
    {
        Assert.SkipWhen(string.IsNullOrWhiteSpace(Server), "Set TABLEPRO_MONGODB to host:port to run the MongoDB server tests.");
        var parts = Server!.Split(':');
        var profile = new ConnectionProfile
        {
            Name = "test",
            Engine = DatabaseEngine.MongoDb,
            Host = parts[0],
            Port = parts.Length > 1 ? int.Parse(parts[1], CultureInfo.InvariantCulture) : 27017,
            Database = database,
            SslMode = SslMode.Disabled,
            SafeMode = readOnly ? SafeModeLevel.ReadOnly : SafeModeLevel.Silent,
        };
        return await new MongoDbDriver().ConnectAsync(ConnectionRequest.Direct(profile, null), TestContext.Current.CancellationToken);
    }

    private static async Task<List<StatementResult>> RunAsync(IDatabaseSession session, params string[] statements)
    {
        await using var channel = await session.OpenChannelAsync(TestContext.Current.CancellationToken);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(StopOnError: false), TestContext.Current.CancellationToken))
        {
            results.Add(result);
        }

        return results;
    }

    [Fact]
    public async Task BrowsesEditsAndQueriesACollection()
    {
        var database = "tablepro_test_" + Guid.NewGuid().ToString("N")[..8];
        await using var session = await ConnectAsync(database);
        var ct = TestContext.Current.CancellationToken;
        try
        {
            var setup = await RunAsync(
                session,
                "db.people.insertMany([{name: 'Ada', age: 36, tags: ['math']}, {name: 'Alan', age: NumberLong(41)}, {name: 'Grace', age: 85}])",
                "db.people.createIndex({name: 1}, {unique: true})");
            Assert.All(setup, r => Assert.True(r.Succeeded, r.Error));

            var table = new ObjectName(database, "people");
            var structure = await session.GetStructureAsync(table, ct);
            Assert.Equal(["_id", "name", "age", "tags"], structure.Columns.Select(c => c.Name));
            Assert.Equal(["_id"], structure.PrimaryKey);
            Assert.Contains(structure.Indexes, i => i.Name == "name_1" && i.IsUnique);

            var filter = new BrowseFilter([new FilterRule("name", FilterOperator.StartsWith, "a")]);
            var page = await session.BrowseAsync(new BrowseRequest(table, filter, [new SortColumn("age", false)], 0, 10), ct);
            Assert.Equal(["Ada", "Alan"], page.Rows.Select(r => r[1]));
            Assert.Equal(2, await session.CountAsync(table, filter, ct));

            var id = page.Rows[0][0];
            var saved = await session.SaveChangesAsync(table, [new RowUpdate(new Dictionary<string, object?> { ["_id"] = id }, new Dictionary<string, object?> { ["age"] = 37L })], ct);
            Assert.Equal(1, saved);

            await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(
                table, [new RowDelete(new Dictionary<string, object?> { ["_id"] = "000000000000000000000000" })], ct));

            var query = await RunAsync(session, "db.people.find({age: {$gt: 36}}).sort({age: 1}).limit(5)", "db.people.countDocuments({})", "db.people.distinct('name')");
            Assert.Equal(3, query[0].ResultSets[0].RowCount);
            Assert.Equal(3L, query[1].ResultSets[0][0, 0]);
            Assert.Equal(3, query[2].ResultSets[0].RowCount);

            var objects = await session.GetObjectsAsync(database, ct);
            Assert.Contains(objects, o => o.Name.Name == "people" && o.Kind == ObjectKind.Collection && o.RowEstimate == 3);
            Assert.Contains("createIndex", await session.GetDefinitionAsync(objects[0], ct), StringComparison.Ordinal);
        }
        finally
        {
            await RunAsync(session, $"db.getSiblingDB('{database}').dropDatabase()");
        }
    }

    [Fact]
    public async Task ReadOnlyRefusesWrites()
    {
        await using var session = await ConnectAsync("test", readOnly: true);

        var results = await RunAsync(session, "db.people.insertOne({a: 1})", "db.people.find()");

        Assert.False(results[0].Succeeded);
        Assert.True(results[1].Succeeded, results[1].Error);
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.SaveChangesAsync(
            new ObjectName("test", "people"), [new RowInsert(new Dictionary<string, object?> { ["a"] = 1 })], TestContext.Current.CancellationToken));
    }
}
