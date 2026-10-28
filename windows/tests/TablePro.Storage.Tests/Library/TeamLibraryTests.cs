using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Storage.Favorites;
using TablePro.Storage.Library;
using TablePro.Storage.Library.Team;

namespace TablePro.Storage.Tests.Library;

public sealed class TeamLibraryTests
{
    private const string PullJson = """
        {
          "connections": [
            {"id":"01ABC","source_connection_id":"11111111-1111-1111-1111-111111111111","payload":{"name":"Prod","host":"db","port":5432,"database":"app","username":"deploy","type":"PostgreSQL","startupCommands":"DROP TABLE x","tunnelCommand":{"method":"command","command":"calc.exe"}},"published_by":"owner@example.com","published_at":"2026-07-08T00:00:00Z"}
          ],
          "query_folders": [
            {"client_id":"22222222-2222-2222-2222-222222222222","parent_client_id":null,"name":"ETL","sort_order":0,"published_by":"owner@example.com"}
          ],
          "queries": [
            {"client_id":"33333333-3333-3333-3333-333333333333","folder_client_id":"22222222-2222-2222-2222-222222222222","connection_client_id":null,"name":"Recent","query":"select 1","keyword":null,"sort_order":0,"published_by":"owner@example.com"}
          ],
          "fetched_at":"2026-07-08T00:00:00Z"
        }
        """;

    private static readonly TeamLibraryCredentials License = new("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", new string('a', 64));

    [Fact]
    public void ThePullResponseDecodesTheSnakeCaseWireFormatAndSanitizingDropsWhatWouldRunByItself()
    {
        var response = JsonSerializer.Deserialize(PullJson, LibraryJson.PullResponse)!;
        Assert.Equal("Prod", response.Connections[0].Name);
        Assert.Equal("owner@example.com", response.Connections[0].PublishedBy);
        Assert.Equal("ETL", response.QueryFolders[0].Name);
        Assert.Equal("select 1", response.Queries[0].Query);

        var sanitized = response.Sanitized();
        Assert.False(sanitized.Connections[0].Payload.ContainsKey("startupCommands"));
        Assert.False(sanitized.Connections[0].Payload.ContainsKey("tunnelCommand"));
        Assert.Equal("db", sanitized.Connections[0].Payload["host"]!.GetValue<string>());
        Assert.True(response.Connections[0].Payload.ContainsKey("startupCommands"));
    }

    [Fact]
    public void APublishRequestUsesSnakeCaseKeysUpperCaseIdsAndKeepsThePayloadsOwnKeys()
    {
        var folder = new SqlFavoriteFolder { Name = "ETL" };
        var favorite = new SqlFavorite { Name = "Recent", Query = "select 1", FolderId = folder.Id, Keyword = "rec" };
        var payload = JsonNode.Parse("""{"name":"Prod","host":"db","port":5432,"database":"app","username":"deploy","type":"PostgreSQL"}""")!.AsObject();
        var source = Guid.NewGuid();

        var request = TeamLibrarySync.BuildPublishRequest(License, [favorite], [folder], [(source, payload)]);
        var json = JsonSerializer.Serialize(request, LibraryJson.PublishRequest);

        Assert.Contains("\"license_key\"", json, StringComparison.Ordinal);
        Assert.Contains("\"machine_id\"", json, StringComparison.Ordinal);
        Assert.Contains("\"query_folders\"", json, StringComparison.Ordinal);
        Assert.Contains("\"source_connection_id\":\"" + source.ToString("D").ToUpperInvariant() + "\"", json, StringComparison.Ordinal);
        Assert.Contains("\"folder_client_id\":\"" + folder.Id.ToString("D").ToUpperInvariant() + "\"", json, StringComparison.Ordinal);
        Assert.Contains("\"name\":\"Prod\"", json, StringComparison.Ordinal);
        Assert.DoesNotContain("parent_client_id", json, StringComparison.Ordinal);
    }

    [Fact]
    public async Task APullIsCachedInTheMacFormatAndReadBackSanitizedByANewStore()
    {
        using var temp = new TempDirectory();
        var api = new FakeApi { Pull = JsonSerializer.Deserialize(PullJson, LibraryJson.PullResponse)! };
        var sync = new TeamLibrarySync(api, new TeamLibraryStore(temp.Paths), () => License);

        await sync.StartAsync(TestContext.Current.CancellationToken);

        Assert.Equal(1, api.PullCount);
        Assert.Equal("Recent", Assert.Single(sync.Library.Queries).Name);
        var cached = await File.ReadAllTextAsync(temp.File("team_library.json"), TestContext.Current.CancellationToken);
        Assert.Contains("\"query_folders\"", cached, StringComparison.Ordinal);
        Assert.DoesNotContain("startupCommands", cached, StringComparison.Ordinal);

        var restarted = new TeamLibrarySync(api, new TeamLibraryStore(temp.Paths), () => License);
        await restarted.StartAsync(TestContext.Current.CancellationToken);
        Assert.Equal(1, api.PullCount);
        Assert.Single(restarted.Library.Queries);
    }

