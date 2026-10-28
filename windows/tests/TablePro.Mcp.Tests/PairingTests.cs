using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Connections;
using TablePro.Mcp.Audit;
using TablePro.Mcp.Auth;

namespace TablePro.Mcp.Tests;

public sealed class PkceAndScopeTests
{
    [Fact]
    public void ChallengeIsTheUnpaddedBase64UrlSha256OfTheVerifier()
    {
        // RFC 7636, appendix B.
        Assert.Equal("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", McpPkce.ChallengeOf("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
    }

    [Theory]
    [InlineData("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", true)]
    [InlineData("short", false)]
    [InlineData("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjX!", false)]
    [InlineData("dBjftJeZ4CVP mB92K27uhbUJU1p1r_wW1gFWFOEjXk", false)]
    public void VerifierMustBe43To128UnreservedCharacters(string verifier, bool valid)
    {
        Assert.Equal(valid, McpPkce.IsValidVerifier(verifier));
        Assert.False(McpPkce.IsValidVerifier(new string('a', 129)));
        Assert.True(McpPkce.IsValidVerifier(new string('~', 128)));
    }

    [Theory]
    [InlineData("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", true)]
    [InlineData("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM=", false)]
    [InlineData("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw+cM", false)]
    [InlineData("", false)]
    public void ChallengeMustBe43Base64UrlCharacters(string challenge, bool valid) =>
        Assert.Equal(valid, McpPkce.IsValidChallenge(challenge));

    [Theory]
    [InlineData(null, McpClientPermission.ReadOnly)]
    [InlineData("", McpClientPermission.ReadOnly)]
    [InlineData("readwrite", McpClientPermission.ReadWrite)]
    [InlineData("read-write, whatever", McpClientPermission.ReadWrite)]
    [InlineData("full", McpClientPermission.ReadWrite)]
    [InlineData("readwrite readonly", McpClientPermission.ReadOnly)]
    [InlineData("unknown", McpClientPermission.ReadOnly)]
    public void TheLowestNamedLevelWinsAndUnknownEntriesAreSkipped(string? scopes, McpClientPermission expected) =>
        Assert.Equal(expected, McpScopes.Parse(scopes));
}

public sealed class PairingCodeTests
{
    private const string Verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

    [Fact]
    public void AMatchingVerifierReleasesTheTokenOnce()
    {
        var time = new ManualTime();
        var codes = new McpPairingCodes(time);
        var code = codes.Insert(Pending(time), out _)!;

        var first = codes.Consume(code, Verifier, out var record);
        var second = codes.Consume(code, Verifier, out _);

        Assert.Equal(McpCodeOutcome.Exchanged, first);
        Assert.Equal("tp_secret", record!.Token);
        Assert.Equal(McpCodeOutcome.NotFound, second);
    }

    [Fact]
    public void AFailedVerificationBurnsTheCode()
    {
        var time = new ManualTime();
        var codes = new McpPairingCodes(time);
        var code = codes.Insert(Pending(time), out _)!;

        var wrong = codes.Consume(code, new string('x', 43), out _);
        var right = codes.Consume(code, Verifier, out _);

        Assert.Equal(McpCodeOutcome.Mismatch, wrong);
        Assert.Equal(McpCodeOutcome.NotFound, right);
    }

    [Fact]
    public void AnExpiredCodeIsRefusedAndDropped()
    {
        var time = new ManualTime();
        var codes = new McpPairingCodes(time);
        var code = codes.Insert(Pending(time), out _)!;

        time.Advance(McpPairingCodes.ExchangeWindow);

        Assert.Equal(McpCodeOutcome.Expired, codes.Consume(code, Verifier, out _));
        Assert.Equal(0, codes.Count);
    }

    [Fact]
    public void PendingCodesAreCappedAndExpiredOnesMakeRoom()
    {
        var time = new ManualTime();
        var codes = new McpPairingCodes(time);
        for (var i = 0; i < McpPairingCodes.MaxPendingCodes; i++)
        {
            Assert.NotNull(codes.Insert(Pending(time), out _));
        }

        Assert.Null(codes.Insert(Pending(time), out _));
        time.Advance(McpPairingCodes.ExchangeWindow + TimeSpan.FromSeconds(1));
        Assert.NotNull(codes.Insert(Pending(time), out var expired));
        Assert.Equal(McpPairingCodes.MaxPendingCodes, expired.Count);
    }

    [Fact]
    public void TheExchangeWindowIsFiveMinutes() => Assert.Equal(TimeSpan.FromMinutes(5), McpPairingCodes.ExchangeWindow);

    [Fact]
    public void TheLimiterLocksAfterTheLastAllowedFailureAndOpensAgainLater()
    {
        var time = new ManualTime();
        var limiter = new McpFailureLimiter(3, TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(15), time);

        limiter.RecordFailure();
        limiter.RecordFailure();
        Assert.Null(limiter.LockedFor());
        limiter.RecordFailure();
        Assert.Equal(TimeSpan.FromMinutes(15), limiter.LockedFor());
        time.Advance(TimeSpan.FromMinutes(15));
        Assert.Null(limiter.LockedFor());
    }

    [Fact]
    public void FailuresOutsideTheWindowDoNotCount()
    {
        var time = new ManualTime();
        var limiter = new McpFailureLimiter(2, TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(15), time);

        limiter.RecordFailure();
        time.Advance(TimeSpan.FromMinutes(6));
        limiter.RecordFailure();

        Assert.Null(limiter.LockedFor());
    }

    private static McpPendingCode Pending(TimeProvider time) =>
        new(Guid.NewGuid(), "client", "tp_secret", McpClientPermission.ReadOnly, McpPkce.ChallengeOf(Verifier), time.GetLocalNow() + McpPairingCodes.ExchangeWindow);
}

public sealed class PairingFlowTests
{
    private const string Ping = """{"jsonrpc":"2.0","id":1,"method":"ping"}""";

    [Fact]
    public async Task AnApprovedClientExchangesItsCodeForATokenThatWorks()
    {
        await using var harness = await ServerHarness.StartAsync();
        harness.Host.ApprovePairing = (_, _) => Task.FromResult<McpPairingApproval?>(new McpPairingApproval(McpClientPermission.ReadWrite, null, null));
        var verifier = NewVerifier();

        var (pairStatus, pair) = await PostAsync(harness, McpPairingService.PairPath, new JsonObject
        {
            ["client_name"] = "Claude Code",
            ["code_challenge"] = McpPkce.ChallengeOf(verifier),
            ["code_challenge_method"] = "S256",
            ["scopes"] = "readwrite",
        }, authorized: false);
        var (exchangeStatus, exchange) = await PostAsync(harness, McpPairingService.ExchangePath, new JsonObject
        {
            ["code"] = pair.GetProperty("code").GetString(),
            ["code_verifier"] = verifier,
        }, authorized: false);

        Assert.Equal(HttpStatusCode.OK, pairStatus);
        Assert.Equal(300, pair.GetProperty("expires_in").GetInt32());
        Assert.Equal(HttpStatusCode.OK, exchangeStatus);
        var token = exchange.GetProperty("token").GetString()!;
        Assert.StartsWith("tp_", token, StringComparison.Ordinal);
        Assert.Equal("read_write", exchange.GetProperty("scope").GetString());

        var request = Assert.Single(harness.Host.PairingRequests);
        Assert.Equal("Claude Code", request.ClientName);
        Assert.Equal(McpClientPermission.ReadWrite, request.RequestedPermission);
        Assert.Null(request.RequestedConnectionIds);

        harness.Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var ping = ServerHarness.Post(Ping);
        using var pingResponse = await harness.Http.SendAsync(ping, TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.OK, pingResponse.StatusCode);

        // The host keeps the hash and a short prefix, never the token.
        var saved = Assert.Single(harness.Host.SavedClients.Values);
        Assert.Equal("Claude Code", saved.Name);
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(token))), saved.TokenHash);
        Assert.DoesNotContain(token, saved.ToString(), StringComparison.Ordinal);
        Assert.StartsWith(saved.TokenPrefix, token, StringComparison.Ordinal);
        Assert.True(saved.TokenPrefix.Length < token.Length / 2);

