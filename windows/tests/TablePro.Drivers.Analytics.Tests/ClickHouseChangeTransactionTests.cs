using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Drivers.ClickHouse;

namespace TablePro.Drivers.Analytics.Tests;

/// <summary>ClickHouse has no transaction, so a multi-table sync keeps the table-by-table path and an import cannot delete first.</summary>
public sealed class ClickHouseChangeTransactionTests
{
    [Fact]
    public async Task ClickHouseOffersNoChangeTransactions()
    {
        await using var session = new ClickHouseSession(Profiles.Direct(Profiles.Profile(DatabaseEngine.ClickHouse)));

        Assert.Null(ChangeTransactions.For(session));
        await Assert.ThrowsAsync<NotSupportedException>(() => session.BeginChangesAsync(TestContext.Current.CancellationToken));
    }
}
