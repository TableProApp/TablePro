using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Kafka;

/// <summary>Apache Kafka through Confluent's client, which wraps the native librdkafka shipped in its package.</summary>
public sealed class KafkaDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Kafka];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken) =>
        await KafkaSession.ConnectAsync(request, cancellationToken);
}
