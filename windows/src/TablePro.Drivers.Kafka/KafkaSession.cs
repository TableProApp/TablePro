using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using Confluent.Kafka;
using Confluent.Kafka.Admin;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Kafka;

/// <summary>
/// An Apache Kafka cluster. Topics are the objects and messages their rows: a page is read from the oldest messages
/// (or the newest, sorted descending), saves produce new messages, and consumer groups with their lag fill the server
/// dashboard.
/// </summary>
internal sealed class KafkaSession : IDatabaseSession, IServerActivityProvider, ISchemaDdlProvider
{
    /// <summary>How long a grid page may spend reading before it shows what arrived.</summary>
    internal static readonly TimeSpan BrowseBudget = TimeSpan.FromSeconds(30);

    private KafkaSession(ConnectionRequest request, KafkaCluster cluster, string serverVersion)
    {
        Profile = request.Profile;
        Cluster = cluster;
        ServerVersion = serverVersion;
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => KafkaDialect.Instance;

    public string ServerVersion { get; }

    public string? CurrentDatabase => null;

    public string? DefaultSchema => null;

    public string ProcessIdColumn => "group";

    internal KafkaCluster Cluster { get; }

    public IReadOnlyList<string> CommonDataTypes => [];

    public static async Task<KafkaSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var config = KafkaSettings.Build(request);
        var cluster = new KafkaCluster(config, TimeSpan.FromSeconds(Math.Max(5, request.Profile.ConnectTimeoutSeconds)));
        try
        {
            cancellationToken.ThrowIfCancellationRequested();

            // Metadata proves the bootstrap servers answer and the credentials are accepted.
            var metadata = cluster.Metadata();
            var version = string.Create(CultureInfo.InvariantCulture, $"Apache Kafka, {metadata.Brokers.Count} brokers (librdkafka {Library.VersionString})");
            return new KafkaSession(request, cluster, version);
        }
        catch
        {
            cluster.Dispose();
            throw;
        }
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await Yield();
        Cluster.Metadata();
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();

        // Topics whose names start with "__" are Kafka's own (__consumer_offsets, __transaction_state).
        var topics = Cluster.Metadata().Topics
            .Where(t => !t.Error.IsError && !t.Topic.StartsWith("__", StringComparison.Ordinal))
            .OrderBy(t => t.Topic, StringComparer.Ordinal)
            .ToList();
        Dictionary<string, long>? counts = null;
        try
        {
            var partitions = topics.SelectMany(t => t.Partitions.Select(p => new TopicPartition(t.Topic, p.PartitionId))).ToList();
            var marks = await Cluster.WatermarksAsync(partitions, cancellationToken);
            counts = marks.GroupBy(m => m.Key.Topic).ToDictionary(g => g.Key, g => g.Sum(m => m.Value.High - m.Value.Low));
        }
        catch (KafkaException)
        {
            // Without DESCRIBE rights on every topic the list still shows, only without message counts.
        }

        return topics.Select(t => new DatabaseObject(
            new ObjectName(null, t.Topic),
            ObjectKind.Topic,
            counts?.GetValueOrDefault(t.Topic),
            t.Partitions.Count == 1 ? "1 partition" : string.Create(CultureInfo.InvariantCulture, $"{t.Partitions.Count} partitions"))).ToArray();
    }

