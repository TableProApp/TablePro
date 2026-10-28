using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Drivers.BigQuery;
using TablePro.Drivers.Snowflake;
using TablePro.Drivers.Spanner;
using TablePro.Drivers.Trino;

namespace TablePro.Drivers.Warehouse.Tests;

public sealed class SessionContractTests
{
    /// <summary>
    /// The ADO.NET sessions re-implement part of IDatabaseSession; a call through the interface must reach the
    /// engine's own method, not AdoNetSession's, or Snowflake binds by the wrong name and Spanner runs DDL as a query.
    /// </summary>
    [Theory]
    [InlineData(typeof(SnowflakeSession), new[] { "BrowseAsync", "CountAsync", "SaveChangesAsync" })]
    [InlineData(typeof(SpannerSession), new[] { "BrowseAsync", "CountAsync", "SaveChangesAsync", "OpenChannelAsync", "PingAsync" })]
    public void InterfaceCallsReachTheEngineOverrides(Type session, string[] methods)
    {
        var map = session.GetInterfaceMap(typeof(IDatabaseSession));

        foreach (var name in methods)
        {
            var index = Array.FindIndex(map.InterfaceMethods, m => m.Name == name);
            Assert.Equal(session, map.TargetMethods[index].DeclaringType);
        }
    }

    [Fact]
    public void EachDriverServesItsEngine()
    {
        Assert.Equal([DatabaseEngine.Snowflake], new SnowflakeDriver().Engines);
        Assert.Equal([DatabaseEngine.BigQuery], new BigQueryDriver().Engines);
        Assert.Equal([DatabaseEngine.Spanner], new SpannerDriver().Engines);
        Assert.Equal([DatabaseEngine.Trino], new TrinoDriver().Engines);
    }

    [Fact]
    public async Task SessionsDoNotDialUntilConnected()
    {
        await using var snowflake = new SnowflakeSession(Profiles.Request(DatabaseEngine.Snowflake, host: "xy12345"));
        await using var spanner = new SpannerSession(Profiles.Request(DatabaseEngine.Spanner, host: "projects/p/instances/i/databases/d"));
        await using var bigQuery = new BigQuerySession(Profiles.Request(DatabaseEngine.BigQuery, database: "proj"));

        Assert.Equal("PUBLIC", snowflake.DefaultSchema);
        Assert.Equal(string.Empty, spanner.DefaultSchema);
        Assert.Equal("d", spanner.CurrentDatabase);
        Assert.Equal("proj", bigQuery.CurrentDatabase);
        Assert.Equal(["proj"], await bigQuery.GetDatabasesAsync(TestContext.Current.CancellationToken));
    }
}
