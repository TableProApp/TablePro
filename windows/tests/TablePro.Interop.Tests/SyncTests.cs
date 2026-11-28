namespace TablePro.Interop.Tests;

// Sync over a core with storage and no sign-in, so nothing reaches a server: TablePro Sync answers why it cannot run.
public sealed class SyncTests : IDisposable
{
    private static readonly SyncCategories Everything = new([], Passwords: false);

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-sync-").FullName;
    private readonly TableProCore _core;

    public SyncTests()
    {
        _core = TableProCore.Create(
            new HostConfiguration("test", Path.Combine(_directory, "storage")),
            new MemorySecretStore());
    }

    public void Dispose()
    {
        _core.Dispose();
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
            // Sync opens the history and saved queries' databases, which close on the core's own threads and can
            // still hold them here on Windows, as HistoryTests finds.
        }
    }

    [Fact]
    public async Task APcThatIsOffSaysSoAndKeepsNoServiceAccount()
    {
        using var sync = await _core.OpenSyncAsync(new SyncConfiguration(SyncProvider.Off, Everything), account: null);

        Assert.Equal(SyncStatus.Off, sync.Status);
        Assert.Empty(sync.Scopes);
        Assert.Null(sync.ServiceAccount);
    }

    [Fact]
    public async Task TableProSyncWithNoSignInIsUnavailableWithItsReason()
    {
        var configuration = new SyncConfiguration(SyncProvider.TableProSync, new SyncCategories(["saved_query"], true))
        {
            ServiceAccount = null,
        };
        using var sync = await _core.OpenSyncAsync(configuration, account: null);

        var status = sync.Status;
        var plan = await Assert.ThrowsAsync<TableProException>(sync.PlanUploadAsync);
        var keys = await Assert.ThrowsAsync<TableProException>(sync.GetKeyStateAsync);

        Assert.Equal(SyncPhase.Unavailable, status.Phase);
        Assert.StartsWith("sync.", status.Problem, StringComparison.Ordinal);
        Assert.Null(status.LastPass);
        Assert.StartsWith("sync.", plan.Code, StringComparison.Ordinal);
        Assert.StartsWith("sync.", keys.Code, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheCategoriesAndTheHistoryWindowAreTakenWhileOff()
    {
        using var sync = await _core.OpenSyncAsync(new SyncConfiguration(SyncProvider.Off, Everything), account: null);

        await sync.SetCategoriesAsync(new SyncCategories(["saved_query", "saved_query_folder"], Passwords: true));
        sync.SetHistoryWindow(1_000);
        sync.SetHistoryWindow(null);

        Assert.Throws<ArgumentOutOfRangeException>(() => sync.SetHistoryWindow(-1));
        Assert.Equal(SyncPhase.Off, sync.Status.Phase);
    }

    [Fact]
    public async Task OnlyOneReaderFollowsTheChangesAndDisposingEndsIt()
    {
        using var sync = await _core.OpenSyncAsync(new SyncConfiguration(SyncProvider.Off, Everything), account: null);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));

        var reading = ReadAllAsync(sync, timeout.Token);
        await using var second = sync.ReadChangesAsync(timeout.Token).GetAsyncEnumerator(timeout.Token);
        await Assert.ThrowsAsync<InvalidOperationException>(async () => await second.MoveNextAsync());
        sync.Dispose();

        Assert.DoesNotContain(SyncChanges.None, await reading);
    }

    [Fact]
    public async Task AnUploadIsRefusedWithoutASignInAndTurningOffIsNot()
    {
        using var sync = await _core.OpenSyncAsync(new SyncConfiguration(SyncProvider.Off, Everything), account: null);

        var upload = await Assert.ThrowsAsync<TableProException>(
            () => sync.ChooseProviderAsync(SyncProvider.TableProSync));
        await sync.ChooseProviderAsync(SyncProvider.Off);

        Assert.StartsWith("sync.", upload.Code, StringComparison.Ordinal);
        Assert.Null(await sync.GetOpenUploadAsync());
    }

    [Fact]
    public async Task KeyCallsNameTheirDraftsAndNeedASignIn()
    {
        using var sync = await _core.OpenSyncAsync(new SyncConfiguration(SyncProvider.Off, Everything), account: null);

        var malformed = Assert.Throws<TableProException>(() => sync.DiscardKeyDraft("not-a-draft"));
        sync.DiscardKeyDraft(Guid.NewGuid().ToString().ToUpperInvariant());
        var request = await Assert.ThrowsAsync<TableProException>(sync.RequestApprovalAsync);
        var devices = await Assert.ThrowsAsync<TableProException>(sync.GetAccountDevicesAsync);

        Assert.Equal("sync.malformed", malformed.Code);
        Assert.StartsWith("sync.", request.Code, StringComparison.Ordinal);
        Assert.StartsWith("sync.", devices.Code, StringComparison.Ordinal);
    }

    private static async Task<List<SyncChanges>> ReadAllAsync(TableProSync sync, CancellationToken cancellationToken)
    {
        var seen = new List<SyncChanges>();
        await foreach (var changes in sync.ReadChangesAsync(cancellationToken))
        {
            seen.Add(changes);
        }

        return seen;
    }
}
