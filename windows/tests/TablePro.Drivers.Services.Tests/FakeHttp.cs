using System.Net;
using System.Text;
using System.Text.Json;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Services.Tests;

internal sealed record RecordedRequest(HttpMethod Method, Uri Uri, string? Authorization, string? Body)
{
    public JsonElement Json => JsonDocument.Parse(Body ?? "null").RootElement;
}

/// <summary>Answers every request in-process from a script, and keeps what was sent for the assertions.</summary>
internal sealed class FakeHttpHandler(Func<RecordedRequest, HttpResponseMessage> respond) : HttpMessageHandler
{
    private readonly List<RecordedRequest> _requests = [];

    public IReadOnlyList<RecordedRequest> Requests
    {
        get
        {
            lock (_requests)
            {
                return [.. _requests];
            }
        }
    }

    public static HttpResponseMessage Json(string json, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    public static HttpResponseMessage Text(string text, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(text, Encoding.UTF8, "text/plain") };

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
        string? authorization = request.Headers.TryGetValues("Authorization", out var values) ? values.First() : null;
        var recorded = new RecordedRequest(request.Method, request.RequestUri!, authorization, body);
        lock (_requests)
        {
            _requests.Add(recorded);
        }

        return respond(recorded);
    }
}

internal static class Requests
{
    public static ConnectionRequest For(
        DatabaseEngine engine,
        string host = "localhost",
        int port = 0,
        string? database = null,
        string? user = null,
        string? password = null,
        SslMode ssl = SslMode.Preferred,
        Dictionary<string, string>? options = null)
    {
        var profile = new ConnectionProfile
        {
            Name = "test",
            Engine = engine,
            Host = host,
            Port = port,
            Database = database,
            Username = user,
            SslMode = ssl,
            ConnectTimeoutSeconds = 5,
            AdditionalOptions = options ?? [],
        };
        return ConnectionRequest.Direct(profile, password);
    }

    public static string Base64(string text) => Convert.ToBase64String(Encoding.UTF8.GetBytes(text));

    public static string FromBase64(string base64) => Encoding.UTF8.GetString(Convert.FromBase64String(base64));
}
