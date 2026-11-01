using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;

namespace TablePro.Drivers.Search.Tests;

/// <summary>
/// Answers requests from routes matched on method and path, and records every request with its body, so no test
/// touches the network. A route can answer once or every time; an unmatched request is a 404 the test will notice.
/// </summary>
internal sealed class FakeHttp : HttpMessageHandler
{
    private readonly List<Route> _routes = [];
    private readonly ConcurrentQueue<Recorded> _requests = new();

    public IReadOnlyList<Recorded> Requests => [.. _requests];

    public Func<HttpRequestMessage, Exception?>? Fail { get; set; }

    public TimeSpan Delay { get; set; }

    public FakeHttp On(string method, string pathPrefix, string body, HttpStatusCode status = HttpStatusCode.OK, bool once = false, string contentType = "application/json")
    {
        lock (_routes)
        {
            _routes.Add(new Route(method, pathPrefix, status, body, once, contentType));
        }

        return this;
    }

    public Recorded Last(string method, string pathPrefix) =>
        Requests.Last(r => r.Method == method && r.PathAndQuery.StartsWith(pathPrefix, StringComparison.Ordinal));

    public IEnumerable<Recorded> All(string method, string pathPrefix) =>
        Requests.Where(r => r.Method == method && r.PathAndQuery.StartsWith(pathPrefix, StringComparison.Ordinal));

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
        var headers = request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value), StringComparer.OrdinalIgnoreCase);
        if (request.Content is not null)
        {
            foreach (var header in request.Content.Headers)
            {
                headers[header.Key] = string.Join(",", header.Value);
            }
        }

        _requests.Enqueue(new Recorded(request.Method.Method, request.RequestUri!, headers, body));
        if (Fail?.Invoke(request) is { } failure)
        {
            throw failure;
        }

        if (Delay > TimeSpan.Zero)
        {
            await Task.Delay(Delay, cancellationToken);
        }

        Route? match;
        lock (_routes)
        {
            // The most specific route wins. Among equals, one-shot answers go first in the order queued, then the
            // standing route added last, so a test can override a default.
            match = _routes
                .Select((route, index) => (route, index))
                .Where(r => r.route.Method == request.Method.Method && request.RequestUri!.PathAndQuery.StartsWith(r.route.Prefix, StringComparison.Ordinal))
                .OrderByDescending(r => r.route.Prefix.Length)
                .ThenByDescending(r => r.route.Once)
                .ThenBy(r => r.route.Once ? r.index : -r.index)
                .Select(r => r.route)
                .FirstOrDefault();
            if (match is { Once: true })
            {
                _routes.Remove(match);
            }
        }

        return match is null
            ? new HttpResponseMessage(HttpStatusCode.NotFound) { Content = new StringContent("{\"error\":\"no route\"}", Encoding.UTF8, "application/json") }
            : new HttpResponseMessage(match.Status) { Content = new StringContent(match.Body, Encoding.UTF8, match.ContentType) };
    }

    private sealed record Route(string Method, string Prefix, HttpStatusCode Status, string Body, bool Once, string ContentType);
}

internal sealed record Recorded(string Method, Uri Uri, IReadOnlyDictionary<string, string> Headers, string? Body)
{
    public string PathAndQuery => Uri.PathAndQuery;

    public JsonElement Json => JsonDocument.Parse(Body ?? "null").RootElement;

    public string Header(string name) => Headers.TryGetValue(name, out var value) ? value : string.Empty;
}

internal static class Profiles
{
    public static ConnectionRequest Request(
        DatabaseEngine engine,
        string? username = null,
        string? password = null,
        string? database = null,
        SslMode ssl = SslMode.Disabled,
        Dictionary<string, string>? options = null,
        string host = "search.test")
    {
        var profile = new ConnectionProfile
        {
            Name = engine.ToString(),
            Engine = engine,
            Host = host,
            Username = username,
            Database = database,
            SslMode = ssl,
            AdditionalOptions = options ?? [],
        };
        return new ConnectionRequest(profile, password, host, profile.EffectivePort, database);
    }

    public static async Task<List<StatementResult>> RunAsync(IDatabaseSession session, params string[] statements)
    {
        await using var channel = await session.OpenChannelAsync(CancellationToken.None);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(StopOnError: false), CancellationToken.None))
        {
            results.Add(result);
        }

        return results;
    }

    public static object? Cell(ResultSet set, int row, string column) => set[row, set.ColumnIndex(column)];
}
