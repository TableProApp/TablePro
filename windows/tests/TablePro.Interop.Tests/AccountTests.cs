using System.Net;
using System.Net.Sockets;
using System.Text;

namespace TablePro.Interop.Tests;

// The account against a stand-in for tablepro-cloud on a loopback port; nothing here reaches tablepro.app.
public sealed class AccountTests : IAsyncDisposable
{
    private const string MachineGuid = "d3b07384-d113-4ec6-a2f1-6a3f0c2e9b7a";
    private const string Token = "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK";
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(20);

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-account-").FullName;
    private readonly ItemLog _secrets = new();
    private readonly TableProCore _core;
    private Stub? _cloud;

    public AccountTests()
    {
        _core = TableProCore.Create(new HostConfiguration("test"), _secrets);
    }

    [Fact]
    public async Task ANewMachineStartsSignedOutAndIsToldSo()
    {
        using var account = await OpenAsync(Unreachable(), new RecordingBrowser());

        var first = await FirstChangeAsync(account);
        var limits = await Assert.ThrowsAsync<TableProException>(account.GetShareLimitsAsync);
        var profile = await Assert.ThrowsAsync<TableProException>(account.GetProfileAsync);

        Assert.Equal(AccountState.SignedOut, first.State);
        Assert.Equal(AccountState.SignedOut, account.Status.State);
        Assert.Null(account.Status.Email);
        Assert.Equal(FeatureAccess.SignedOut, account.Access("shared_links"));
        Assert.Equal("account.signed_out", limits.Code);
        Assert.Equal("account.signed_out", profile.Code);
        Assert.Null(_secrets.LoadItem(SecretItem.AccountRefreshToken));
    }

    [Fact]
    public async Task AKeptSignInAsksTheHostForTheRefreshTokenItem()
    {
        await File.WriteAllTextAsync(Path.Combine(_directory, "account.json"), "{}", TestContext.Current.CancellationToken);
        using var account = await OpenAsync(Unreachable(), new RecordingBrowser());

        await FirstChangeAsync(account);

        Assert.Contains(SecretItem.AccountRefreshToken, _secrets.Asked);
        Assert.DoesNotContain(SecretItem.McpToken, _secrets.Asked);
        Assert.Equal(AccountState.SignedOut, account.Status.State);
    }

    [Fact]
    public async Task ASignInOpensTheBrowserForTheWindowsClientAndACancelEndsTheWait()
    {
        var browser = new RecordingBrowser();
        var cloud = Unreachable();
        using var account = await OpenAsync(cloud, browser);
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);

