using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Drivers.MySql;

namespace TablePro.Drivers.Tests;

/// <summary>Which MySQL-family engines run a multi-table sync or a delete-first import in one transaction.</summary>
public sealed class ChangeTransactionCapabilityTests
{
    [Theory]
    [InlineData(DatabaseEngine.MySql, true)]
    [InlineData(DatabaseEngine.MariaDb, true)]
    [InlineData(DatabaseEngine.TiDb, true)]
    [InlineData(DatabaseEngine.Databend, false)]
    public async Task OnlyEnginesThatCanRollBackOfferChangeTransactions(DatabaseEngine engine, bool offered)
    {
        // Building the session opens nothing; the capability is known before any connection.
        await using var session = new MySqlSession(Profiles.Request(engine));

        Assert.Equal(offered, ChangeTransactions.For(session) is not null);
    }
}
