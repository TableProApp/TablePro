using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Etcd;

/// <summary>etcd v3 over its JSON gateway, which every etcd since 3.3 serves on the client port.</summary>
public sealed class EtcdDriver : IDatabaseDriver
{
    private readonly Func<HttpMessageHandler>? _handlerFactory;

    public EtcdDriver()
    {
    }

    /// <summary>Tests hand in a fake handler so requests never leave the process.</summary>
    internal EtcdDriver(Func<HttpMessageHandler> handlerFactory)
    {
        _handlerFactory = handlerFactory;
    }

    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Etcd];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        return await EtcdSession.ConnectAsync(request, _handlerFactory?.Invoke(), cancellationToken);
    }
}
