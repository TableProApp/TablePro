using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Principals;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Oracle;
using TablePro.Drivers.Tests.Live;

namespace TablePro.Drivers.Analytics.Tests;

/// <summary>
/// The relational live suite against TABLEPRO_ORACLE_ADMIN, a login that may read V$SESSION and create users, for example
/// <c>host=localhost;port=1521;user=system;password=TablePro-test-1;database=FREEPDB1</c>.
/// </summary>
public sealed class OracleServerTests : RelationalServerTests
{
    protected override string Variable => "TABLEPRO_ORACLE_ADMIN";

    protected override DatabaseEngine Engine => DatabaseEngine.Oracle;

    protected override IDatabaseDriver Driver { get; } = new OracleDriver();

    protected override string IntType => "NUMBER(10)";

    protected override string TextType => "VARCHAR2(100)";

    // Wider than the integer column it replaces: Oracle refuses to narrow the integer digits of a column with rows.
    protected override string DecimalType => "NUMBER(12,2)";

    protected override string TimestampType => "TIMESTAMP";

    // DBMS_SESSION.SLEEP only notices a cancel when it wakes, so the statement is a join Oracle cannot shortcut.
    protected override string SleepStatement => "SELECT COUNT(*) FROM all_objects a, all_objects b WHERE a.object_name || b.object_name = 'x'";

    protected override string ConnectionIdStatement => "SELECT SID || ',' || SERIAL# FROM V$SESSION WHERE SID = SYS_CONTEXT('USERENV', 'SID')";

    protected override string SelectOne => "SELECT 1 FROM DUAL";

    protected override string? BeginStatement => null;

    protected override bool ErrorNamesTheMissingTable => false;

    protected override bool ServerEnforcesReadOnly => false;

    protected override PrivilegeScope TableScope(IDatabaseSession session, ObjectName table) =>
        PrivilegeScope.ForTable(table.Schema!, null, table.Name);

    /// <summary>
    /// The editor's first write opens a transaction the tab says it holds; COMMIT keeps it, and closing the tab with one
    /// open rolls it back rather than leaving ODP.NET to commit each statement.
    /// </summary>
    [Fact]
    public async Task TheEditorHoldsItsChangesUntilCommitAndRollsBackWhenTheTabCloses()
    {
        await using var session = await ConnectAsync();
        var table = await CreateItemsAsync(session, 10);
        try
        {
            var qualified = session.Dialect.Qualify(table);
            await using (var channel = await session.OpenChannelAsync(Ct))
            {
                var deleted = Assert.Single(await RunAsync(channel, [$"DELETE FROM {qualified} WHERE \"id\" = 1"]));
                Assert.True(deleted.Succeeded, deleted.Error);
                Assert.Contains(CoreStrings.Get("Driver/TransactionStartedByWrite"), deleted.Messages ?? []);

                // Another connection does not see an uncommitted delete.
                Assert.Equal(10, await session.CountAsync(table, BrowseFilter.None, Ct));
                var committed = Assert.Single(await RunAsync(channel, ["COMMIT"]));
                Assert.Contains(CoreStrings.Get("Driver/Committed"), committed.Messages ?? []);
                Assert.Equal(9, await session.CountAsync(table, BrowseFilter.None, Ct));

                // A block that commits inside itself leaves no transaction behind for the tab to end.
                var block = Assert.Single(await RunAsync(channel, [$"BEGIN DELETE FROM {qualified} WHERE \"id\" = 2; COMMIT; END;"]));
                Assert.True(block.Succeeded, block.Error);
                Assert.DoesNotContain(CoreStrings.Get("Driver/TransactionStartedByWrite"), block.Messages ?? []);
                Assert.Equal(8, await session.CountAsync(table, BrowseFilter.None, Ct));

                Assert.True(Assert.Single(await RunAsync(channel, [$"DELETE FROM {qualified}"])).Succeeded);
            }

            Assert.Equal(8, await session.CountAsync(table, BrowseFilter.None, Ct));

            // An import, a copy or an MCP call keeps ODP.NET's commit per statement.
            await using (var channel = await session.OpenChannelAsync(Ct))
            {
                await foreach (var result in channel.ExecuteAsync([$"DELETE FROM {qualified} WHERE \"id\" = 3"], new ExecuteOptions(), Ct))
                {
                    Assert.True(result.Succeeded, result.Error);
                    Assert.DoesNotContain(CoreStrings.Get("Driver/TransactionStartedByWrite"), result.Messages ?? []);
                }

                Assert.Equal(7, await session.CountAsync(table, BrowseFilter.None, Ct));
            }
        }
        finally
        {
            await DropQuietlyAsync(session, table);
        }
    }
}
