using TablePro.Interop;

namespace TablePro.App.Model.Tests;

internal sealed class FakeDatabase : IAsyncDisposable
{
    public int Disposals { get; private set; }

    public ValueTask DisposeAsync()
    {
        Disposals++;
        return ValueTask.CompletedTask;
    }
}

internal sealed class FakeConnector : IConnector<FakeDatabase>
{
    public List<FakeDatabase> Opened { get; } = [];

    public List<ConnectionSecrets> Attempts { get; } = [];

    public List<ConnectionSecrets> Saved { get; } = [];

    // Each connect takes the next failure, until none is left.
    public Queue<CoreError> Failures { get; } = new();

    public Gate? Connecting { get; set; }

    public async Task<FakeDatabase> ConnectSavedAsync(
        Guid id,
        ConnectionSecrets secrets,
        CancellationToken cancellationToken)
    {
        Attempts.Add(secrets);
        return await OpenAsync(cancellationToken);
    }

    public Task<FakeDatabase> OpenFileAsync(string path, string? engineId, CancellationToken cancellationToken) =>
        OpenAsync(cancellationToken);

    public Task SaveSecretsAsync(Guid id, ConnectionSecrets secrets)
    {
        Saved.Add(secrets);
        return Task.CompletedTask;
    }

    private async Task<FakeDatabase> OpenAsync(CancellationToken cancellationToken)
    {
        if (Connecting is { } connecting)
        {
            await connecting.PassAsync(cancellationToken);
        }

        if (Failures.TryDequeue(out var failure))
        {
            throw new TableProException(failure);
        }

        var database = new FakeDatabase();
        Opened.Add(database);
        return database;
    }
}

// The workspace a connection shows: its strip is the truth once connected, as WorkspaceView.Snapshot says.
internal sealed class FakeConnectionView : IConnectionView<FakeDatabase>
{
    public List<string> Shown { get; } = [];

    public List<SessionConnection?> Restores { get; } = [];

    public List<bool> Closes { get; } = [];

    public SessionShare<FakeDatabase>? Share { get; private set; }

    public IReadOnlyList<SessionTab> Strip { get; set; } = [];

    public Func<SecretKind, SecretAnswer?> Answer { get; set; } = _ => null;

    public bool ForgetsHostKey { get; set; }

    public int RecoveriesCancelled { get; private set; }

    public void ShowState(ConnectionState state) => Shown.Add($"state {state}");

    public void ShowConnecting() => Shown.Add("connecting");

    public void ShowConnected(SessionShare<FakeDatabase> share, SessionConnection? restore, bool adopted)
    {
        Share = share;
        Restores.Add(restore);
        Shown.Add(adopted ? "adopted" : "connected");
    }

    public void ShowFailed(CoreError failure) => Shown.Add("failed " + failure.Code);

    public void ShowCancelledKeepsTabs() => Shown.Add("cancelled, tabs kept");

    public Task<SecretAnswer?> AskSecretAsync(SecretKind kind, CancellationToken cancellationToken)
    {
        Shown.Add($"asked {kind}");
        return Task.FromResult(Answer(kind));
    }

    public Task<bool> RecoverHostKeyAsync(Guid id, HostKeyFailure failure, CancellationToken cancellationToken)
    {
        Shown.Add("host key " + failure.Host);
        return Task.FromResult(ForgetsHostKey);
    }

    public void CancelRecovery() => RecoveriesCancelled++;

    public Task CloseTabsAsync(bool keepClosed)
    {
        Closes.Add(keepClosed);
        Share = null;
        return Task.CompletedTask;
    }

    public SessionConnection Snapshot(SessionConnection origin) =>
        Share is null ? origin : origin with { Tabs = Strip };
}
