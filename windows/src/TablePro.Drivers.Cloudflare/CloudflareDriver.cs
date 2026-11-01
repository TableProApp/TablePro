using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Drivers.Cloudflare.Localization;

namespace TablePro.Drivers.Cloudflare;

/// <summary>Cloudflare's HTTP SQL services: D1 (SQLite) and R2 SQL (read-only Iceberg).</summary>
public sealed class CloudflareDriver : IDatabaseDriver
{
    private readonly Func<HttpMessageHandler>? _handlerFactory;

    public CloudflareDriver()
    {
    }

    /// <summary>Tests hand in a fake handler so requests never leave the process.</summary>
    internal CloudflareDriver(Func<HttpMessageHandler> handlerFactory)
    {
        _handlerFactory = handlerFactory;
    }

    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.CloudflareD1, DatabaseEngine.CloudflareR2Sql];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var handler = _handlerFactory?.Invoke();
        return request.Profile.Engine switch
        {
            DatabaseEngine.CloudflareD1 => await D1Session.ConnectAsync(request, handler, cancellationToken),
            DatabaseEngine.CloudflareR2Sql => await R2SqlSession.ConnectAsync(request, handler, cancellationToken),
            _ => throw new NotSupportedException(CloudflareStrings.Format("Cloudflare/NotACloudflareEngine", request.Profile.Descriptor.DisplayName)),
        };
    }
}