    public Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken) =>
        Task.FromResult(new TableStructure(table, KafkaRows.Columns, [], [], []));

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        var topic = Cluster.Topic(obj.Name.Name);
        var replication = topic.Partitions.Count > 0 ? topic.Partitions[0].Replicas.Length : 1;
        var sql = new StringBuilder("CREATE TOPIC ").Append(KafkaQL.Quote(topic.Topic))
            .Append(CultureInfo.InvariantCulture, $" PARTITIONS {topic.Partitions.Count} REPLICATION {replication}");
        try
        {
            var configs = await Cluster.Admin.DescribeConfigsAsync(
                [new ConfigResource { Type = ResourceType.Topic, Name = topic.Topic }],
                new DescribeConfigsOptions { RequestTimeout = Cluster.RequestTimeout }).WaitAsync(cancellationToken);
            foreach (var entry in configs.SelectMany(c => c.Entries.Values).Where(e => !e.IsDefault && !e.IsSensitive && e.Source == ConfigSource.DynamicTopicConfig).OrderBy(e => e.Name, StringComparer.Ordinal))
            {
                // A trailing backslash continues the statement on the next line, so the definition runs as written.
                sql.Append(" \\\n    CONFIG ").Append(entry.Name).Append('=').Append(entry.Value.Contains(' ', StringComparison.Ordinal) ? KafkaQL.Quote(entry.Value) : entry.Value);
            }
        }
        catch (KafkaException)
        {
            // Reading configs needs DESCRIBE_CONFIGS; the partitions and replication are still the definition.
        }

        return sql.ToString();
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var topic = request.Table.Name;
        var newestFirst = request.Sort.Count > 0 && request.Sort[0].Descending
            && request.Sort[0].Column is KafkaRows.TimestampColumn or KafkaRows.OffsetColumn;
        var start = newestFirst ? KafkaStart.Newest : KafkaStart.Oldest;
        List<KafkaRecord> page;
        bool complete;
        if (request.Filter.IsEmpty)
        {
            (page, complete) = await Cluster.ConsumeAsync(new KafkaConsume(topic, start, request.Limit, request.Offset, null), BrowseBudget, cancellationToken);
        }
        else
        {
            // A broker cannot filter, so a window of the topic is read and filtered here; matches beyond it are not seen.
            var (window, done) = await ReadWindowAsync(topic, start, cancellationToken);
            var accept = RowFilter.Compile(request.Filter, KafkaRows.ColumnNames, "Kafka");
            var rows = KafkaRows.ToResultSet(window);
            var matches = window.Where((_, i) => accept(rows.Rows[i])).ToList();
            page = KafkaRows.Page(matches, request.Offset, request.Limit, newestFirst);
            complete = done;
        }

        if (newestFirst)
        {
            page.Reverse();
        }

        return KafkaRows.ToResultSet(page, !complete);
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        if (filter.IsEmpty)
        {
            // High minus low watermark counts offsets, which on compacted or transactional topics is an upper bound.
            var topic = Cluster.Topic(table.Name);
            var marks = await Cluster.WatermarksAsync(topic.Partitions.Select(p => new TopicPartition(table.Name, p.PartitionId)).ToList(), cancellationToken);
            return marks.Values.Sum(m => m.High - m.Low);
        }

        var (window, _) = await ReadWindowAsync(table.Name, KafkaStart.Oldest, cancellationToken);
        var accept = RowFilter.Compile(filter, KafkaRows.ColumnNames, "Kafka");
        var rows = KafkaRows.ToResultSet(window);
        return rows.Rows.Count(row => accept(row));
    }

    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Yield();
        var messages = KafkaWrites.Prepare(changes);
        foreach (var outgoing in messages)
        {
            var delivery = outgoing.Partition is { } partition
                ? Cluster.Producer.ProduceAsync(new TopicPartition(table.Name, partition), outgoing.Message, cancellationToken)
                : Cluster.Producer.ProduceAsync(table.Name, outgoing.Message, cancellationToken);
            await delivery;
        }

        return messages.Count;
    }

    /// <summary>
    /// Deleting a topic from the sidebar, in KafkaQL for the review sheet, as macOS offers it. Kafka has no rename and
    /// no truncate: deleting records up to an offset is per partition and leaves retention to remove them, which is not
    /// what Truncate promises, so neither is offered.
    /// </summary>
    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) => TopicDdl(table, change);

    internal static IReadOnlyList<string> TopicDdl(ObjectName table, SchemaChange change) =>
        change is DropObject { Object.Kind: ObjectKind.Topic } ? ["DROP TOPIC " + KafkaQL.Quote(table.Name)] : [];

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IQueryChannel>(new KafkaChannel(Cluster));

    public async Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken)
    {
        await Yield();
        var listing = await Cluster.Admin.ListConsumerGroupsAsync(new ListConsumerGroupsOptions { RequestTimeout = Cluster.RequestTimeout }).WaitAsync(cancellationToken);
        var ids = listing.Valid.Select(g => g.GroupId).Order(StringComparer.Ordinal).ToList();
        var rows = new List<object?[]>(ids.Count);
        if (ids.Count > 0)
        {
            var described = await Cluster.Admin.DescribeConsumerGroupsAsync(ids, new DescribeConsumerGroupsOptions { RequestTimeout = Cluster.RequestTimeout }).WaitAsync(cancellationToken);
            var committed = new Dictionary<string, List<TopicPartitionOffsetError>>(StringComparer.Ordinal);
            foreach (var id in ids)
            {
                // librdkafka lists one group's offsets per call.
                var offsets = await Cluster.Admin.ListConsumerGroupOffsetsAsync(
                    [new ConsumerGroupTopicPartitions(id, null)],
                    new ListConsumerGroupOffsetsOptions { RequestTimeout = Cluster.RequestTimeout }).WaitAsync(cancellationToken);
                committed[id] = offsets.SelectMany(o => o.Partitions).ToList();
            }

            var partitions = committed.Values.SelectMany(p => p.Select(o => o.TopicPartition)).Distinct().ToList();
            var ends = await Cluster.WatermarksAsync(partitions, cancellationToken);
            foreach (var group in described.ConsumerGroupDescriptions.OrderBy(g => g.GroupId, StringComparer.Ordinal))
            {
                var offsets = committed.GetValueOrDefault(group.GroupId) ?? [];
                rows.Add(
                [
                    group.GroupId,
                    group.State.ToString(),
                    group.Members.Count,
                    string.IsNullOrEmpty(group.PartitionAssignor) ? null : group.PartitionAssignor,
                    string.Join(", ", offsets.Select(o => o.Topic).Distinct().Order(StringComparer.Ordinal)),
                    KafkaActivity.Lag(offsets.Select(o => (o.TopicPartition, o.Offset.Value)), ends),
                ]);
            }
        }

        return new ResultSet(KafkaActivity.Columns, rows);
    }

    public async Task TerminateAsync(object processId, CancellationToken cancellationToken)
    {
        await Yield();
        var group = Convert.ToString(processId, CultureInfo.InvariantCulture) ?? throw new ArgumentNullException(nameof(processId));
        var described = await Cluster.Admin.DescribeConsumerGroupsAsync([group], new DescribeConsumerGroupsOptions { RequestTimeout = Cluster.RequestTimeout }).WaitAsync(cancellationToken);
        var description = described.ConsumerGroupDescriptions.FirstOrDefault() ?? throw new InvalidOperationException($"There is no consumer group named {group}.");
        KafkaActivity.EnsureDeletable(description.GroupId, description.State, description.Members.Count);
        await Cluster.Admin.DeleteGroupsAsync([group], new DeleteGroupsOptions { RequestTimeout = Cluster.RequestTimeout }).WaitAsync(cancellationToken);
    }

    public ValueTask DisposeAsync()
    {
        Cluster.Dispose();
        return ValueTask.CompletedTask;
    }

    /// <summary>The newest (or oldest) messages of every partition, as many as one read may hold.</summary>
    private async Task<(List<KafkaRecord> Window, bool Complete)> ReadWindowAsync(string topic, KafkaStart start, CancellationToken cancellationToken)
    {
        var partitionCount = Math.Max(1, Cluster.Topic(topic).Partitions.Count);
        var perPartition = Math.Max(1, KafkaCluster.MaxRead / partitionCount);
        return await Cluster.ReadMergedAsync(topic, start, 0, perPartition, null, BrowseBudget, cancellationToken);
    }

    private static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
}

