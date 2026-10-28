using System.Diagnostics;
using Confluent.Kafka;
using Confluent.Kafka.Admin;

namespace TablePro.Drivers.Kafka;

/// <summary>
/// The clients one connection shares: an admin client for metadata and offsets, and a producer made on first use.
/// Reads get a consumer each, assigned to exact partitions under a throwaway group id, so browsing never joins a
/// group, never commits and never moves anyone's offsets.
/// </summary>
internal sealed class KafkaCluster : IDisposable
{
    /// <summary>The most messages one read may hold, across every partition it reads.</summary>
    public const int MaxRead = 200_000;

    private readonly ClientConfig _config;
    private readonly Lazy<IAdminClient> _admin;
    private readonly Lazy<IProducer<byte[]?, byte[]?>> _producer;

    public KafkaCluster(ClientConfig config, TimeSpan requestTimeout)
    {
        _config = config;
        RequestTimeout = requestTimeout;
        _admin = new Lazy<IAdminClient>(() => new AdminClientBuilder(KafkaSettings.Admin(_config)).Build(), LazyThreadSafetyMode.ExecutionAndPublication);
        _producer = new Lazy<IProducer<byte[]?, byte[]?>>(
            () => new ProducerBuilder<byte[]?, byte[]?>(KafkaSettings.Writer(_config))
                .SetKeySerializer(Serializers.ByteArray)
                .SetValueSerializer(Serializers.ByteArray)
                .Build(),
            LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public TimeSpan RequestTimeout { get; }

    public IAdminClient Admin => _admin.Value;

    public IProducer<byte[]?, byte[]?> Producer => _producer.Value;

    /// <summary>Metadata is a blocking call in librdkafka; callers are already on the thread pool.</summary>
    public Metadata Metadata() => Admin.GetMetadata(RequestTimeout);

    public TopicMetadata Topic(string topic)
    {
        var metadata = Admin.GetMetadata(topic, RequestTimeout);
        var found = metadata.Topics.FirstOrDefault(t => t.Topic == topic);
        if (found is null || found.Error.Code == ErrorCode.UnknownTopicOrPart || found.Partitions.Count == 0)
        {
            throw new InvalidOperationException($"There is no topic named {topic}.");
        }

        return found.Error.IsError ? throw new KafkaException(found.Error) : found;
    }

    /// <summary>The first and next-to-be-written offset of each partition, read with two ListOffsets calls.</summary>
    public async Task<Dictionary<TopicPartition, (long Low, long High)>> WatermarksAsync(IReadOnlyCollection<TopicPartition> partitions, CancellationToken cancellationToken)
    {
        var result = new Dictionary<TopicPartition, (long, long)>(partitions.Count);
        if (partitions.Count == 0)
        {
            return result;
        }

        var lows = await ListOffsetsAsync(partitions, OffsetSpec.Earliest(), cancellationToken);
        var highs = await ListOffsetsAsync(partitions, OffsetSpec.Latest(), cancellationToken);
        foreach (var partition in partitions)
        {
            var low = lows.GetValueOrDefault(partition, 0);
            result[partition] = (low, Math.Max(low, highs.GetValueOrDefault(partition, low)));
        }

        return result;
    }

    public async Task<Dictionary<TopicPartition, long>> ListOffsetsAsync(IReadOnlyCollection<TopicPartition> partitions, OffsetSpec spec, CancellationToken cancellationToken)
    {
        var request = partitions.Select(p => new TopicPartitionOffsetSpec { TopicPartition = p, OffsetSpec = spec }).ToList();
        var answer = await Admin.ListOffsetsAsync(request, new ListOffsetsOptions { RequestTimeout = RequestTimeout }).WaitAsync(cancellationToken);
        return answer.ResultInfos.ToDictionary(r => r.TopicPartitionOffsetError.TopicPartition, r => r.TopicPartitionOffsetError.Offset.Value);
    }

    /// <summary>Plans, reads, merges and pages one consume. Returns the page and whether every planned offset arrived in time.</summary>
    public async Task<(List<KafkaRecord> Page, bool Complete)> ConsumeAsync(KafkaConsume query, TimeSpan budget, CancellationToken cancellationToken)
    {
        var (merged, complete) = await ReadMergedAsync(query.Topic, query.Start, query.Skip, query.Limit, query.Partitions, budget, cancellationToken);
        return (KafkaRows.Page(merged, query.Skip, query.Limit, query.Start.ReadsBackward), complete);
    }

    /// <summary>Reads what a page of <paramref name="skip"/> plus <paramref name="limit"/> needs from each partition, merged by time.</summary>
    public async Task<(List<KafkaRecord> Merged, bool Complete)> ReadMergedAsync(
        string topicName, KafkaStart start, int skip, int limit, IReadOnlyList<int>? onlyPartitions, TimeSpan budget, CancellationToken cancellationToken)
    {
        var topic = Topic(topicName);
        var available = topic.Partitions.Select(p => p.PartitionId).ToHashSet();
        var chosen = onlyPartitions ?? available.Order().ToList();
        foreach (var partition in chosen)
        {
            if (!available.Contains(partition))
            {
                throw new InvalidOperationException($"Topic {topicName} has no partition {partition}.");
            }
        }

        var partitions = chosen.Distinct().Select(p => new TopicPartition(topicName, p)).ToList();
        var marks = (await WatermarksAsync(partitions, cancellationToken)).ToDictionary(m => m.Key.Partition.Value, m => m.Value);
        Dictionary<int, long>? times = null;
        if (start.Kind == KafkaStartKind.Timestamp)
        {
            var found = await ListOffsetsAsync(partitions, OffsetSpec.ForTimestamp(start.Value), cancellationToken);
            times = found.ToDictionary(f => f.Key.Partition.Value, f => f.Value);
        }

        var plan = KafkaRows.Plan(start, skip, limit, marks, times);
        if (plan.Sum(r => r.Count) > MaxRead)
        {
            throw new InvalidOperationException(
                $"This page needs more than {MaxRead:N0} messages read across {plan.Count} partitions. Read fewer partitions, or start nearer the rows with FROM OFFSET or FROM TIME.");
        }

        var (records, complete) = Read(topicName, plan, budget, cancellationToken);
        return (KafkaRows.Merge(records), complete);
    }

    /// <summary>
    /// Reads each range from its start until its end offset, the end of the log, or the budget. Compaction and
    /// transaction markers leave gaps, so a partition is done at the first offset at or past its end, not at end - 1.
    /// </summary>
    public (List<KafkaRecord> Records, bool Complete) Read(string topic, IReadOnlyList<PartitionRange> ranges, TimeSpan budget, CancellationToken cancellationToken)
    {
        var records = new List<KafkaRecord>((int)Math.Min(ranges.Sum(r => r.Count), 10_000));
        if (ranges.Count == 0)
        {
            return (records, true);
        }

        using var consumer = new ConsumerBuilder<byte[]?, byte[]?>(KafkaSettings.Reader(_config))
            .SetKeyDeserializer(Deserializers.ByteArray)
            .SetValueDeserializer(Deserializers.ByteArray)
            .Build();
        var pending = ranges.ToDictionary(r => r.Partition);
        consumer.Assign(ranges.Select(r => new TopicPartitionOffset(topic, r.Partition, r.Start)));
        var clock = Stopwatch.StartNew();
        while (pending.Count > 0 && clock.Elapsed < budget)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = consumer.Consume(TimeSpan.FromMilliseconds(200));
            if (result is null || !pending.TryGetValue(result.Partition.Value, out var range))
            {
                continue;
            }

            if (result.IsPartitionEOF || result.Offset.Value >= range.End)
            {
                Done(consumer, pending, topic, range.Partition);
                continue;
            }

            if (result.Offset.Value >= range.Start)
            {
                records.Add(ToRecord(result));
            }

            if (result.Offset.Value >= range.End - 1)
            {
                Done(consumer, pending, topic, range.Partition);
            }
        }

        return (records, pending.Count == 0);
    }

    public void Dispose()
    {
        if (_producer.IsValueCreated)
        {
            // Messages still queued get a moment to leave before the producer goes away.
            _producer.Value.Flush(TimeSpan.FromSeconds(5));
            _producer.Value.Dispose();
        }

        if (_admin.IsValueCreated)
        {
            _admin.Value.Dispose();
        }
    }

    internal static KafkaRecord ToRecord(ConsumeResult<byte[]?, byte[]?> result)
    {
        var message = result.Message;
        var headers = message.Headers is { Count: > 0 } list
            ? list.Select(h => new KeyValuePair<string, byte[]?>(h.Key, h.GetValueBytes())).ToArray()
            : [];
        var timestamp = message.Timestamp.Type == TimestampType.NotAvailable ? -1 : message.Timestamp.UnixTimestampMs;
        return new KafkaRecord(result.Partition.Value, result.Offset.Value, timestamp, message.Key, message.Value, headers);
    }

    private static void Done(IConsumer<byte[]?, byte[]?> consumer, Dictionary<int, PartitionRange> pending, string topic, int partition)
    {
        pending.Remove(partition);
        consumer.Pause([new TopicPartition(topic, partition)]);
    }
}
