using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using Confluent.Kafka;
using Confluent.Kafka.Admin;
using TablePro.Core.Drivers;
using TablePro.Core.Results;

namespace TablePro.Drivers.Kafka;

/// <summary>An editor tab of KafkaQL statements, each run through the connection's admin client, a reader or the producer.</summary>
internal sealed class KafkaChannel(KafkaCluster cluster) : IQueryChannel
{
    private static readonly TimeSpan DefaultBudget = TimeSpan.FromSeconds(30);

    private readonly SemaphoreSlim _gate = new(1, 1);

    public async IAsyncEnumerable<StatementResult> ExecuteAsync(
        IReadOnlyList<string> statements,
        ExecuteOptions options,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            foreach (var text in statements)
            {
                var result = await RunAsync(text, options, cancellationToken);
                yield return result;
                if (!result.Succeeded && (options.StopOnError || cancellationToken.IsCancellationRequested))
                {
                    yield break;
                }
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public ValueTask DisposeAsync()
    {
        _gate.Dispose();
        return ValueTask.CompletedTask;
    }

    private async Task<StatementResult> RunAsync(string text, ExecuteOptions options, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var stopwatch = Stopwatch.StartNew();
        try
        {
            var statement = KafkaQL.Parse(text);
            var budget = options.CommandTimeoutSeconds > 0 ? TimeSpan.FromSeconds(options.CommandTimeoutSeconds) : DefaultBudget;
            var (sets, affected, messages) = await RunAsync(statement, options.RowLimit, budget, cancellationToken);
            return new StatementResult(text, sets, affected, stopwatch.Elapsed, Messages: messages);
        }
        catch (OperationCanceledException)
        {
            return new StatementResult(text, [], -1, stopwatch.Elapsed, "Statement cancelled.");
        }
        catch (Exception ex) when (ex is KafkaQLException or KafkaException or InvalidOperationException or NotSupportedException or ArgumentException or FormatException or TimeoutException)
        {
            return new StatementResult(text, [], -1, stopwatch.Elapsed, ex.Message);
        }
    }

    private async Task<(IReadOnlyList<ResultSet> Sets, int Affected, IReadOnlyList<string> Messages)> RunAsync(
        KafkaStatement statement, int rowLimit, TimeSpan budget, CancellationToken cancellationToken)
    {
        var options = cluster.RequestTimeout;
        switch (statement)
        {
            case KafkaConsume consume:
            {
                var limited = consume with { Limit = Math.Min(consume.Limit, Math.Max(1, rowLimit)) };
                var (page, complete) = await cluster.ConsumeAsync(limited, budget, cancellationToken);
                IReadOnlyList<string> notes = complete
                    ? []
                    : [string.Create(CultureInfo.InvariantCulture, $"Stopped after {budget.TotalSeconds:0} seconds with some partitions not fully read; the rows shown are what arrived.")];
                return ([KafkaRows.ToResultSet(page, !complete)], -1, notes);
            }

            case KafkaProduce produce:
            {
                var message = new Message<byte[]?, byte[]?>
                {
                    Key = produce.Key is null ? null : Encoding.UTF8.GetBytes(produce.Key),
                    Value = produce.Value is null ? null : Encoding.UTF8.GetBytes(produce.Value),
                };
                if (produce.Headers.Count > 0)
                {
                    message.Headers = [];
                    foreach (var (name, value) in produce.Headers)
                    {
                        message.Headers.Add(name, Encoding.UTF8.GetBytes(value));
                    }
                }

                var delivery = produce.Partition is { } partition
                    ? await cluster.Producer.ProduceAsync(new TopicPartition(produce.Topic, partition), message, cancellationToken)
                    : await cluster.Producer.ProduceAsync(produce.Topic, message, cancellationToken);
                return ([Table(
                    ["partition", "offset", "timestamp"],
                    [typeof(int), typeof(long), typeof(DateTimeOffset)],
                    [[delivery.Partition.Value, delivery.Offset.Value, KafkaRows.Timestamp(delivery.Timestamp.UnixTimestampMs)]])], 1, []);
            }

            case KafkaShow { Target: KafkaShowTarget.Topics }:
            {
                var rows = cluster.Metadata().Topics
                    .OrderBy(t => t.Topic, StringComparer.Ordinal)
                    .Select(t => new object?[]
                    {
                        t.Topic,
                        t.Partitions.Count,
                        t.Partitions.Count > 0 ? t.Partitions[0].Replicas.Length : 0,
                        t.Topic.StartsWith("__", StringComparison.Ordinal),
                        t.Error.IsError ? t.Error.Reason : null,
                    }).ToList();
                return ([Table(["topic", "partitions", "replication", "internal", "error"], [typeof(string), typeof(int), typeof(int), typeof(bool), typeof(string)], rows)], -1, []);
            }

            case KafkaShow { Target: KafkaShowTarget.Brokers }:
            {
                var metadata = cluster.Metadata();
                int? controller = null;
                try
                {
                    controller = (await cluster.Admin.DescribeClusterAsync(new DescribeClusterOptions { RequestTimeout = options }).WaitAsync(cancellationToken)).Controller?.Id;
                }
                catch (KafkaException)
                {
                    // Older brokers cannot describe the cluster; the broker list still stands.
                }

                var rows = metadata.Brokers.OrderBy(b => b.BrokerId)
                    .Select(b => new object?[] { b.BrokerId, b.Host, b.Port, controller is null ? null : b.BrokerId == controller })
                    .ToList();
                return ([Table(["id", "host", "port", "controller"], [typeof(int), typeof(string), typeof(int), typeof(bool)], rows)], -1, []);
            }

            case KafkaShow { Target: KafkaShowTarget.Groups }:
            {
                var listing = await cluster.Admin.ListConsumerGroupsAsync(new ListConsumerGroupsOptions { RequestTimeout = options }).WaitAsync(cancellationToken);
                var rows = listing.Valid.OrderBy(g => g.GroupId, StringComparer.Ordinal)
                    .Select(g => new object?[] { g.GroupId, g.State.ToString(), g.IsSimpleConsumerGroup })
                    .ToList();
                return ([Table(["group", "state", "simple"], [typeof(string), typeof(string), typeof(bool)], rows)], -1, []);
            }

            case KafkaShow { Target: KafkaShowTarget.Cluster }:
            {
                var described = await cluster.Admin.DescribeClusterAsync(new DescribeClusterOptions { RequestTimeout = options }).WaitAsync(cancellationToken);
                var metadata = cluster.Metadata();
                object?[] row =
                [
                    described.ClusterId,
                    described.Controller?.Id,
                    described.Nodes.Count,
                    metadata.Topics.Count,
                    metadata.Topics.Sum(t => t.Partitions.Count),
                ];
                return ([Table(["cluster_id", "controller", "brokers", "topics", "partitions"], [typeof(string), typeof(int), typeof(int), typeof(int), typeof(int)], [row])], -1, []);
            }

            case KafkaDescribeTopic describe:
            {
                var topic = cluster.Topic(describe.Topic);
                var partitions = topic.Partitions.Select(p => new TopicPartition(topic.Topic, p.PartitionId)).ToList();
                var marks = await cluster.WatermarksAsync(partitions, cancellationToken);
                var rows = topic.Partitions.OrderBy(p => p.PartitionId).Select(p =>
                {
                    var (low, high) = marks.GetValueOrDefault(new TopicPartition(topic.Topic, p.PartitionId));
                    return new object?[]
                    {
                        p.PartitionId,
                        p.Leader,
                        string.Join(",", p.Replicas),
                        string.Join(",", p.InSyncReplicas),
                        low,
                        high,
                        high - low,
                    };
                }).ToList();
                var sets = new List<ResultSet>
                {
                    Table(["partition", "leader", "replicas", "isr", "low", "high", "messages"], [typeof(int), typeof(int), typeof(string), typeof(string), typeof(long), typeof(long), typeof(long)], rows),
                };
                try
                {
                    var configs = await cluster.Admin.DescribeConfigsAsync(
                        [new ConfigResource { Type = ResourceType.Topic, Name = topic.Topic }],
                        new DescribeConfigsOptions { RequestTimeout = options }).WaitAsync(cancellationToken);
                    var configRows = configs.SelectMany(c => c.Entries.Values).OrderBy(e => e.Name, StringComparer.Ordinal)
                        .Select(e => new object?[] { e.Name, e.IsSensitive ? null : e.Value, e.IsDefault, e.Source.ToString() })
                        .ToList();
                    sets.Add(Table(["config", "value", "default", "source"], [typeof(string), typeof(string), typeof(bool), typeof(string)], configRows));
                }
                catch (KafkaException)
                {
                    // Configs need DESCRIBE_CONFIGS, which a read-only user may lack.
                }

                return (sets, -1, []);
            }

            case KafkaDescribeGroup describe:
            {
                var described = await cluster.Admin.DescribeConsumerGroupsAsync([describe.Group], new DescribeConsumerGroupsOptions { RequestTimeout = options }).WaitAsync(cancellationToken);
                var group = described.ConsumerGroupDescriptions.FirstOrDefault() ?? throw new InvalidOperationException($"There is no consumer group named {describe.Group}.");
                var offsets = await cluster.Admin.ListConsumerGroupOffsetsAsync(
                    [new ConsumerGroupTopicPartitions(describe.Group, null)],
                    new ListConsumerGroupOffsetsOptions { RequestTimeout = options }).WaitAsync(cancellationToken);
                var committed = offsets.SelectMany(o => o.Partitions).ToList();
                var owners = group.Members
                    .SelectMany(m => (m.Assignment?.TopicPartitions ?? []).Select(tp => (tp, m)))
                    .GroupBy(x => x.tp)
                    .ToDictionary(g => g.Key, g => g.First().m);
                var partitions = committed.Select(c => c.TopicPartition).Concat(owners.Keys).Distinct().ToList();
                var ends = await cluster.WatermarksAsync(partitions, cancellationToken);
                var rows = partitions.OrderBy(p => p.Topic, StringComparer.Ordinal).ThenBy(p => p.Partition.Value).Select(tp =>
                {
                    var offset = committed.FirstOrDefault(c => c.TopicPartition == tp)?.Offset.Value ?? -1;
                    var end = ends.GetValueOrDefault(tp);
                    var member = owners.GetValueOrDefault(tp);
                    return new object?[]
                    {
                        tp.Topic,
                        tp.Partition.Value,
                        offset >= 0 ? offset : null,
                        end.High,
                        KafkaActivity.Lag([(tp, offset)], ends),
                        member?.ConsumerId,
                        member?.ClientId,
                        member?.Host,
                    };
                }).ToList();
                var note = string.Create(CultureInfo.InvariantCulture, $"Group {group.GroupId} is {group.State} with {group.Members.Count} member(s).");
                return ([Table(
                    ["topic", "partition", "committed", "end", "lag", "member", "client_id", "host"],
                    [typeof(string), typeof(int), typeof(long), typeof(long), typeof(long), typeof(string), typeof(string), typeof(string)],
                    rows)], -1, [note]);
            }

            case KafkaCreateTopic create:
            {
                var spec = new TopicSpecification
                {
                    Name = create.Topic,
                    NumPartitions = create.Partitions,
                    ReplicationFactor = create.Replication,
                    Configs = create.Config.Count > 0 ? new Dictionary<string, string>(create.Config) : null,
                };
                await cluster.Admin.CreateTopicsAsync([spec], new CreateTopicsOptions { RequestTimeout = options, OperationTimeout = options }).WaitAsync(cancellationToken);
                return ([], 0, [$"Topic {create.Topic} created."]);
            }

            case KafkaDropTopic drop:
                await cluster.Admin.DeleteTopicsAsync([drop.Topic], new DeleteTopicsOptions { RequestTimeout = options, OperationTimeout = options }).WaitAsync(cancellationToken);
                return ([], 0, [$"Topic {drop.Topic} deleted."]);

            default:
                throw new KafkaQLException("That statement is not supported.");
        }
    }

    private static ResultSet Table(string[] names, Type[] types, List<object?[]> rows)
    {
        var columns = new ResultColumn[names.Length];
        for (var i = 0; i < names.Length; i++)
        {
            var type = types[i];
            var typeName = type == typeof(long) ? "BIGINT" : type == typeof(int) ? "INTEGER" : type == typeof(bool) ? "BOOLEAN" : type == typeof(DateTimeOffset) ? "TIMESTAMP" : "TEXT";
            columns[i] = new ResultColumn(names[i], typeName, type);
        }

        return new ResultSet(columns, rows);
    }
}