        var signingIn = account.SignInAsync(cancel.Token);
        var opened = await browser.Opened.Task.WaitAsync(Patience, TestContext.Current.CancellationToken);
        await cancel.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => signingIn);
        var query = Uri.UnescapeDataString(opened.Query);
        Assert.Equal(new Uri(cloud).Authority, opened.Authority);
        Assert.Contains("client_id=tablepro-windows", query, StringComparison.Ordinal);
        Assert.Contains("redirect_uri=http://127.0.0.1:", query, StringComparison.Ordinal);
        Assert.Equal(AccountState.SignedOut, account.Status.State);
    }

    [Fact]
    public async Task ABrowserThatDoesNotOpenEndsTheSignInWithItsCode()
    {
        using var account = await OpenAsync(Unreachable(), new RecordingBrowser(opens: false));

        var refused = await Assert.ThrowsAsync<TableProException>(
            () => account.SignInAsync(TestContext.Current.CancellationToken));

        Assert.Equal("account.browser", refused.Code);
    }

    [Fact]
    public async Task ASharedLinkIsReadSignedOutAndAsksForItsPassword()
    {
        _cloud = Stub.Start(request => request switch
        {
            { Path: var path } when path != $"/v2/shared/{Token}" => (404, Problem(404, "not_found")),
            { Password: null } => (401, Problem(401, "share_password_required")),
            { Password: "hunter2" } => (200, """
                {"kind":"query","title":"Orders","note":"","dialect":"sqlite","sql":"SELECT 1",
                "created_at":"2026-11-13T00:00:00Z","allow_download":true,"made_with":"TablePro"}
                """),
            _ => (401, Problem(401, "share_password_wrong")),
        });
        using var account = await OpenAsync(_cloud.Base, new RecordingBrowser());

        var required = await Assert.ThrowsAsync<TableProException>(() => account.FetchSharedAsync(Token));
        var wrong = await Assert.ThrowsAsync<TableProException>(() => account.FetchSharedAsync(Token, "nope"));
        var opened = await account.FetchSharedAsync(Token, "hunter2");
        var gone = await Assert.ThrowsAsync<TableProException>(() => account.FetchSharedAsync(Token[..^1] + "x"));
        var malformed = await Assert.ThrowsAsync<TableProException>(() => account.FetchSharedAsync("short"));

        Assert.Equal("account.share_password_required", required.Code);
        Assert.Equal("account.share_password_wrong", wrong.Code);
        Assert.Equal("SELECT 1", opened.Sql);
        Assert.Equal("Orders", opened.Title);
        Assert.Equal(new DateTimeOffset(2026, 11, 13, 0, 0, 0, TimeSpan.Zero), opened.CreatedAt);
        Assert.Null(opened.ExpiresAt);
        Assert.Equal("account.not_found", gone.Code);
        Assert.Equal("account.not_found", malformed.Code);
        Assert.All(_cloud.Requests, request => Assert.False(request.Authorized));
    }

    [Fact]
    public async Task AMachineGuidThatIsNotAGuidIsRefusedBeforeTheAccountStarts()
    {
        var refused = await Assert.ThrowsAsync<TableProException>(() => _core.OpenAccountAsync(
            Configuration(Unreachable()) with { MachineGuid = "not a guid" },
            new RecordingBrowser()));

        Assert.Equal("account.no_machine_id", refused.Code);
    }

    [Fact]
    public void TheSecretScanNamesEachKindByLineAndTheColumnsThatMayHoldOne()
    {
        var hits = ShareLinks.ScanSql("SELECT 1;\nSELECT 'AKIAIOSFODNN7EXAMPLE', 'postgres://ada:pw@db/app';");
        var columns = ShareLinks.ScanColumns(["id", "api_key", "password", "name"]);

        Assert.Equal([new SecretHit(SecretHitKind.AwsAccessKey, 2), new SecretHit(SecretHitKind.UrlCredentials, 2)], hits);
        Assert.Equal(["api_key", "password"], columns);
        Assert.Empty(ShareLinks.ScanSql("SELECT name FROM people"));
    }

    [Fact]
    public void OnlyAShareLinkWithAWellFormedTokenGivesItsToken()
    {
        Assert.Equal(Token, ShareLinks.TokenFromLink($"tablepro://share?token={Token}"));
        Assert.Null(ShareLinks.TokenFromLink("tablepro://share?token=short"));
        Assert.Null(ShareLinks.TokenFromLink($"https://s.tablepro.app/{Token}"));
        Assert.Null(ShareLinks.TokenFromLink($"tablepro://open?token={Token}"));
    }

    public async ValueTask DisposeAsync()
    {
        if (_cloud is not null)
        {
            await _cloud.DisposeAsync();
        }

        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    private static async Task<AccountStatus> FirstChangeAsync(TableProAccount account)
    {
        using var waiting = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        waiting.CancelAfter(Patience);
        await foreach (var status in account.ReadStatusChangesAsync(waiting.Token))
        {
            return status;
        }

        throw new InvalidOperationException("The account was disposed before it said anything.");
    }

    private static string Problem(int status, string code) =>
        $$"""{"type":"about:blank","title":"Refused","status":{{status}},"code":"{{code}}"}""";

    // Nothing listens once the listener is stopped, so every request is refused.
    private static string Unreachable()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return $"http://127.0.0.1:{port}";
    }

    private Task<TableProAccount> OpenAsync(string cloud, IAccountBrowser browser) =>
        _core.OpenAccountAsync(Configuration(cloud), browser);

    private AccountConfiguration Configuration(string cloud) =>
        new("Lab", "1.0.0", "Windows 11", Path.Combine(_directory, "account.json"), "Done", "Unknown")
        {
            AccountUrl = cloud,
            ApiUrl = cloud + "/v2",
            MachineGuid = MachineGuid,
        };

    // Notes which items the core asks for, so a tag mapped to the wrong item shows.
    private sealed class ItemLog : ISecretStore
    {
        private readonly MemorySecretStore _store = new();
        private readonly Lock _gate = new();
        private readonly List<SecretItem> _asked = [];

        public IReadOnlyList<SecretItem> Asked
        {
            get
            {
                lock (_gate)
                {
                    return [.. _asked];
                }
            }
        }

        public string? Load(Guid connectionId, SecretKind kind) => _store.Load(connectionId, kind);

        public void Store(Guid connectionId, SecretKind kind, string secret, string label) =>
            _store.Store(connectionId, kind, secret, label);

        public void Relabel(Guid connectionId, SecretKind kind, string label) =>
            _store.Relabel(connectionId, kind, label);

        public void Delete(Guid connectionId, SecretKind kind) => _store.Delete(connectionId, kind);

        public void DeleteConnection(Guid connectionId) => _store.DeleteConnection(connectionId);

        public string? LoadItem(SecretItem item)
        {
            lock (_gate)
            {
                _asked.Add(item);
            }

            return _store.LoadItem(item);
        }

        public void StoreItem(SecretItem item, string secret) => _store.StoreItem(item, secret);

        public void DeleteItem(SecretItem item) => _store.DeleteItem(item);
    }

    private sealed class RecordingBrowser(bool opens = true) : IAccountBrowser
    {
        public TaskCompletionSource<Uri> Opened { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<bool> OpenAsync(Uri url)
        {
            Opened.TrySetResult(url);
            return Task.FromResult(opens);
        }
    }

    private sealed record StubRequest(string Path, string? Password, bool Authorized);

    // One request per connection, answered as the core's own tests answer: JSON, then close.
    private sealed class Stub : IAsyncDisposable
    {
        private readonly TcpListener _listener;
        private readonly Func<StubRequest, (int Status, string Body)> _answer;
        private readonly CancellationTokenSource _stop = new();
        private readonly Task _serving;
        private readonly Lock _gate = new();
        private readonly List<StubRequest> _requests = [];

        private Stub(Func<StubRequest, (int Status, string Body)> answer)
        {
            _answer = answer;
            _listener = new TcpListener(IPAddress.Loopback, 0);
            _listener.Start();
            Base = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";
            _serving = ServeAsync();
        }

        public string Base { get; }

        public IReadOnlyList<StubRequest> Requests
        {
            get
            {
                lock (_gate)
                {
                    return [.. _requests];
                }
            }
        }

        public static Stub Start(Func<StubRequest, (int Status, string Body)> answer) => new(answer);

        public async ValueTask DisposeAsync()
        {
            await _stop.CancelAsync();
            _listener.Stop();
            try
            {
                await _serving;
            }
            catch (Exception exception) when (exception is OperationCanceledException or SocketException or ObjectDisposedException)
            {
                // The listener stopped under the accept.
            }

            _stop.Dispose();
        }

        private async Task ServeAsync()
        {
            while (!_stop.IsCancellationRequested)
            {
                using var client = await _listener.AcceptTcpClientAsync(_stop.Token);
                await AnswerAsync(client);
            }
        }

        private async Task AnswerAsync(TcpClient client)
        {
            var stream = client.GetStream();
            using var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
            var line = await reader.ReadLineAsync(_stop.Token) ?? string.Empty;
            var path = line.Split(' ') is [_, var target, ..] ? target : string.Empty;
            string? password = null;
            var authorized = false;
            while (await reader.ReadLineAsync(_stop.Token) is { Length: > 0 } header)
            {
                var colon = header.IndexOf(':', StringComparison.Ordinal);
                var name = colon < 0 ? header : header[..colon].Trim();
                var value = colon < 0 ? string.Empty : header[(colon + 1)..].Trim();
                if (name.Equals("x-share-password", StringComparison.OrdinalIgnoreCase))
                {
                    password = value;
                }
                else if (name.Equals("authorization", StringComparison.OrdinalIgnoreCase))
                {
                    authorized = true;
                }
            }

            var request = new StubRequest(path, password, authorized);
            lock (_gate)
            {
                _requests.Add(request);
            }

            var (status, body) = _answer(request);
            var bytes = Encoding.UTF8.GetBytes(body);
            var head = $"HTTP/1.1 {status} Stub\r\ncontent-type: application/json\r\ncontent-length: {bytes.Length}\r\nconnection: close\r\n\r\n";
            await stream.WriteAsync(Encoding.ASCII.GetBytes(head), _stop.Token);
            await stream.WriteAsync(bytes, _stop.Token);
            await stream.FlushAsync(_stop.Token);
        }
    }
}
