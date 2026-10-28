using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Drivers.BigQuery;
using TablePro.Drivers.Snowflake;
using TablePro.Drivers.Spanner;
using TablePro.Drivers.Trino;

namespace TablePro.Drivers.Warehouse.Tests;

/// <summary>
/// Against real services, only when their environment variables are set; otherwise each test is skipped.
/// TABLEPRO_TEST_TRINO=host:port (plain HTTP, user "trino", catalog "tpch");
/// TABLEPRO_TEST_SPANNER_EMULATOR=host:port with TABLEPRO_TEST_SPANNER_DATABASE=projects/p/instances/i/databases/d;
/// TABLEPRO_TEST_BIGQUERY_PROJECT with Application Default Credentials;
/// TABLEPRO_TEST_SNOWFLAKE_ACCOUNT, TABLEPRO_TEST_SNOWFLAKE_USER and TABLEPRO_TEST_SNOWFLAKE_PASSWORD.
/// </summary>
public sealed class IntegrationTests
{
    [Fact]
    public async Task TrinoRunsAQueryAndListsSchemas()
    {
        var endpoint = Require("TABLEPRO_TEST_TRINO");
        var colon = endpoint.LastIndexOf(':');
        var profile = Profile(DatabaseEngine.Trino) with
        {
            Host = colon > 0 ? endpoint[..colon] : endpoint,
            Port = colon > 0 ? int.Parse(endpoint[(colon + 1)..], System.Globalization.CultureInfo.InvariantCulture) : 8080,
            Username = "trino",
            Database = "tpch",
            SslMode = SslMode.Disabled,
        };

        await RoundTripAsync(new TrinoDriver(), ConnectionRequest.Direct(profile, null));
    }

    [Fact]
    public async Task SpannerEmulatorRunsAQuery()
    {
        var emulator = Require("TABLEPRO_TEST_SPANNER_EMULATOR");
        var profile = Profile(DatabaseEngine.Spanner) with
        {
            Host = Require("TABLEPRO_TEST_SPANNER_DATABASE"),
            AdditionalOptions = new Dictionary<string, string> { ["emulatorHost"] = emulator },
        };

        await RoundTripAsync(new SpannerDriver(), ConnectionRequest.Direct(profile, null));
    }

    [Fact]
    public async Task BigQueryRunsAQuery()
    {
        var profile = Profile(DatabaseEngine.BigQuery) with { Database = Require("TABLEPRO_TEST_BIGQUERY_PROJECT") };

        await RoundTripAsync(new BigQueryDriver(), ConnectionRequest.Direct(profile, null));
    }

    [Fact]
    public async Task SnowflakeRunsAQuery()
    {
        var profile = Profile(DatabaseEngine.Snowflake) with
        {
            Host = Require("TABLEPRO_TEST_SNOWFLAKE_ACCOUNT"),
            Username = Require("TABLEPRO_TEST_SNOWFLAKE_USER"),
        };

        await RoundTripAsync(new SnowflakeDriver(), ConnectionRequest.Direct(profile, Require("TABLEPRO_TEST_SNOWFLAKE_PASSWORD")));
    }

    private static ConnectionProfile Profile(DatabaseEngine engine) => new() { Name = "integration", Engine = engine };

    private static string Require(string variable)
    {
        var value = Environment.GetEnvironmentVariable(variable);
        Assert.SkipWhen(string.IsNullOrWhiteSpace(value), $"{variable} is not set.");
        return value!;
    }

    private static async Task RoundTripAsync(IDatabaseDriver driver, ConnectionRequest request)
    {
        var ct = TestContext.Current.CancellationToken;
        await using var session = await driver.ConnectAsync(request, ct);
        await session.PingAsync(ct);
        _ = await session.GetSchemasAsync(ct);

        await using var channel = await session.OpenChannelAsync(ct);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(["SELECT 1"], new ExecuteOptions(), ct))
        {
            results.Add(result);
        }

        var single = Assert.Single(results);
        Assert.True(single.Succeeded, single.Error);
        Assert.Equal(1, Convert.ToInt32(Assert.Single(single.ResultSets)[0, 0], System.Globalization.CultureInfo.InvariantCulture));
    }
}