    [Fact]
    public async Task APullIsDueAgainAfterAWeek()
    {
        using var temp = new TempDirectory();
        var api = new FakeApi { Pull = TeamLibraryPullResponse.Empty };
        var clock = new ManualClock(DateTimeOffset.Parse("2026-10-01T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture));
        var sync = new TeamLibrarySync(api, new TeamLibraryStore(temp.Paths), () => License, clock);

        await sync.PullIfDueAsync(TestContext.Current.CancellationToken);
        clock.Now += TimeSpan.FromDays(6);
        await sync.PullIfDueAsync(TestContext.Current.CancellationToken);
        Assert.Equal(1, api.PullCount);
        clock.Now += TimeSpan.FromDays(1);
        await sync.PullIfDueAsync(TestContext.Current.CancellationToken);
        Assert.Equal(2, api.PullCount);
    }

    [Fact]
    public async Task WithoutALicenseNothingIsPulledAndPublishingIsRefused()
    {
        using var temp = new TempDirectory();
        var api = new FakeApi { Pull = TeamLibraryPullResponse.Empty };
        var sync = new TeamLibrarySync(api, new TeamLibraryStore(temp.Paths), () => null);

        await sync.StartAsync(TestContext.Current.CancellationToken);
        Assert.False(sync.IsAvailable);
        Assert.Equal(0, api.PullCount);
        await Assert.ThrowsAsync<TeamLibraryException>(() => sync.PublishAsync([], [], cancellationToken: TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task PublishingSendsTheSavedQueriesThenRefreshesAndClearingEmptiesTheLibrary()
    {
        using var temp = new TempDirectory();
        var api = new FakeApi { Pull = JsonSerializer.Deserialize(PullJson, LibraryJson.PullResponse)! };
        var sync = new TeamLibrarySync(api, new TeamLibraryStore(temp.Paths), () => License);

        await sync.PublishAsync([new SqlFavorite { Name = "Mine", Query = "select 2" }], [], cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal("Mine", Assert.Single(api.Published!.Queries).Name);
        Assert.Equal(1, api.PullCount);
        Assert.False(sync.IsPublishing);

        await sync.ClearAsync(TestContext.Current.CancellationToken);
        Assert.True(sync.Library.IsEmpty);
        Assert.False(File.Exists(temp.File("team_library.json")));
    }

    [Fact]
    public async Task TeamQueriesForAConnectionAreTheUnscopedOnesAndItsOwn()
    {
        var connection = Guid.NewGuid();
        var response = TeamLibraryPullResponse.Empty with
        {
            Queries =
            [
                new("1", null, null, "Shared", "select 1", null, 1, null),
                new("2", null, connection.ToString("D").ToUpperInvariant(), "Mine", "select 2", null, 0, null),
                new("3", null, Guid.NewGuid().ToString("D").ToUpperInvariant(), "Other", "select 3", null, 0, null),
            ],
        };
        var api = new FakeApi { Pull = response };
        using var temp = new TempDirectory();
        var sync = new TeamLibrarySync(api, new TeamLibraryStore(temp.Paths), () => License);
        await sync.PullAsync(TestContext.Current.CancellationToken);

        Assert.Equal(["Mine", "Shared"], sync.QueriesFor(connection).Select(q => q.Name));
    }

    [Fact]
    public async Task TheHttpClientPostsToTheMacEndpointsAndReportsTheServersMessage()
    {
        var handler = new RecordingHandler(request => request.RequestUri!.AbsolutePath.EndsWith("/pull", StringComparison.Ordinal)
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(PullJson, Encoding.UTF8, "application/json") }
            : new HttpResponseMessage(HttpStatusCode.Forbidden) { Content = new StringContent("""{"message":"License is not a Team license."}""", Encoding.UTF8, "application/json") });
        using var http = new HttpClient(handler);
        var client = new HttpTeamLibraryApiClient(http);

        var pulled = await client.PullAsync(License, TestContext.Current.CancellationToken);
        Assert.Single(pulled.Queries);
        Assert.Equal("https://api.tablepro.app/v1/license/library/pull", handler.Requests[0].Uri);
        Assert.Contains("\"license_key\":\"AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\"", handler.Requests[0].Body, StringComparison.Ordinal);

        var error = await Assert.ThrowsAsync<TeamLibraryException>(() => client.DeleteQueryAsync("33333333", License, TestContext.Current.CancellationToken));
        Assert.Equal("License is not a Team license.", error.Message);
        Assert.Equal(403, error.StatusCode);
        Assert.Equal("https://api.tablepro.app/v1/license/library/queries/33333333", handler.Requests[1].Uri);
        Assert.Equal("DELETE", handler.Requests[1].Method);
    }

    private sealed class FakeApi : ITeamLibraryApiClient
    {
        public required TeamLibraryPullResponse Pull { get; init; }

        public int PullCount { get; private set; }

        public TeamLibraryPublishRequest? Published { get; private set; }

        public Task<TeamLibraryPullResponse> PullAsync(TeamLibraryCredentials credentials, CancellationToken cancellationToken = default)
        {
            PullCount++;
            return Task.FromResult(Pull);
        }

        public Task<TeamLibraryPublishResponse> PublishAsync(TeamLibraryPublishRequest request, CancellationToken cancellationToken = default)
        {
            Published = request;
            return Task.FromResult(new TeamLibraryPublishResponse("now", request.Connections.Count, request.Queries.Count));
        }

        public Task DeleteConnectionAsync(string id, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task DeleteQueryAsync(string clientId, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task DeleteQueryFolderAsync(string clientId, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default) => Task.CompletedTask;
    }

    private sealed class ManualClock(DateTimeOffset start) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = start;

        public override DateTimeOffset GetUtcNow() => Now;
    }

    private sealed class RecordingHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<(string Method, string Uri, string Body)> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content is null ? string.Empty : await request.Content.ReadAsStringAsync(cancellationToken);
            Requests.Add((request.Method.Method, request.RequestUri!.ToString(), body));
            return respond(request);
        }
    }
}
