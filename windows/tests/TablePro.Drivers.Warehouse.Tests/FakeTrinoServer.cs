using System.Collections.Concurrent;
using System.Net;
using System.Text;

namespace TablePro.Drivers.Warehouse.Tests;

/// <summary>A recorded request, read before the client disposes it.</summary>
internal sealed record RecordedRequest(HttpMethod Method, Uri Uri, IReadOnlyDictionary<string, string> Headers, string? Body)
{
    public string? Header(string name) => Headers.TryGetValue(name, out var value) ? value : null;
}

/// <summary>Answers the client protocol from a script: each request goes to the responder, and every request is kept.</summary>
internal sealed class FakeTrinoServer : HttpMessageHandler
{
    public const string Base = "http://trino.test:8080";

    private readonly Func<RecordedRequest, CancellationToken, Task<HttpResponseMessage>> _respond;

    public FakeTrinoServer(Func<RecordedRequest, CancellationToken, Task<HttpResponseMessage>> respond)
    {
        _respond = respond;
    }

    public FakeTrinoServer(Func<RecordedRequest, HttpResponseMessage> respond)
        : this((request, _) => Task.FromResult(respond(request)))
    {
    }

    public ConcurrentQueue<RecordedRequest> Requests { get; } = new();

    public RecordedRequest[] Sent => [.. Requests];

    public static HttpResponseMessage Json(string json, HttpStatusCode status = HttpStatusCode.OK, params (string Name, string Value)[] headers)
    {
        var response = new HttpResponseMessage(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        foreach (var (name, value) in headers)
        {
            response.Headers.TryAddWithoutValidation(name, value);
        }

        return response;
    }

    public static HttpResponseMessage Status(HttpStatusCode status, string body = "") =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "text/plain") };

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (name, values) in request.Headers)
        {
            headers[name] = string.Join(",", values);
        }

        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
        var recorded = new RecordedRequest(request.Method, request.RequestUri!, headers, body);
        Requests.Enqueue(recorded);
        return await _respond(recorded, cancellationToken);
    }
}
