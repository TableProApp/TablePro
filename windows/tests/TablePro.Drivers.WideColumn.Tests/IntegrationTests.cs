using System.Globalization;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Cassandra;
using TablePro.Drivers.DynamoDb;

namespace TablePro.Drivers.WideColumn.Tests;

/// <summary>
/// Runs against real servers only when asked: TABLEPRO_CASSANDRA=host[:port] (Cassandra or ScyllaDB, no login) and
/// TABLEPRO_DYNAMODB=http://localhost:8000 (DynamoDB Local).
/// </summary>
public sealed class IntegrationTests
{
    [Fact]
    public async Task CassandraRoundTrip()
    {
        var target = Environment.GetEnvironmentVariable("TABLEPRO_CASSANDRA");
        Assert.SkipWhen(string.IsNullOrWhiteSpace(target), "Set TABLEPRO_CASSANDRA=host[:port] to run against a server.");
        var ct = TestContext.Current.CancellationToken;
        var (host, port) = Split(target!, 9042);
        var keyspace = "tablepro_" + Guid.NewGuid().ToString("N")[..8];

        var request = Requests.For(DatabaseEngine.Cassandra, host: host, port: port, user: null, password: null, database: null, ssl: SslMode.Disabled);
        await using var session = (CassandraSession)await new CassandraDriver().ConnectAsync(request, ct);
        await using var channel = await session.OpenChannelAsync(ct);
        await RunAsync(channel, ct,
            $"CREATE KEYSPACE {keyspace} WITH replication = {{'class': 'SimpleStrategy', 'replication_factor': 1}}",
            $"CREATE TYPE {keyspace}.address (street text, zip int)",
            $"CREATE TABLE {keyspace}.items (id int, at timestamp, tags set<text>, home frozen<address>, note text, PRIMARY KEY (id, at))");
        try
        {
            var table = new ObjectName(keyspace, "items");
            var at = new DateTimeOffset(2024, 1, 2, 3, 4, 5, TimeSpan.Zero);
            await session.SaveChangesAsync(table, [
                new RowInsert(new Dictionary<string, object?> { ["id"] = 1, ["at"] = at, ["tags"] = "[\"a\",\"b\"]", ["home"] = "{\"street\":\"Main\",\"zip\":1}", ["note"] = "x" }),
                new RowInsert(new Dictionary<string, object?> { ["id"] = 2, ["at"] = at, ["note"] = "y" }),
            ], ct);
            await session.SaveChangesAsync(table, [new RowUpdate(new Dictionary<string, object?> { ["id"] = 2, ["at"] = at }, new Dictionary<string, object?> { ["note"] = "z" })], ct);

            var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 1), ct);
            Assert.Single(page.Rows);
            Assert.True(page.IsTruncated);
            var next = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 1, 10), ct);
            Assert.Single(next.Rows);

            var filtered = await session.BrowseAsync(new BrowseRequest(table, new BrowseFilter([new FilterRule("id", FilterOperator.Equals, "1")]), [], 0, 10), ct);
            var row = Assert.Single(filtered.Rows);
            Assert.Equal("[\"a\",\"b\"]", row[filtered.ColumnIndex("tags")]);
            Assert.Equal("{\"street\":\"Main\",\"zip\":1}", row[filtered.ColumnIndex("home")]);

            Assert.Equal(2, await session.CountAsync(table, BrowseFilter.None, ct));
            var structure = await session.GetStructureAsync(table, ct);
            Assert.Equal(["id", "at"], structure.PrimaryKey);
            Assert.StartsWith($"CREATE TABLE \"{keyspace}\".\"items\"", await session.GetDefinitionAsync(new DatabaseObject(table, ObjectKind.Table), ct), StringComparison.Ordinal);
            Assert.Contains(await session.GetObjectsAsync(keyspace, ct), o => CassandraObjects.IsUserType(o));

            await session.SaveChangesAsync(table, [new RowDelete(new Dictionary<string, object?> { ["id"] = 1, ["at"] = at })], ct);
            Assert.Equal(1, await session.CountAsync(table, BrowseFilter.None, ct));
        }
        finally
        {
            await RunAsync(channel, ct, $"DROP KEYSPACE {keyspace}");
        }
    }

    [Fact]
    public async Task DynamoDbLocalRoundTrip()
    {
        var endpoint = Environment.GetEnvironmentVariable("TABLEPRO_DYNAMODB");
        Assert.SkipWhen(string.IsNullOrWhiteSpace(endpoint), "Set TABLEPRO_DYNAMODB=http://localhost:8000 to run against DynamoDB Local.");
        var ct = TestContext.Current.CancellationToken;
        var tableName = "tablepro_" + Guid.NewGuid().ToString("N")[..8];

        using (var admin = new AmazonDynamoDBClient(new Amazon.Runtime.BasicAWSCredentials("local", "local"), new AmazonDynamoDBConfig { ServiceURL = endpoint, AuthenticationRegion = "us-east-1" }))
        {
            await admin.CreateTableAsync(
                new CreateTableRequest
                {
                    TableName = tableName,
                    KeySchema = [new KeySchemaElement("pk", KeyType.HASH)],
                    AttributeDefinitions = [new AttributeDefinition("pk", ScalarAttributeType.S)],
                    BillingMode = BillingMode.PAY_PER_REQUEST,
                },
                ct);
        }

        var request = Requests.For(DatabaseEngine.DynamoDb, host: "us-east-1", user: null, password: null, options: new Dictionary<string, string> { ["endpoint"] = endpoint! });
        await using var session = await new DynamoDbDriver().ConnectAsync(request, ct);
        var table = new ObjectName(null, tableName);

        await session.SaveChangesAsync(table, [.. Enumerable.Range(0, 30).Select(i => new RowInsert(new Dictionary<string, object?>
        {
            ["pk"] = "k" + i.ToString("D2", CultureInfo.InvariantCulture),
            ["n"] = (decimal)i,
        }))], ct);

        var first = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 10), ct);
        Assert.Equal(10, first.RowCount);
        Assert.True(first.IsTruncated);
        var rest = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 20, 50), ct);
        Assert.Equal(10, rest.RowCount);

        var filtered = await session.BrowseAsync(new BrowseRequest(table, new BrowseFilter([new FilterRule("n", FilterOperator.GreaterOrEqual, "25")]), [], 0, 50), ct);
        Assert.Equal(5, filtered.RowCount);

        await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(
            table, [new RowUpdate(new Dictionary<string, object?> { ["pk"] = "missing" }, new Dictionary<string, object?> { ["n"] = 1m })], ct));

        await using var channel = await session.OpenChannelAsync(ct);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync([$"SELECT * FROM \"{tableName}\" WHERE pk = 'k01'"], new ExecuteOptions(), ct))
        {
            results.Add(result);
        }

        Assert.True(results[0].Succeeded, results[0].Error);
        Assert.Equal(1, results[0].ResultSets[0].RowCount);
    }

    private static async Task RunAsync(IQueryChannel channel, CancellationToken ct, params string[] statements)
    {
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(), ct))
        {
            Assert.True(result.Succeeded, result.Error);
        }
    }

    private static (string Host, int Port) Split(string target, int defaultPort)
    {
        var colon = target.LastIndexOf(':');
        return colon > 0 && int.TryParse(target.AsSpan(colon + 1), CultureInfo.InvariantCulture, out var port)
            ? (target[..colon], port)
            : (target, defaultPort);
    }
}
