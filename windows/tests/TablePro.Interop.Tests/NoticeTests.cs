using TablePro.Testing;
using Native = TablePro.Interop.Native;

namespace TablePro.Interop.Tests;

public sealed class NoticeTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-notices-").FullName;
    private readonly TableProCore _core;

    public NoticeTests()
    {
        _core = TableProCore.Create(new HostConfiguration("notice-test", _directory), new MemorySecretStore());
    }

    [Fact]
    public void ANoticeKeepsItsSeverityMessageAndCode()
    {
        var mapped = Mapping.Event(new Native.RunEvent.Notice("WARNING", "w", "01000"));

        Assert.Equal(new QueryEvent.Notice("WARNING", "w", "01000"), mapped);
    }

    [Fact]
    public void TheNoticeLimitKeepsHowManyCameBeforeIt()
    {
        var mapped = Mapping.Event(new Native.RunEvent.NoticeLimitReached(10_000));

        Assert.Equal(new QueryEvent.NoticeLimitReached(10_000), mapped);
    }

    [Fact]
    public async Task APostgresRunPastTheNoticeLimitEndsItsNoticesWithTheLimit()
    {
        Assert.SkipUnless(SshTestEnvironment.Available, "Requires the Windows PostgreSQL fixture.");
        var cancel = TestContext.Current.CancellationToken;
        var saved = await _core.Library.SaveAsync(
            new SavedConnection(null, "PostgreSQL", "postgres", "127.0.0.1", SshTestEnvironment.DatabasePort,
                "tablepro_ssh", "tablepro_ssh", TlsSettings.Disabled),
            new ConnectionSecrets(DatabasePassword: SshTestEnvironment.DatabasePassword));
        await using var session = await _core.ConnectAsync(saved.Id!.Value, cancellationToken: cancel);
        await using var editor = await session.OpenEditorAsync(cancel);

        using var run = editor.Run(
            "DO $$ BEGIN FOR i IN 1..10005 LOOP RAISE NOTICE 'row %', i; END LOOP; END $$",
            cancellationToken: cancel);
        var events = new List<QueryEvent>();
        await foreach (var queryEvent in run.ReadEventsAsync(cancel))
        {
            events.Add(queryEvent);
        }

        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        var notices = events.OfType<QueryEvent.Notice>().ToList();
        Assert.Equal(10_000, notices.Count);
        Assert.Equal(("row 1", "00000"), (notices[0].Message, notices[0].Code));
        var limit = Assert.Single(events.OfType<QueryEvent.NoticeLimitReached>());
        Assert.Equal(10_000, limit.Retained);
        Assert.True(events.IndexOf(limit) > events.IndexOf(notices[^1]));
    }

    public void Dispose()
    {
        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }
}