/// <summary>The server dashboard's view of consumer groups. Pure.</summary>
internal static class KafkaActivity
{
    public static IReadOnlyList<ResultColumn> Columns { get; } =
    [
        new("group", "TEXT", typeof(string)),
        new("state", "TEXT", typeof(string)),
        new("members", "INTEGER", typeof(int)),
        new("assignor", "TEXT", typeof(string)),
        new("topics", "TEXT", typeof(string)),
        new("lag", "BIGINT", typeof(long)),
    ];

    /// <summary>
    /// Messages written but not yet committed by the group, summed over its partitions. A partition with no commit has
    /// no lag to speak of and is left out; null when the group has committed nothing.
    /// </summary>
    public static long? Lag(IEnumerable<(TopicPartition Partition, long Committed)> committed, IReadOnlyDictionary<TopicPartition, (long Low, long High)> ends)
    {
        long? total = null;
        foreach (var (partition, offset) in committed)
        {
            if (offset < 0 || !ends.TryGetValue(partition, out var end))
            {
                continue;
            }

            total = (total ?? 0) + Math.Max(0, end.High - Math.Max(offset, end.Low));
        }

        return total;
    }

    /// <summary>Kafka deletes only a group with no members; stopping someone's consumers is not this app's call.</summary>
    public static void EnsureDeletable(string group, ConsumerGroupState state, int members)
    {
        if (members > 0 || state is not (ConsumerGroupState.Empty or ConsumerGroupState.Dead))
        {
            throw new InvalidOperationException(
                $"Consumer group {group} is {state} with {members} member(s). Kafka only deletes a group with no members; stop its consumers first.");
        }
    }
}
