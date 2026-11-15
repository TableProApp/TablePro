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
    public async Task AConnectionOpenedInAnotherDatabaseConnectsThereEveryTime()
    {
        var origin = new SessionConnection { ConnectionId = SavedId, Name = "Shop", Database = "analytics" };
        var life = New(origin);

        await life.ConnectAsync();
        await life.DisconnectAsync(keepTabs: true);
        await life.ConnectAsync();

        Assert.Equal<string?>(["analytics", "analytics"], _connector.Databases);
        Assert.True(life.IsSame(origin with { Name = "Renamed" }));
        Assert.False(life.IsSame(origin with { Database = null }));
        Assert.True(life.Matches(SavedId, null), "a database of the connection is still that connection");
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
    public async Task ASessionThatArrivesAfterADisconnectIsClosedAndNeverShown()
    {
        var life = New();
        var cancelled = 0;
        life.Cancelled += (_, _) => cancelled++;
        // The core checks for a cancel only until the server answers, so its session can still come back.
        var arriving = new Gate(honorsCancel: false);
        _connector.Connecting = arriving;

        var connect = life.ConnectAsync();
        await arriving.Reached;
        await life.DisconnectAsync();
        arriving.Open();
        await connect;

        Assert.Equal(1, Assert.Single(_connector.Opened).Disposals);
        Assert.Null(life.Session);
        Assert.Equal(ConnectionState.NotConnected, life.State);
        Assert.DoesNotContain("connected", _view.Shown);
        Assert.Equal(1, cancelled);
    }

    [Fact]
    public async Task ASaveDuringAConnectStartsItOverAndOnlyTheNewSessionShows()
    {
        var life = New();
        var cancelled = 0;
        life.Cancelled += (_, _) => cancelled++;
        var first = new Gate(honorsCancel: false);
        _connector.Connecting = first;

        var connect = life.ConnectAsync();
        await first.Reached;
        _connector.Connecting = null;
        await life.RestartConnectAsync();
        first.Open();
        await connect;

        Assert.Equal(2, _connector.Attempts.Count);
        Assert.Equal(2, _connector.Opened.Count);
        Assert.Same(_connector.Opened[0], life.Session);
        Assert.Equal(0, _connector.Opened[0].Disposals);
        Assert.Equal(1, _connector.Opened[1].Disposals);
        Assert.Equal(ConnectionState.Connected, life.State);
        Assert.Single(_view.Shown, shown => shown == "connected");
        Assert.Equal(0, cancelled);
        Assert.Equal(1, _view.RecoveriesCancelled);
    }

    [Fact]
    public async Task AConnectStartedOverKeepsTheConnectionWhenTheOldOneEndsCancelled()
    {
        var life = New();
        var cancelled = 0;
        life.Cancelled += (_, _) => cancelled++;
        var first = new Gate();
        _connector.Connecting = first;

        var connect = life.ConnectAsync();
        await first.Reached;
        var second = new Gate();
        _connector.Connecting = second;
        var restart = life.RestartConnectAsync();
        await second.Reached;
        await connect;

        Assert.Equal(ConnectionState.Connecting, life.State);
        Assert.Equal(0, cancelled);
        Assert.DoesNotContain("cancelled, tabs kept", _view.Shown);

        second.Open();
        await restart;

        Assert.Equal(ConnectionState.Connected, life.State);
        Assert.Same(Assert.Single(_connector.Opened), life.Session);
    }

    [Fact]
    public async Task ASaveAfterTheUserCancelledLeavesTheConnectCancelled()
    {
        var life = New();
        var cancelled = 0;
        life.Cancelled += (_, _) => cancelled++;
        var arriving = new Gate(honorsCancel: false);
        _connector.Connecting = arriving;

        var connect = life.ConnectAsync();
        await arriving.Reached;
        life.CancelConnect();
        await life.RestartConnectAsync();
        arriving.Open();
        await connect;

        Assert.Single(_connector.Attempts);
        Assert.Equal(1, Assert.Single(_connector.Opened).Disposals);
        Assert.Equal(ConnectionState.NotConnected, life.State);
        Assert.Equal(1, cancelled);
    }

    [Fact]
    public async Task OnlyAConnectUnderWayStartsOver()
    {
        var life = New();

        await life.RestartConnectAsync();

        Assert.Equal(ConnectionState.NotConnected, life.State);
        Assert.Empty(_connector.Attempts);

        await life.ConnectAsync();
        await life.RestartConnectAsync();

        Assert.Single(_connector.Attempts);
        Assert.Equal(0, Assert.Single(_connector.Opened).Disposals);
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
    public async Task ASecretWithNoneSavedIsAskedForAndKeptByTheConnectThatLogsInWithIt()
    {
        _connector.Failures.Enqueue(Errors.Of("keyring.secret_not_stored", SecretKind.SshPassword));
        _view.Answer = _ => new SecretAnswer("typed", Save: true);
        var life = New();

        await life.ConnectAsync();

        Assert.Equal(ConnectionState.Connected, life.State);
        Assert.Equal<ConnectionSecrets>(
            [ConnectionSecrets.None, new ConnectionSecrets(SshPassword: "typed")],
            _connector.Attempts);
        Assert.Equal<ConnectionSecrets>(
            [ConnectionSecrets.None, new ConnectionSecrets(SshPassword: "typed")],
            _connector.Kept);
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
        // The core stores a secret to keep only once it logs in, so the refused one is never stored.
        Assert.Equal(new ConnectionSecrets(DatabasePassword: "wrong"), _connector.Kept[^1]);

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
