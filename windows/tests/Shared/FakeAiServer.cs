using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace TablePro.Testing;

// An OpenAI-compatible server on 127.0.0.1, as Ollama answers: models at /v1/models, a streamed reply at
// /v1/chat/completions. Each request is kept, so a test can check what reached it.
internal sealed class FakeAiServer : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private readonly List<Request> _seen = [];
    private readonly Lock _gate = new();

    public FakeAiServer(string reply, IReadOnlyList<string>? models = null, int status = 200, string? error = null)
    {
        Reply = reply;
        Models = models ?? ["test-model"];
        Status = status;
        Error = error;
        _listener.Start();
        _ = AcceptAsync();
    }

    public sealed record Request(string Method, string Path, IReadOnlyDictionary<string, string> Headers, string Body);

    public string Reply { get; }

    public IReadOnlyList<string> Models { get; }

    public int Status { get; }

    public string? Error { get; }

    // With the version path, as the settings take it.
    public string Address => $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}/v1";

    public IReadOnlyList<Request> Seen
    {
        get
        {
            lock (_gate)
            {
                return [.. _seen];
            }
        }
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
        _stop.Dispose();
    }

    private async Task AcceptAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(_stop.Token).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is OperationCanceledException or SocketException or ObjectDisposedException)
            {
                return;
            }

            _ = AnswerAsync(client);
        }
    }

    private async Task AnswerAsync(TcpClient client)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var request = await ReadAsync(stream).ConfigureAwait(false);
                lock (_gate)
                {
                    _seen.Add(request);
                }

                var (status, type, body) = Respond(request);
                var head = $"HTTP/1.1 {status} X\r\ncontent-type: {type}\r\ncontent-length: {Encoding.UTF8.GetByteCount(body)}\r\nconnection: close\r\n\r\n";
                await stream.WriteAsync(Encoding.UTF8.GetBytes(head + body), _stop.Token).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is IOException or OperationCanceledException or SocketException or ObjectDisposedException)
            {
                // The client went away; nothing is left to answer.
            }
        }
    }

    private (int Status, string Type, string Body) Respond(Request request)
    {
        if (Status != 200)
        {
            return (Status, "application/json", JsonSerializer.Serialize(new { error = new { message = Error ?? "refused" } }));
        }

        if (request.Method == "GET" && request.Path.StartsWith("/v1/models", StringComparison.Ordinal))
        {
            var listing = new { @object = "list", data = Models.Select(model => new { id = model }).ToArray() };
            return (200, "application/json", JsonSerializer.Serialize(listing));
        }

        var builder = new StringBuilder();
        // A few pieces, as a model streams them.
        foreach (var part in Chunk(Reply))
        {
            var chunk = new { choices = new[] { new { delta = new { content = part } } } };
            builder.Append("data: ").Append(JsonSerializer.Serialize(chunk)).Append("\n\n");
        }

        builder.Append("data: ").Append("""{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":120,"completion_tokens":30}}""").Append("\n\n");
        builder.Append("data: [DONE]\n\n");
        return (200, "text/event-stream", builder.ToString());
    }

    private static IEnumerable<string> Chunk(string text)
    {
        for (var start = 0; start < text.Length; start += 16)
        {
            yield return text.Substring(start, Math.Min(16, text.Length - start));
        }
    }

    private static async Task<Request> ReadAsync(NetworkStream stream)
    {
        var bytes = new List<byte>();
        var buffer = new byte[4096];
        int headEnd;
        while (true)
        {
            var read = await stream.ReadAsync(buffer).ConfigureAwait(false);
            if (read == 0)
            {
                throw new IOException("The client closed before its request ended.");
            }

            bytes.AddRange(buffer.AsSpan(0, read));
            headEnd = IndexOfBlankLine(bytes);
            if (headEnd >= 0)
            {
                break;
            }
        }

        var head = Encoding.ASCII.GetString([.. bytes.Take(headEnd)]);
        var lines = head.Split("\r\n");
        var first = lines[0].Split(' ');
        var headers = lines.Skip(1)
            .Select(line => line.Split(':', 2))
            .Where(parts => parts.Length == 2)
            .GroupBy(parts => parts[0].Trim().ToLowerInvariant())
            .ToDictionary(group => group.Key, group => group.Last()[1].Trim());
        var length = headers.TryGetValue("content-length", out var text)
            ? int.Parse(text, CultureInfo.InvariantCulture)
            : 0;
        var bodyStart = headEnd + 4;
        while (bytes.Count < bodyStart + length)
        {
            var read = await stream.ReadAsync(buffer).ConfigureAwait(false);
            if (read == 0)
            {
                throw new IOException("The client closed before its body ended.");
            }

            bytes.AddRange(buffer.AsSpan(0, read));
        }

        var body = Encoding.UTF8.GetString([.. bytes.Skip(bodyStart).Take(length)]);
        return new Request(first[0], first.Length > 1 ? first[1] : string.Empty, headers, body);
    }

    private static int IndexOfBlankLine(List<byte> bytes)
    {
        for (var index = 0; index + 3 < bytes.Count; index++)
        {
            if (bytes[index] == '\r' && bytes[index + 1] == '\n' && bytes[index + 2] == '\r' && bytes[index + 3] == '\n')
            {
                return index;
            }
        }

        return -1;
    }
}
