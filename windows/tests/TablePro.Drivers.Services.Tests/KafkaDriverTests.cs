using System.Text;
using Confluent.Kafka;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Sql;
using TablePro.Drivers.Kafka;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.Services.Tests;

public sealed class KafkaRowsTests
{
    private static KafkaRecord Record(int partition, long offset, long time, string? key = "k", string? value = "v", params (string, string?)[] headers) =>
        new(partition, offset, time, key is null ? null : Encoding.UTF8.GetBytes(key), value is null ? null : Encoding.UTF8.GetBytes(value),
            headers.Select(h => new KeyValuePair<string, byte[]?>(h.Item1, h.Item2 is null ? null : Encoding.UTF8.GetBytes(h.Item2))).ToArray());

    [Fact]
    public void MapsARecordToTheSixColumns()
    {
        var set = KafkaRows.ToResultSet([Record(2, 41, 1_700_000_000_123, "user-1", "{\"a\":1}", ("trace", "abc"))]);

        Assert.Equal(["partition", "offset", "timestamp", "key", "value", "headers"], set.Columns.Select(c => c.Name));
        Assert.Equal(typeof(int), set.Columns[0].ClrType);
        Assert.Equal(typeof(long), set.Columns[1].ClrType);
        Assert.Equal(typeof(DateTimeOffset), set.Columns[2].ClrType);
        Assert.Equal(typeof(string), set.Columns[3].ClrType);
        var row = set.Rows[0];
        Assert.Equal(2, row[0]);
        Assert.Equal(41L, row[1]);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1_700_000_000_123), row[2]);
        Assert.Equal("user-1", row[3]);
        Assert.Equal("{\"a\":1}", row[4]);
        Assert.Equal("{\"trace\":\"abc\"}", row[5]);
    }

    [Fact]
    public void ATombstoneStaysNullAndAnEmptyValueStaysEmpty()
    {
        var set = KafkaRows.ToResultSet([Record(0, 0, 1, value: null), Record(0, 1, 2, value: "")]);

        Assert.Null(set.Rows[0][4]);
        Assert.Equal(string.Empty, set.Rows[1][4]);
    }

    [Fact]
    public void OneBinaryPayloadMakesTheWholeColumnBytes()
    {
        var binary = new KafkaRecord(0, 1, 5, null, [0xFF, 0xFE], []);
        var set = KafkaRows.ToResultSet([Record(0, 0, 1), binary]);

        Assert.Equal(typeof(byte[]), set.Columns[4].ClrType);
        Assert.Equal("BLOB", set.Columns[4].DataType);
        Assert.Equal(Encoding.UTF8.GetBytes("v"), set.Rows[0][4]);
        Assert.Equal(new byte[] { 0xFF, 0xFE }, set.Rows[1][4]);
        Assert.Equal(typeof(string), set.Columns[3].ClrType);
    }

    [Fact]
    public void AMissingTimestampIsNull()
    {
        Assert.Null(KafkaRows.Timestamp(-1));
        Assert.Null(KafkaRows.Timestamp(0));
    }

    [Fact]
    public void HeadersWriteBinaryAsHexAndNullAsNull()
    {
        var json = KafkaRows.HeadersJson([new("bin", [0xC3, 0x28]), new("none", null), new("text", Encoding.UTF8.GetBytes("é\"q"))]);

        Assert.Equal("{\"bin\":\"C328\",\"none\":null,\"text\":\"é\\\"q\"}", json);
        Assert.Null(KafkaRows.HeadersJson([]));
    }

    [Fact]
    public void MergeOrdersByTimeThenPartitionThenOffset()
    {
        var merged = KafkaRows.Merge([Record(1, 5, 20), Record(0, 9, 10), Record(1, 4, 10), Record(0, 8, 10)]);

        Assert.Equal([(0, 8L), (0, 9L), (1, 4L), (1, 5L)], merged.Select(r => (r.Partition, r.Offset)));
    }

    [Fact]
    public void ForwardPagesSkipFromTheFront()
    {
        var ordered = Enumerable.Range(0, 10).Select(i => Record(0, i, i)).ToList();

        Assert.Equal([3L, 4L], KafkaRows.Page(ordered, 3, 2, readsBackward: false).Select(r => r.Offset));
    }

    [Fact]
    public void BackwardPagesSkipFromTheEnd()
    {
        var ordered = Enumerable.Range(0, 10).Select(i => Record(0, i, i)).ToList();

        Assert.Equal([5L, 6L, 7L], KafkaRows.Page(ordered, 2, 3, readsBackward: true).Select(r => r.Offset));
        Assert.Equal([0L, 1L], KafkaRows.Page(ordered, 8, 5, readsBackward: true).Select(r => r.Offset));
        Assert.Empty(KafkaRows.Page(ordered, 20, 5, readsBackward: true));
        Assert.Empty(KafkaRows.Page(ordered, 0, 0, readsBackward: false));
    }

    private static readonly Dictionary<int, (long Low, long High)> Marks = new() { [0] = (100, 1_000), [1] = (0, 5), [2] = (50, 50) };

    [Fact]
    public void OldestPlanReadsSkipPlusLimitFromEachLowWatermark()
    {
        var plan = KafkaRows.Plan(KafkaStart.Oldest, 10, 20, Marks);

        Assert.Equal([new PartitionRange(0, 100, 130), new PartitionRange(1, 0, 5)], plan);
    }

    [Fact]
    public void NewestPlanStepsBackFromEachHighWatermark()
    {
        var plan = KafkaRows.Plan(KafkaStart.Newest, 0, 10, Marks);

        Assert.Equal([new PartitionRange(0, 990, 1_000), new PartitionRange(1, 0, 5)], plan);
    }

    [Fact]
    public void OffsetPlanClampsToTheLog()
    {
        var plan = KafkaRows.Plan(new KafkaStart(KafkaStartKind.Offset, 3), 0, 4, Marks);

        Assert.Equal([new PartitionRange(0, 100, 104), new PartitionRange(1, 3, 5)], plan);
    }

    [Fact]
    public void TimePlanSkipsPartitionsWithNothingAfterTheTime()
    {
        var plan = KafkaRows.Plan(new KafkaStart(KafkaStartKind.Timestamp, 123), 0, 10, Marks, new Dictionary<int, long> { [0] = 500, [1] = -1 });

        Assert.Equal([new PartitionRange(0, 500, 510)], plan);
    }

    [Fact]
    public void AnchorAndTailPlansReadOnlyTheirPartitions()
    {
        var anchor = KafkaRows.Plan(new KafkaStart(KafkaStartKind.Anchor, 0, new Dictionary<int, long> { [0] = 200 }), 0, 10, Marks);
        var tail = KafkaRows.Plan(new KafkaStart(KafkaStartKind.Tail, 0, new Dictionary<int, long> { [0] = 300 }), 5, 10, Marks);

        Assert.Equal([new PartitionRange(0, 200, 210)], anchor);
        Assert.Equal([new PartitionRange(0, 285, 300)], tail);
    }

    [Fact]
    public void RowFilterMatchesValuesAndNumbersOverMessages()
    {
        var set = KafkaRows.ToResultSet([Record(0, 1, 1, value: "Hello"), Record(1, 2, 2, value: "bye")]);
        var contains = Kafka.RowFilter.Compile(new BrowseFilter([new FilterRule("value", FilterOperator.Contains, "HELL")]), KafkaRows.ColumnNames);
        var partition = Kafka.RowFilter.Compile(new BrowseFilter([new FilterRule("partition", FilterOperator.GreaterThan, "0")]), KafkaRows.ColumnNames);

        Assert.Equal([true, false], set.Rows.Select(contains));
        Assert.Equal([false, true], set.Rows.Select(partition));
        Assert.Throws<NotSupportedException>(() => Kafka.RowFilter.Compile(new BrowseFilter([], "offset > 3"), KafkaRows.ColumnNames));
    }
}

