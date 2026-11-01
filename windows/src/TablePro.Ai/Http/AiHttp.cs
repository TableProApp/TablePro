using System.Net;

namespace TablePro.Ai.Http;

/// <summary>
/// The one connection pool every provider shares. A client per request would leave sockets in TIME_WAIT, and a
/// pooled connection that never expires would keep a stale DNS answer.
/// </summary>
public static class AiHttp
{
    private static readonly Lazy<HttpClient> Client = new(Create, LazyThreadSafetyMode.ExecutionAndPublication);

    public static HttpClient SharedClient => Client.Value;

    private static HttpClient Create()
    {
        var handler = new SocketsHttpHandler
        {
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(1),
            ConnectTimeout = TimeSpan.FromSeconds(15),
            AutomaticDecompression = DecompressionMethods.All,
            EnableMultipleHttp2Connections = true,
        };

        // A streamed reply can run for minutes; each call bounds itself with its own cancellation token instead.
        return new HttpClient(handler, disposeHandler: true)
        {
            Timeout = Timeout.InfiniteTimeSpan,
            DefaultRequestVersion = HttpVersion.Version20,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrLower,
        };
    }
}
