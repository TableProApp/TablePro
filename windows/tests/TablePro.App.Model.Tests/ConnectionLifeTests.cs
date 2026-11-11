using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ConnectionLifeTests
{
    private static readonly Guid SavedId = Guid.NewGuid();
    private readonly FakeConnectionView _view = new();
    private readonly FakeConnector _connector = new();

    [Fact]
    public async Task AConnectionSavedWithTabsShowsThemOnItsFirstSession()
    {
        var origin = new SessionConnection
        {
            ConnectionId = SavedId,
            Name = "Chinook",
            Tabs = [new SessionTab { Kind = TabKind.Query, Title = "Query 1", Sql = "select 1" }],
        };
        var life = New(origin);

        await life.ConnectAsync();

        Assert.Equal(ConnectionState.Connected, life.State);
        Assert.Same(origin, Assert.Single(_view.Restores));
        Assert.Same(Assert.Single(_connector.Opened), life.Session);
        Assert.Equal<string>(
            ["state Connecting", "connecting", "state Connected", "connected"],
            _view.Shown);
    }

    [Fact]
    public async Task AReconnectKeepsTheTabsAndShowsThemOnTheNextSession()
    {
        var life = New();
        await life.ConnectAsync();
        var first = Assert.Single(_connector.Opened);
        _view.Strip = [new SessionTab { Kind = TabKind.Table, Title = "Artist", Table = "Artist" }];

        await life.DisconnectAsync(keepTabs: true);

        Assert.Equal(ConnectionState.NotConnected, life.State);
        Assert.Equal(1, first.Disposals);
        Assert.Equal<bool>([true], _view.Closes);
        Assert.Equal(_view.Strip, life.Snapshot().Tabs);

        await life.ConnectAsync();

        Assert.Equal(2, _connector.Opened.Count);
        Assert.Null(_view.Restores[0]);
        Assert.Equal(_view.Strip, _view.Restores[^1]?.Tabs);
    }

    [Fact]
    public async Task ACancelledReconnectKeepsTheConnectionAndItsTabsToRetry()
    {
        var life = New();
        var cancelled = 0;
        life.Cancelled += (_, _) => cancelled++;
        await life.ConnectAsync();
        _view.Strip = [new SessionTab { Kind = TabKind.Query, Title = "Query 1", Sql = "select 1" }];
        await life.DisconnectAsync(keepTabs: true);
        var connecting = new Gate();
        _connector.Connecting = connecting;

        var reconnect = life.ConnectAsync();
        await connecting.Reached;
        life.CancelConnect();
        await reconnect;

        Assert.Equal(ConnectionState.NotConnected, life.State);
        Assert.Equal(0, cancelled);
        Assert.Contains("cancelled, tabs kept", _view.Shown);

        _connector.Connecting = null;
        await life.ConnectAsync();

        Assert.Equal(ConnectionState.Connected, life.State);
        Assert.Equal(_view.Strip, _view.Restores[^1]?.Tabs);
    }

    [Fact]
    public async Task ACancelledFirstConnectTakesTheConnectionAway()
    {
        var life = New();
        var cancelled = 0;
        life.Cancelled += (_, _) => cancelled++;
        var connecting = new Gate();
        _connector.Connecting = connecting;

        var connect = life.ConnectAsync();
        await connecting.Reached;
        life.CancelConnect();
        await connect;

        Assert.Equal(1, cancelled);
        Assert.Equal(ConnectionState.NotConnected, life.State);
        Assert.DoesNotContain("cancelled, tabs kept", _view.Shown);
        Assert.Empty(_connector.Opened);
    }

    [Fact]
    public async Task DisconnectingTwiceLetsTheSessionGoOnce()
    {
        var life = New();
        await life.ConnectAsync();
        var database = Assert.Single(_connector.Opened);

        await life.DisconnectAsync();
        await life.DisconnectAsync();

        Assert.Equal(1, database.Disposals);
        Assert.Null(life.Session);
        Assert.Equal<bool>([false, false], _view.Closes);
        Assert.Empty(life.Snapshot().Tabs);
    }

    [Fact]
    public async Task AWindowThatAdoptsTheSessionHoldsItUntilBothLetGo()
    {
        var life = New();
        await life.ConnectAsync();
        var database = Assert.Single(_connector.Opened);
        var other = new FakeConnectionView();
        var adopted = new ConnectionLife<FakeDatabase>(life.Origin with { Tabs = [] }, other, _connector);

        adopted.Adopt(life);

        Assert.Equal(ConnectionState.Connected, adopted.State);
        Assert.Same(life.Share, other.Share);
        Assert.Equal(2, life.Share?.Holders);
        Assert.Contains("adopted", other.Shown);
        Assert.Single(_connector.Opened);

        await life.DisconnectAsync();

        Assert.Equal(0, database.Disposals);

        await adopted.DisconnectAsync();

        Assert.Equal(1, database.Disposals);
    }

    [Fact]
    public void OnlyAConnectedConnectionGivesUpItsSession()
    {
        var adopted = New();

        Assert.Throws<InvalidOperationException>(() => adopted.Adopt(New()));
    }

    [Fact]
    public async Task ASecretWithNoneSavedIsAskedForAndSavedOnceTheConnectWorks()
    {
        _connector.Failures.Enqueue(Errors.Of("keyring.secret_not_stored", SecretKind.SshPassword));
        _view.Answer = _ => new SecretAnswer("typed", Save: true);
        var life = New();

        await life.ConnectAsync();

        Assert.Equal(ConnectionState.Connected, life.State);
        Assert.Equal<ConnectionSecrets>(
            [ConnectionSecrets.None, new ConnectionSecrets(SshPassword: "typed")],
            _connector.Attempts);
        Assert.Equal(new ConnectionSecrets(SshPassword: "typed"), Assert.Single(_connector.Saved));
        Assert.Contains("asked SshPassword", _view.Shown);
    }

    [Fact]
    public async Task ASecretRefusedAgainFailsAndAClosedQuestionCancelsTheConnect()
    {
        _connector.Failures.Enqueue(Errors.Of("keyring.secret_not_stored", SecretKind.DatabasePassword));
        _connector.Failures.Enqueue(Errors.Of("keyring.secret_not_stored", SecretKind.DatabasePassword));
        _view.Answer = _ => new SecretAnswer("wrong", Save: true);
        var life = New();
        var cancelled = 0;
        life.Cancelled += (_, _) => cancelled++;

        await life.ConnectAsync();

        Assert.Equal(ConnectionState.Failed, life.State);
        Assert.Contains("failed keyring.secret_not_stored", _view.Shown);
        Assert.Empty(_connector.Saved);

        _view.Answer = _ => null;
        _connector.Failures.Enqueue(Errors.Of("keyring.secret_not_stored"));
        await life.ConnectAsync();

        Assert.Equal(1, cancelled);
        Assert.Equal(ConnectionState.NotConnected, life.State);
    }

    [Fact]
    public async Task AChangedHostKeyIsForgottenOnceAskedAndTheConnectTriedAgain()
    {
        var key = new HostKeyFailure("db.example.com", "ssh-ed25519", "SHA256:abc", "known_hosts", 3, TrustAllowed: true);
        _connector.Failures.Enqueue(Errors.Of("ssh.host_key_changed", hostKey: key));
        _view.ForgetsHostKey = true;
        var life = New();

        await life.ConnectAsync();

        Assert.Equal(ConnectionState.Connected, life.State);
        Assert.Equal(2, _connector.Attempts.Count);
        Assert.Contains("host key db.example.com", _view.Shown);

        _view.ForgetsHostKey = false;
        await life.DisconnectAsync();
        _connector.Failures.Enqueue(Errors.Of("ssh.host_key_changed", hostKey: key));
        await life.ConnectAsync();

        Assert.Equal(ConnectionState.Failed, life.State);
        Assert.Contains("failed ssh.host_key_changed", _view.Shown);
    }

    [Fact]
    public async Task AFileOpensByItsPathAndMatchesItWhateverTheCase()
    {
        var life = New(new SessionConnection { FilePath = @"C:\Data\Chinook.sqlite", Name = "Chinook.sqlite" });

        await life.ConnectAsync();

        Assert.Equal(ConnectionState.Connected, life.State);
        Assert.Empty(_connector.Attempts);
        Assert.True(life.Matches(null, @"c:\data\chinook.sqlite"));
        Assert.False(life.Matches(SavedId, null));
    }

    private ConnectionLife<FakeDatabase> New(SessionConnection? origin = null) => new(
        origin ?? new SessionConnection { ConnectionId = SavedId, Name = "Chinook", EngineId = "sqlite" },
        _view,
        _connector);
}
