using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Drivers.Elasticsearch;
using TablePro.Drivers.SurrealDb;
using TablePro.Drivers.Typesense;
using TablePro.Drivers.Weaviate;

namespace TablePro.Drivers.Search.Tests;

/// <summary>
/// Runs against real servers only when their URL is set, for example
/// <c>TABLEPRO_TEST_ELASTICSEARCH_URL=http://localhost:9200</c>. Credentials come from the matching <c>_USER</c>,
/// <c>_PASSWORD</c> and, for SurrealDB, <c>_DATABASE</c> (<c>ns/db</c>) variables.
/// </summary>
public sealed class IntegrationTests
{
    private static CancellationToken None => TestContext.Current.CancellationToken;

    [Fact]
    public Task Elasticsearch() => RoundTripAsync(new ElasticsearchDriver(), DatabaseEngine.Elasticsearch, "ELASTICSEARCH", "GET /_cluster/health");

    [Fact]
    public Task Typesense() => RoundTripAsync(new TypesenseDriver(), DatabaseEngine.Typesense, "TYPESENSE", "GET /collections");

    [Fact]
    public Task Weaviate() => RoundTripAsync(new WeaviateDriver(), DatabaseEngine.Weaviate, "WEAVIATE", "{ Get { __typename } }", allowStatementError: true);

    [Fact]
    public Task SurrealDb() => RoundTripAsync(new SurrealDbDriver(), DatabaseEngine.SurrealDb, "SURREALDB", "RETURN 1 + 1;");

    private static async Task RoundTripAsync(IDatabaseDriver driver, DatabaseEngine engine, string name, string statement, bool allowStatementError = false)
    {
        var url = Environment.GetEnvironmentVariable($"TABLEPRO_TEST_{name}_URL");
        Assert.SkipWhen(string.IsNullOrWhiteSpace(url), $"Set TABLEPRO_TEST_{name}_URL to run against a server.");

        var uri = new Uri(url!);
        var profile = new ConnectionProfile
        {
            Name = name,
            Engine = engine,
            Host = uri.Host,
            Port = uri.Port,
            Username = Environment.GetEnvironmentVariable($"TABLEPRO_TEST_{name}_USER"),
            Database = Environment.GetEnvironmentVariable($"TABLEPRO_TEST_{name}_DATABASE"),
            SslMode = uri.Scheme == Uri.UriSchemeHttps ? SslMode.Required : SslMode.Disabled,
        };

        await using var session = await driver.ConnectAsync(ConnectionRequest.Direct(profile, Environment.GetEnvironmentVariable($"TABLEPRO_TEST_{name}_PASSWORD")), None);
        await session.PingAsync(None);
        var objects = await session.GetObjectsAsync(session.DefaultSchema, None);
        if (objects.Count > 0)
        {
            await session.GetStructureAsync(objects[0].Name, None);
        }

        await using var channel = await session.OpenChannelAsync(None);
        await foreach (var result in channel.ExecuteAsync([statement], new ExecuteOptions(), None))
        {
            Assert.True(allowStatementError || result.Succeeded, result.Error);
        }
    }
}
