namespace TablePro.App.Model.Tests;

public sealed class SessionWriterTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-session-").FullName;

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    private string SessionFile => Path.Combine(_directory, "session.json");

    private static SessionState Holding(string sql) => new()
    {
        Connections =
        [
            new SessionConnection
            {
                FilePath = @"C:\data\app.sqlite",
                Name = "app",
                EngineId = "sqlite",
                Tabs = [new SessionTab { Kind = TabKind.Query, Title = "Query 1", Sql = sql }],
            },
        ],
        Front = 0,
    };

    private static string? SqlIn(SessionStore store) =>
        store.Load().Connections.SingleOrDefault()?.Tabs.SingleOrDefault()?.Sql;

    [Fact]
    public async Task ASaveFromThePoolNeverLandsOverALaterOne()
    {
        var store = new SessionStore(SessionFile);
        var writer = new SessionWriter(store);

        for (var round = 0; round < 50; round++)
        {
            var earlier = writer.SaveInBackgroundAsync(Holding($"SELECT {round}"));
            Assert.Equal(SessionSave.Written, writer.Save(Holding($"SELECT {round} -- later")));
            await earlier;

            Assert.Equal($"SELECT {round} -- later", SqlIn(store));
        }
    }

    [Fact]
    public async Task NothingIsWrittenAfterTheLastSave()
    {
        var store = new SessionStore(SessionFile);
        var writer = new SessionWriter(store);

        Assert.Equal(SessionSave.Written, writer.Save(Holding("SELECT 'last'"), last: true));
        var after = await writer.SaveInBackgroundAsync(Holding("SELECT 'emptied as the tabs close'"));

        Assert.Equal(SessionSave.Skipped, after);
        Assert.Equal(SessionSave.Skipped, writer.Save(Holding("SELECT 'again'")));
        Assert.Equal("SELECT 'last'", SqlIn(store));
    }

    [Fact]
    public async Task ASaveTheFileRefusesSaysSoAndLeavesTheOneBefore()
    {
        var store = new SessionStore(SessionFile);
        var writer = new SessionWriter(store);
        Assert.Equal(SessionSave.Written, await writer.SaveInBackgroundAsync(Holding("SELECT 1")));
        File.Delete(SessionFile);
        Directory.CreateDirectory(SessionFile);

        Assert.Equal(SessionSave.Refused, await writer.SaveInBackgroundAsync(Holding("SELECT 2")));

        Directory.Delete(SessionFile);
        Assert.Equal(SessionSave.Written, writer.Save(Holding("SELECT 3")));
        Assert.Equal("SELECT 3", SqlIn(store));
    }
}