public sealed class KafkaSettingsTests
{
    [Fact]
    public void PlainConnectionUsesTheRequestEndpoint()
    {
        var config = KafkaSettings.Build(Requests.For(DatabaseEngine.Kafka, "broker.local", 9093));

        Assert.Equal("broker.local:9093", config.BootstrapServers);
        Assert.Equal(SecurityProtocol.Plaintext, config.SecurityProtocol);
        Assert.Null(config.SaslMechanism);
    }

    [Fact]
    public void BootstrapListOptionWins()
    {
        var config = KafkaSettings.Build(Requests.For(DatabaseEngine.Kafka, options: new() { ["bootstrapServers"] = "a:9092,b:9092" }));

        Assert.Equal("a:9092,b:9092", config.BootstrapServers);
    }

    [Theory]
    [InlineData(null, SaslMechanism.Plain)]
    [InlineData("SCRAM-SHA-256", SaslMechanism.ScramSha256)]
    [InlineData("scram_sha_512", SaslMechanism.ScramSha512)]
    public void UserNameTurnsOnSasl(string? mechanism, SaslMechanism expected)
    {
        var options = mechanism is null ? null : new Dictionary<string, string> { ["saslMechanism"] = mechanism };
        var config = KafkaSettings.Build(Requests.For(DatabaseEngine.Kafka, user: "alice", password: "pw", options: options));

        Assert.Equal(SecurityProtocol.SaslPlaintext, config.SecurityProtocol);
        Assert.Equal(expected, config.SaslMechanism);
        Assert.Equal("alice", config.SaslUsername);
        Assert.Equal("pw", config.SaslPassword);
    }