        var actions = harness.Server.AuditLog.Snapshot().Select(e => e.Tool).ToArray();
        Assert.Contains("client.created", actions);
        Assert.Contains("pairing.approved", actions);
        Assert.Contains("pairing.exchange", actions);
        Assert.All(harness.Server.AuditLog.Snapshot().Where(e => e.Tool.StartsWith("pairing.", StringComparison.Ordinal)), e => Assert.Equal(saved.Id, e.ClientId));
    }

    [Fact]
    public async Task ARevokedClientIsTurnedAwayAtItsNextRequest()
    {
        await using var harness = await ServerHarness.StartAsync();
        var issued = await harness.Server.Clients.IssueAsync("Cursor", McpClientPermission.ReadOnly, null, null, TestContext.Current.CancellationToken);
        harness.Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", issued.Token);

        using var before = ServerHarness.Post(Ping);
        using var beforeResponse = await harness.Http.SendAsync(before, TestContext.Current.CancellationToken);
        Assert.True(await harness.Server.Clients.RevokeAsync(issued.Grant.Id, TestContext.Current.CancellationToken));
        using var after = ServerHarness.Post(Ping);
        using var afterResponse = await harness.Http.SendAsync(after, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.OK, beforeResponse.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, afterResponse.StatusCode);
        Assert.NotNull(harness.Host.SavedClients[issued.Grant.Id].RevokedAt);
        Assert.True(Assert.Single(harness.Server.Clients.Clients).IsRevoked);
        var refusal = harness.Server.AuditLog.Snapshot()[^1];
        Assert.Equal(McpAuditOutcome.Unauthorized, refusal.Outcome);
        Assert.Equal(issued.Grant.Id, refusal.ClientId);
        Assert.Contains("revoked", refusal.Message, StringComparison.Ordinal);
        Assert.Contains(harness.Server.AuditLog.Snapshot(), e => e is { Tool: "client.revoked", Category: McpAuditCategory.Admin });
    }

    [Fact]
    public async Task AnExpiredClientTokenIsRefused()
    {
        var time = new ManualTime();
        await using var harness = await ServerHarness.StartAsync(configure: o => o with { Time = time });
        var issued = await harness.Server.Clients.IssueAsync("Zed", McpClientPermission.ReadOnly, null, time.GetLocalNow().AddDays(30), TestContext.Current.CancellationToken);
        harness.Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", issued.Token);

        time.Advance(TimeSpan.FromDays(30));
        using var request = ServerHarness.Post(Ping);
        using var response = await harness.Http.SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        Assert.Contains("expired", harness.Server.AuditLog.Snapshot()[^1].Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ADeclinedPairingGetsNoCodeAndRepeatedRefusalsPausePairing()
    {
        await using var harness = await ServerHarness.StartAsync();
        var body = new JsonObject { ["client_name"] = "Spam", ["code_challenge"] = McpPkce.ChallengeOf(NewVerifier()) };

        var statuses = new List<HttpStatusCode>();
        for (var i = 0; i < 3; i++)
        {
            statuses.Add((await PostAsync(harness, McpPairingService.PairPath, body, authorized: false)).Status);
        }

        using var locked = ServerHarness.Post(body.ToJsonString(), McpPairingService.PairPath);
        harness.Http.DefaultRequestHeaders.Authorization = null;
        using var lockedResponse = await harness.Http.SendAsync(locked, TestContext.Current.CancellationToken);

        Assert.All(statuses, s => Assert.Equal(HttpStatusCode.Forbidden, s));
        Assert.Equal((HttpStatusCode)429, lockedResponse.StatusCode);
        Assert.True(lockedResponse.Headers.RetryAfter?.Delta > TimeSpan.FromMinutes(9));
        Assert.Equal(3, harness.Host.PairingRequests.Count);
        Assert.Empty(harness.Host.SavedClients);
        Assert.Equal(3, harness.Server.AuditLog.Snapshot().Count(e => e.Tool == "pairing.denied"));
    }

    [Fact]
    public async Task OnlyOnePairingQuestionIsOpenAtATime()
    {
        await using var harness = await ServerHarness.StartAsync();
        var answer = new TaskCompletionSource<McpPairingApproval?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var asked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        harness.Host.ApprovePairing = (_, _) =>
        {
            asked.TrySetResult();
            return answer.Task;
        };
        var body = new JsonObject { ["client_name"] = "First", ["code_challenge"] = McpPkce.ChallengeOf(NewVerifier()) };

        var first = PostAsync(harness, McpPairingService.PairPath, body, authorized: false);
        await asked.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        var (secondStatus, second) = await PostAsync(harness, McpPairingService.PairPath, body, authorized: false);
        answer.SetResult(new McpPairingApproval(McpClientPermission.ReadOnly, null, null));
        var (firstStatus, _) = await first;

        Assert.Equal((HttpStatusCode)429, secondStatus);
        Assert.Equal("pairing_busy", second.GetProperty("error").GetString());
        Assert.Equal(HttpStatusCode.OK, firstStatus);
    }

    [Fact]
    public async Task AnUnansweredQuestionTimesOutAsADecline()
    {
        await using var harness = await ServerHarness.StartAsync(configure: o => o with { PairingApprovalTimeout = TimeSpan.FromMilliseconds(100) });
        harness.Host.ApprovePairing = async (_, ct) =>
        {
            await Task.Delay(Timeout.Infinite, ct);
            return null;
        };

        var (status, body) = await PostAsync(harness, McpPairingService.PairPath, new JsonObject { ["client_name"] = "Slow", ["code_challenge"] = McpPkce.ChallengeOf(NewVerifier()) }, authorized: false);

        Assert.Equal(HttpStatusCode.Forbidden, status);
        Assert.Equal("access_denied", body.GetProperty("error").GetString());
        Assert.Null(harness.Server.Pairing.Refusals.LockedFor());
    }

    [Theory]
    [InlineData("""{"code_challenge":"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"}""")]
    [InlineData("""{"client_name":"x","code_challenge":"plain"}""")]
    [InlineData("""{"client_name":"x","code_challenge":"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM","code_challenge_method":"plain"}""")]
    [InlineData("""{"client_name":"x","code_challenge":"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM","connection_ids":["not-a-guid"]}""")]
    [InlineData("""{"client_name":"x","code_challenge":"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM","connection_ids":""}""")]
    [InlineData("""{"client_name":"a\u0007b","code_challenge":"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"}""")]
    [InlineData("""not json""")]
    public async Task AMalformedPairingRequestNeverReachesTheUser(string json)
    {
        await using var harness = await ServerHarness.StartAsync();
        harness.Http.DefaultRequestHeaders.Authorization = null;

        using var request = ServerHarness.Post(json, McpPairingService.PairPath);
        using var response = await harness.Http.SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Empty(harness.Host.PairingRequests);
    }

    [Fact]
    public async Task NamedConnectionsReachTheQuestionAndAnEmptyListMeansNone()
    {
        await using var harness = await ServerHarness.StartAsync();
        var id = Guid.NewGuid();

        await PostAsync(harness, McpPairingService.PairPath, new JsonObject { ["client_name"] = "Scoped", ["code_challenge"] = McpPkce.ChallengeOf(NewVerifier()), ["connection_ids"] = new JsonArray(id.ToString()) }, authorized: false);
        await PostAsync(harness, McpPairingService.PairPath, new JsonObject { ["client_name"] = "None", ["code_challenge"] = McpPkce.ChallengeOf(NewVerifier()), ["connection_ids"] = new JsonArray() }, authorized: false);

        Assert.Equal([id], harness.Host.PairingRequests[0].RequestedConnectionIds);
        Assert.Empty(harness.Host.PairingRequests[1].RequestedConnectionIds!);
    }

    [Fact]
    public async Task AWebPageCannotRaiseAPairingQuestion()
    {
        await using var harness = await ServerHarness.StartAsync();
        harness.Http.DefaultRequestHeaders.Authorization = null;

        using var request = ServerHarness.Post(new JsonObject { ["client_name"] = "Evil", ["code_challenge"] = McpPkce.ChallengeOf(NewVerifier()) }.ToJsonString(), McpPairingService.PairPath);
        request.Headers.TryAddWithoutValidation("Origin", "https://evil.example");
        using var response = await harness.Http.SendAsync(request, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
        Assert.Empty(harness.Host.PairingRequests);
    }

    [Fact]
    public async Task AWrongVerifierBurnsTheCodeAndRepeatedMissesLockTheExchange()
    {
        await using var harness = await ServerHarness.StartAsync();
        harness.Host.ApprovePairing = (_, _) => Task.FromResult<McpPairingApproval?>(new McpPairingApproval(McpClientPermission.ReadOnly, null, null));
        var verifier = NewVerifier();
        var (_, pair) = await PostAsync(harness, McpPairingService.PairPath, new JsonObject { ["client_name"] = "Victim", ["code_challenge"] = McpPkce.ChallengeOf(verifier) }, authorized: false);
        var code = pair.GetProperty("code").GetString();

        var (wrong, _) = await PostAsync(harness, McpPairingService.ExchangePath, new JsonObject { ["code"] = code, ["code_verifier"] = NewVerifier() }, authorized: false);
        var (late, _) = await PostAsync(harness, McpPairingService.ExchangePath, new JsonObject { ["code"] = code, ["code_verifier"] = verifier }, authorized: false);
        for (var i = 0; i < 3; i++)
        {
            await PostAsync(harness, McpPairingService.ExchangePath, new JsonObject { ["code"] = "guess" + i, ["code_verifier"] = verifier }, authorized: false);
        }

        var (locked, lockedBody) = await PostAsync(harness, McpPairingService.ExchangePath, new JsonObject { ["code"] = "another", ["code_verifier"] = verifier }, authorized: false);

        Assert.Equal(HttpStatusCode.Forbidden, wrong);
        Assert.Equal(HttpStatusCode.NotFound, late);
        Assert.Equal((HttpStatusCode)429, locked);
        Assert.Equal("rate_limited", lockedBody.GetProperty("error").GetString());
    }

    [Fact]
    public async Task AnUncollectedCodeTakesItsGrantWithItWhenItExpires()
    {
        var time = new ManualTime();
        await using var harness = await ServerHarness.StartAsync(configure: o => o with { Time = time });
        harness.Host.ApprovePairing = (_, _) => Task.FromResult<McpPairingApproval?>(new McpPairingApproval(McpClientPermission.ReadOnly, null, null));
        var verifier = NewVerifier();
        var (_, pair) = await PostAsync(harness, McpPairingService.PairPath, new JsonObject { ["client_name"] = "Abandoned", ["code_challenge"] = McpPkce.ChallengeOf(verifier) }, authorized: false);
        Assert.Single(harness.Host.SavedClients);

        time.Advance(McpPairingCodes.ExchangeWindow);
        var (status, _) = await PostAsync(harness, McpPairingService.ExchangePath, new JsonObject { ["code"] = pair.GetProperty("code").GetString(), ["code_verifier"] = verifier }, authorized: false);

        Assert.Equal(HttpStatusCode.Gone, status);
        Assert.Empty(harness.Host.SavedClients);
        Assert.Empty(harness.Server.Clients.Clients);
    }

    [Fact]
    public async Task TheMcpEndpointStillNeedsATokenAndThePairingEndpointsServeOnlyPost()
    {
        await using var harness = await ServerHarness.StartAsync();
        harness.Http.DefaultRequestHeaders.Authorization = null;

        using var get = await harness.Http.GetAsync(new Uri(McpPairingService.PairPath, UriKind.Relative), TestContext.Current.CancellationToken);
        using var mcp = ServerHarness.Post(Ping);
        using var mcpResponse = await harness.Http.SendAsync(mcp, TestContext.Current.CancellationToken);

        Assert.Equal(HttpStatusCode.MethodNotAllowed, get.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, mcpResponse.StatusCode);
    }

    internal static string NewVerifier()
    {
        Span<byte> bytes = stackalloc byte[32];
        RandomNumberGenerator.Fill(bytes);
        return System.Buffers.Text.Base64Url.EncodeToString(bytes);
    }

    private static async Task<(HttpStatusCode Status, JsonElement Body)> PostAsync(ServerHarness harness, string path, JsonObject body, bool authorized)
    {
        using var request = ServerHarness.Post(body.ToJsonString(), path);
        if (!authorized)
        {
            request.Headers.Authorization = null;
            harness.Http.DefaultRequestHeaders.Authorization = null;
        }

        using var response = await harness.Http.SendAsync(request, TestContext.Current.CancellationToken);
        var text = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        Assert.Equal("no-store", response.Headers.CacheControl?.ToString());
        return (response.StatusCode, JsonDocument.Parse(text).RootElement.Clone());
    }
}

public sealed class ClientGrantTests
{
    [Fact]
    public async Task AGrantNamingConnectionsHidesTheOthers()
    {
        await using var harness = await ServerHarness.StartAsync();
        var analytics = ServerHarness.Profile("Analytics", ExternalAccessLevel.ReadOnly);
        var billing = ServerHarness.Profile("Billing", ExternalAccessLevel.ReadWrite);
        harness.Host.Add(analytics);
        harness.Host.Add(billing);
        var issued = await harness.Server.Clients.IssueAsync("Scoped", McpClientPermission.ReadWrite, [analytics.Id], null, TestContext.Current.CancellationToken);
        harness.Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", issued.Token);

        var list = await harness.CallAsync("list_connections");
        var hidden = await harness.CallAsync("list_schemas", new JsonObject { ["connection_id"] = billing.Id.ToString() });

        Assert.Equal(["Analytics"], list.Json.GetProperty("connections").EnumerateArray().Select(c => c.GetProperty("name").GetString()));
        Assert.True(hidden.IsError);
        Assert.StartsWith("not_found:", hidden.Text, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AReadOnlyGrantCapsAReadWriteConnection()
    {
        await using var harness = await ServerHarness.StartAsync();
        var billing = ServerHarness.Profile("Billing", ExternalAccessLevel.ReadWrite);
        var session = harness.Host.Add(billing);
        harness.Host.Approve = (_, _) => Task.FromResult(true);
        var issued = await harness.Server.Clients.IssueAsync("Reader", McpClientPermission.ReadOnly, null, null, TestContext.Current.CancellationToken);
        harness.Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", issued.Token);

        var list = await harness.CallAsync("list_connections");
        var write = await harness.CallAsync("execute_query", new JsonObject { ["connection_id"] = billing.Id.ToString(), ["query"] = "DELETE FROM users" });

        Assert.Equal("read_only", list.Json.GetProperty("connections")[0].GetProperty("external_access").GetString());
        Assert.True(write.IsError);
        Assert.StartsWith("denied:", write.Text, StringComparison.Ordinal);
        Assert.Empty(session.Executed);
        Assert.Empty(harness.Host.ApprovalRequests);
        var entry = harness.Server.AuditLog.Snapshot()[^1];
        Assert.Equal(issued.Grant.Id, entry.ClientId);
        Assert.Equal("Reader", entry.ClientName);
    }

    [Fact]
    public async Task TheWriteQuestionNamesTheClientThatAsks()
    {
        await using var harness = await ServerHarness.StartAsync();
        var billing = ServerHarness.Profile("Billing", ExternalAccessLevel.ReadWrite);
        harness.Host.Add(billing);
        var issued = await harness.Server.Clients.IssueAsync("Cursor", McpClientPermission.ReadWrite, null, null, TestContext.Current.CancellationToken);
        harness.Http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", issued.Token);

        await harness.CallAsync("execute_query", new JsonObject { ["connection_id"] = billing.Id.ToString(), ["query"] = "DELETE FROM users" });

        Assert.Equal("Cursor", Assert.Single(harness.Host.ApprovalRequests).ClientName);
    }

    [Fact]
    public async Task TheSettingsTokenKeepsItsFullReach()
    {
        await using var harness = await ServerHarness.StartAsync();
        harness.Host.Add(ServerHarness.Profile("Billing", ExternalAccessLevel.ReadWrite));

        var list = await harness.CallAsync("list_connections");

        Assert.Equal("read_write", list.Json.GetProperty("connections")[0].GetProperty("external_access").GetString());
        var entry = harness.Server.AuditLog.Snapshot()[^1];
        Assert.Equal(McpPrincipal.Owner.Name, entry.ClientName);
        Assert.Null(entry.ClientId);
    }

    [Fact]
    public void ApplyLowersOnlyAReadWriteLevel()
    {
        var reader = new McpPrincipal(Guid.NewGuid(), "r", McpClientPermission.ReadOnly, null);
        var blocked = ServerHarness.Profile("b", ExternalAccessLevel.Blocked);
        var readOnly = ServerHarness.Profile("o", ExternalAccessLevel.ReadOnly);

        Assert.Equal(ExternalAccessLevel.Blocked, reader.Apply(blocked)!.ExternalAccess);
        Assert.Same(readOnly, reader.Apply(readOnly));
        Assert.Equal(ExternalAccessLevel.ReadOnly, reader.Apply(ServerHarness.Profile("w", ExternalAccessLevel.ReadWrite))!.ExternalAccess);
    }
}

public sealed class ClientRegistryTests
{
    [Fact]
    public async Task GrantsSurviveAReloadFromTheHost()
    {
        var host = new FakeHost();
        using var first = new McpClientRegistry(host);
        var issued = await first.IssueAsync("Claude Desktop", McpClientPermission.ReadWrite, [Guid.Empty], DateTimeOffset.Now.AddDays(90), TestContext.Current.CancellationToken);

        using var second = new McpClientRegistry(host);
        await second.ReloadAsync(TestContext.Current.CancellationToken);
        var (grant, failure) = await second.AuthenticateAsync("Bearer " + issued.Token, TestContext.Current.CancellationToken);

        Assert.Null(failure);
        Assert.Equal(issued.Grant.Id, grant!.Id);
        Assert.Equal([Guid.Empty], grant.ConnectionIds);
    }

    [Fact]
    public async Task TheLastUseIsSavedAtMostOnceAMinute()
    {
        var time = new ManualTime();
        var host = new FakeHost();
        using var registry = new McpClientRegistry(host, time: time);
        var issued = await registry.IssueAsync("Busy", McpClientPermission.ReadOnly, null, null, TestContext.Current.CancellationToken);
        var saves = host.ClientSaves;

        for (var i = 0; i < 10; i++)
        {
            await registry.AuthenticateAsync("Bearer " + issued.Token, TestContext.Current.CancellationToken);
        }

        var afterBurst = host.ClientSaves;
        time.Advance(McpClientRegistry.LastUsedSaveInterval);
        await registry.AuthenticateAsync("Bearer " + issued.Token, TestContext.Current.CancellationToken);

        Assert.Equal(saves + 1, afterBurst);
        Assert.Equal(saves + 2, host.ClientSaves);
        Assert.Equal(time.GetLocalNow(), host.SavedClients[issued.Grant.Id].LastUsedAt);
    }

    [Fact]
    public async Task DeletingForgetsTheGrantAndItsToken()
    {
        var host = new FakeHost();
        var audit = new List<McpAuditEntry>();
        using var registry = new McpClientRegistry(host, e =>
        {
            audit.Add(e);
            return ValueTask.CompletedTask;
        });
        var issued = await registry.IssueAsync("Gone", McpClientPermission.ReadOnly, null, null, TestContext.Current.CancellationToken);

        Assert.True(await registry.DeleteAsync(issued.Grant.Id, TestContext.Current.CancellationToken));
        var (_, failure) = await registry.AuthenticateAsync("Bearer " + issued.Token, TestContext.Current.CancellationToken);

        Assert.Empty(host.SavedClients);
        Assert.Equal(McpAuthFailure.Unknown, failure);
        Assert.False(await registry.DeleteAsync(issued.Grant.Id, TestContext.Current.CancellationToken));
        Assert.Equal(["client.created", "client.deleted"], audit.Select(e => e.Tool));
    }

    [Fact]
    public async Task TwoClientsWithTheSameNameKeepSeparateTokens()
    {
        var host = new FakeHost();
        using var registry = new McpClientRegistry(host);
        var first = await registry.IssueAsync("Claude Code", McpClientPermission.ReadOnly, null, null, TestContext.Current.CancellationToken);
        var second = await registry.IssueAsync("Claude Code", McpClientPermission.ReadOnly, null, null, TestContext.Current.CancellationToken);

        await registry.RevokeAsync(second.Grant.Id, TestContext.Current.CancellationToken);
        var (grant, failure) = await registry.AuthenticateAsync("Bearer " + first.Token, TestContext.Current.CancellationToken);

        Assert.NotEqual(first.Token, second.Token);
        Assert.Null(failure);
        Assert.Equal(first.Grant.Id, grant!.Id);
    }

    [Fact]
    public async Task AGrantWhoseHashTheVaultLostAuthorizesNothing()
    {
        var host = new FakeHost();
        var id = Guid.NewGuid();
        host.SavedClients[id] = new McpClientGrant { Id = id, Name = "Orphan", TokenHash = null };
        using var registry = new McpClientRegistry(host);
        await registry.ReloadAsync(TestContext.Current.CancellationToken);

        Assert.False(Assert.Single(registry.Clients).IsActive(DateTimeOffset.Now));
        Assert.Equal(McpAuthFailure.Unknown, (await registry.AuthenticateAsync("Bearer tp_anything", TestContext.Current.CancellationToken)).Failure);
    }
}

public sealed class AuditPersistenceTests
{
    [Fact]
    public async Task EveryEntryReachesTheHostInOrderWithTheDigestOfTheWholeStatement()
    {
        await using var harness = await ServerHarness.StartAsync();
        var profile = ServerHarness.Profile("Analytics", ExternalAccessLevel.ReadOnly);
        harness.Host.Add(profile);
        var longQuery = "SELECT '" + new string('x', 3_000) + "'";

        await harness.CallAsync("list_connections");
        await harness.CallAsync("execute_query", new JsonObject { ["connection_id"] = profile.Id.ToString(), ["query"] = longQuery });
        await harness.Server.FlushAuditAsync(TestContext.Current.CancellationToken);

        Assert.Equal(["list_connections", "execute_query"], harness.Host.Audit.Select(e => e.Tool));
        var executed = harness.Host.Audit[1];
        Assert.Equal(McpAuditEntry.Digest(longQuery), executed.SqlDigest);
        Assert.True(executed.Sql!.Length < longQuery.Length);
        Assert.Null(harness.Host.Audit[0].SqlDigest);
    }

    [Fact]
    public async Task AFailingStoreNeitherFailsTheCallNorStopsLaterEntries()
    {
        var host = new FakeHost { AuditFailure = new IOException("disk full") };
        await using var harness = await ServerHarness.StartAsync(host);

        var first = await harness.CallAsync("list_connections");
        var second = await harness.CallAsync("list_connections");
        await harness.Server.FlushAuditAsync(TestContext.Current.CancellationToken);

        Assert.False(first.IsError);
        Assert.False(second.IsError);
        Assert.Equal(2, host.AuditAttempts);
        Assert.Equal(2, harness.Server.AuditLog.Count);
    }

    [Fact]
    public async Task AnUnreadableClientStoreStillLetsTheSettingsTokenIn()
    {
        var host = new FakeHost { ClientsFailure = new IOException("vault locked") };
        await using var harness = await ServerHarness.StartAsync(host);

        var list = await harness.CallAsync("list_connections");

        Assert.False(list.IsError);
        Assert.Empty(harness.Server.Clients.Clients);
    }
}