    [Theory]
    [InlineData(CoreSslMode.Required, false, null)]
    [InlineData(CoreSslMode.VerifyCa, true, SslEndpointIdentificationAlgorithm.None)]
    [InlineData(CoreSslMode.VerifyIdentity, true, SslEndpointIdentificationAlgorithm.Https)]
    public void SslModeSetsVerification(CoreSslMode mode, bool verify, SslEndpointIdentificationAlgorithm? identification)
    {
        var config = KafkaSettings.Build(Requests.For(DatabaseEngine.Kafka, user: "u", password: "p", ssl: mode));

        Assert.Equal(SecurityProtocol.SaslSsl, config.SecurityProtocol);
        Assert.Equal(verify, config.EnableSslCertificateVerification);
        Assert.Equal(identification, config.SslEndpointIdentificationAlgorithm);
    }

    [Fact]
    public void ExplicitProtocolAndDottedOptionsPassThrough()
    {
        var config = KafkaSettings.Build(Requests.For(DatabaseEngine.Kafka, options: new()
        {
            ["securityProtocol"] = "SSL",
            ["ssl.ca.location"] = @"C:\certs\ca.pem",
        }));

        Assert.Equal(SecurityProtocol.Ssl, config.SecurityProtocol);
        Assert.Equal(@"C:\certs\ca.pem", config.SslCaLocation);
    }

    [Fact]
    public void ReaderNeverCommitsAndUsesAThrowawayGroup()
    {
        var reader = KafkaSettings.Reader(KafkaSettings.Build(Requests.For(DatabaseEngine.Kafka)));
        var other = KafkaSettings.Reader(KafkaSettings.Build(Requests.For(DatabaseEngine.Kafka)));

        Assert.False(reader.EnableAutoCommit);
        Assert.False(reader.EnableAutoOffsetStore);
        Assert.True(reader.EnablePartitionEof);
        Assert.StartsWith("tablepro-reader-", reader.GroupId, StringComparison.Ordinal);
        Assert.NotEqual(reader.GroupId, other.GroupId);
    }

    [Fact]
    public void UnknownProtocolIsRefused()
    {
        Assert.Throws<ArgumentException>(() => KafkaSettings.Build(Requests.For(DatabaseEngine.Kafka, options: new() { ["securityProtocol"] = "TLS13" })));
    }
}

public sealed class KafkaWritesTests
{
    [Fact]
    public void AnInsertBecomesAMessage()
    {
        var outgoing = KafkaWrites.ToMessage(new Dictionary<string, object?>
        {
            ["key"] = "k",
            ["value"] = "v",
            ["headers"] = "{\"trace\":\"abc\",\"n\":1,\"gone\":null}",
            ["partition"] = 3L,
            ["timestamp"] = "1700000000000",
            ["offset"] = null,
        });

        Assert.Equal(3, outgoing.Partition);
        Assert.Equal("k"u8.ToArray(), outgoing.Message.Key);
        Assert.Equal("v"u8.ToArray(), outgoing.Message.Value);
        Assert.Equal(1_700_000_000_000, outgoing.Message.Timestamp.UnixTimestampMs);
        var headers = outgoing.Message.Headers.Select(h => (h.Key, h.GetValueBytes() is { } b ? Encoding.UTF8.GetString(b) : null)).ToArray();
        Assert.Equal([("trace", (string?)"abc"), ("n", "1"), ("gone", null)], headers);
    }

    [Fact]
    public void ANullValueIsATombstone()
    {
        var outgoing = KafkaWrites.ToMessage(new Dictionary<string, object?> { ["key"] = "k", ["value"] = null });

        Assert.Null(outgoing.Message.Value);
        Assert.Null(outgoing.Partition);
    }

    [Fact]
    public void UpdatesAndDeletesAreRefusedBeforeAnythingIsProduced()
    {
        var changes = new RowChange[]
        {
            new RowInsert(new Dictionary<string, object?> { ["value"] = "ok" }),
            new RowDelete(new Dictionary<string, object?> { ["partition"] = 0, ["offset"] = 1L }),
        };

        var error = Assert.Throws<NotSupportedException>(() => KafkaWrites.Prepare(changes));
        Assert.Contains("append-only", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void AnOffsetOrUnknownColumnIsRefused()
    {
        Assert.Throws<NotSupportedException>(() => KafkaWrites.ToMessage(new Dictionary<string, object?> { ["offset"] = 5L }));
        Assert.Throws<NotSupportedException>(() => KafkaWrites.ToMessage(new Dictionary<string, object?> { ["colour"] = "red" }));
        Assert.Throws<FormatException>(() => KafkaWrites.ToMessage(new Dictionary<string, object?> { ["headers"] = "[1,2]" }));
    }
}

public sealed class KafkaActivityTests
{
    private static readonly TopicPartition P0 = new("orders", 0);
    private static readonly TopicPartition P1 = new("orders", 1);

    [Fact]
    public void LagSumsWhatEachPartitionHasNotCommitted()
    {
        var ends = new Dictionary<TopicPartition, (long Low, long High)> { [P0] = (0, 100), [P1] = (50, 80) };

        Assert.Equal(40 + 30, KafkaActivity.Lag([(P0, 60), (P1, 10)], ends));
    }

    [Fact]
    public void AGroupThatCommittedNothingHasNoLag()
    {
        var ends = new Dictionary<TopicPartition, (long Low, long High)> { [P0] = (0, 100) };

        Assert.Null(KafkaActivity.Lag([(P0, -1001)], ends));
        Assert.Null(KafkaActivity.Lag([], ends));
    }

    [Fact]
    public void OnlyAnEmptyGroupMayBeDeleted()
    {
        KafkaActivity.EnsureDeletable("g", ConsumerGroupState.Empty, 0);
        KafkaActivity.EnsureDeletable("g", ConsumerGroupState.Dead, 0);

        var error = Assert.Throws<InvalidOperationException>(() => KafkaActivity.EnsureDeletable("g", ConsumerGroupState.Stable, 2));
        Assert.Contains("stop its consumers", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void TheDialectTreatsTailAsAReadAndCreateAsStructure()
    {
        Assert.Equal(StatementKind.Read, KafkaDialect.Instance.Classify("TAIL logs"));
        Assert.Equal(StatementKind.Write, KafkaDialect.Instance.Classify("PRODUCE t VALUE v"));
        Assert.Equal(StatementKind.Ddl, KafkaDialect.Instance.Classify("CREATE TOPIC t"));
    }
}

public sealed class KafkaNativeTests
{
    /// <summary>librdkafka is native; reading its version proves the win-x64 DLL from the package loads.</summary>
    [Fact]
    public void LibrdkafkaLoads()
    {
        Assert.True(Library.Version > 0);
        Assert.StartsWith("2.", Library.VersionString, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConnectsToARealBrokerWhenOneIsConfigured()
    {
        var bootstrap = Environment.GetEnvironmentVariable("TABLEPRO_KAFKA_BOOTSTRAP");
        Assert.SkipWhen(string.IsNullOrEmpty(bootstrap), "Set TABLEPRO_KAFKA_BOOTSTRAP to host:port to run against a broker.");

        var request = Requests.For(DatabaseEngine.Kafka, options: new() { ["bootstrapServers"] = bootstrap! });
        await using var session = await new KafkaDriver().ConnectAsync(request, TestContext.Current.CancellationToken);
        var topics = await session.GetObjectsAsync(null, TestContext.Current.CancellationToken);

        Assert.NotNull(topics);
    }
}
