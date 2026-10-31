using TablePro.Drivers.Kafka;

namespace TablePro.Drivers.Services.Tests;

public sealed class KafkaQLTests
{
    private static readonly int[] FirstThreePartitions = [0, 1, 2];

    [Fact]
    public void ConsumeDefaultsToTheOldestHundred()
    {
        var consume = Assert.IsType<KafkaConsume>(KafkaQL.Parse("CONSUME orders"));

        Assert.Equal("orders", consume.Topic);
        Assert.Equal(KafkaStartKind.Oldest, consume.Start.Kind);
        Assert.Equal(KafkaQL.DefaultLimit, consume.Limit);
        Assert.Equal(0, consume.Skip);
        Assert.Null(consume.Partitions);
    }

    [Theory]
    [InlineData("NEWEST", "Newest")]
    [InlineData("latest", "Newest")]
    [InlineData("END", "Newest")]
    [InlineData("OLDEST", "Oldest")]
    [InlineData("earliest", "Oldest")]
    [InlineData("BEGINNING", "Oldest")]
    [InlineData("START", "Oldest")]
    public void ConsumeReadsEveryStartWord(string word, string expected)
    {
        var consume = Assert.IsType<KafkaConsume>(KafkaQL.Parse($"CONSUME orders FROM {word}"));

        Assert.Equal(Enum.Parse<KafkaStartKind>(expected), consume.Start.Kind);
    }

    [Fact]
    public void ConsumeReadsEveryClause()
    {
        var consume = Assert.IsType<KafkaConsume>(KafkaQL.Parse("consume \"my topic\" from offset 42 partition 1 limit 10 skip 5;"));

        Assert.Equal("my topic", consume.Topic);
        Assert.Equal(new KafkaStart(KafkaStartKind.Offset, 42), consume.Start with { Offsets = null });
        Assert.Equal(1, Assert.Single(consume.Partitions!));
        Assert.Equal(10, consume.Limit);
        Assert.Equal(5, consume.Skip);
    }

    [Theory]
    [InlineData("CONSUME t PARTITION 0,1,2")]
    [InlineData("CONSUME t PARTITIONS (0, 1, 2)")]
    [InlineData("CONSUME t PARTITION 0 1 2")]
    public void PartitionListsTakeEverySpelling(string statement)
    {
        var consume = Assert.IsType<KafkaConsume>(KafkaQL.Parse(statement));

        Assert.Equal(FirstThreePartitions, consume.Partitions);
    }

    [Fact]
    public void OffsetWithoutFromIsSkip()
    {
        var consume = Assert.IsType<KafkaConsume>(KafkaQL.Parse("CONSUME t OFFSET 7"));

        Assert.Equal(7, consume.Skip);
        Assert.Equal(KafkaStartKind.Oldest, consume.Start.Kind);
    }

    [Fact]
    public void TimeTakesMillisecondsOrAnIsoInstant()
    {
        var millis = Assert.IsType<KafkaConsume>(KafkaQL.Parse("CONSUME t FROM TIME 1700000000000"));
        var iso = Assert.IsType<KafkaConsume>(KafkaQL.Parse("CONSUME t FROM TIMESTAMP '2023-11-14T22:13:20Z'"));

        Assert.Equal(KafkaStartKind.Timestamp, millis.Start.Kind);
        Assert.Equal(1_700_000_000_000, millis.Start.Value);
        Assert.Equal(1_700_000_000_000, iso.Start.Value);
    }

    [Fact]
    public void AnchorAndTailMapsReadPartitionOffsetPairs()
    {
        var anchor = Assert.IsType<KafkaConsume>(KafkaQL.Parse("CONSUME t FROM ANCHOR(0:120,1:80) LIMIT 50"));
        var tail = Assert.IsType<KafkaConsume>(KafkaQL.Parse("CONSUME t FROM TAIL(0:400)"));

        Assert.Equal(KafkaStartKind.Anchor, anchor.Start.Kind);
        Assert.Equal(120, anchor.Start.Offsets![0]);
        Assert.Equal(80, anchor.Start.Offsets[1]);
        Assert.Equal(KafkaStartKind.Tail, tail.Start.Kind);
        Assert.True(tail.Start.ReadsBackward);
        Assert.Equal(400, tail.Start.Offsets![0]);
    }

    [Fact]
    public void SelectIsSugarForConsume()
    {
        var consume = Assert.IsType<KafkaConsume>(KafkaQL.Parse("SELECT * FROM events LIMIT 3"));

        Assert.Equal("events", consume.Topic);
        Assert.Equal(3, consume.Limit);
    }

    [Fact]
    public void TailReadsTheNewest()
    {
        var tail = Assert.IsType<KafkaConsume>(KafkaQL.Parse("TAIL logs LIMIT 20 PARTITION 3"));

        Assert.Equal("logs", tail.Topic);
        Assert.Equal(KafkaStartKind.Newest, tail.Start.Kind);
        Assert.Equal(20, tail.Limit);
        Assert.Equal(3, Assert.Single(tail.Partitions!));
    }

    [Fact]
    public void ProduceReadsKeyValuePartitionAndBothHeaderSpellings()
    {
        var produce = Assert.IsType<KafkaProduce>(KafkaQL.Parse("PRODUCE INTO orders PARTITION 2 KEY 'k 1' VALUE \"say \\\"hi\\\"\" HEADER trace=abc HEADER \"content type\" json"));

        Assert.Equal("orders", produce.Topic);
        Assert.Equal(2, produce.Partition);
        Assert.Equal("k 1", produce.Key);
        Assert.Equal("say \"hi\"", produce.Value);
        Assert.Equal(new KeyValuePair<string, string>[] { new("trace", "abc"), new("content type", "json") }, produce.Headers);
    }

    [Fact]
    public void ProduceHeaderAssignmentKeepsQuotedEquals()
    {
        var produce = Assert.IsType<KafkaProduce>(KafkaQL.Parse("PRODUCE t VALUE v HEADER \"a=b\"=\"c=d\""));

        Assert.Equal(new KeyValuePair<string, string>[] { new("a=b", "c=d") }, produce.Headers);
    }

    [Fact]
    public void QuoteRoundTripsThroughTheParser()
    {
        const string value = "back\\slash \"quoted\" end\\";
        var produce = Assert.IsType<KafkaProduce>(KafkaQL.Parse($"PRODUCE t VALUE {KafkaQL.Quote(value)}"));

        Assert.Equal(value, produce.Value);
    }

    [Theory]
    [InlineData("SHOW TOPICS", "Topics")]
    [InlineData("show brokers", "Brokers")]
    [InlineData("SHOW GROUPS", "Groups")]
    [InlineData("SHOW CONSUMERS", "Groups")]
    [InlineData("SHOW CLUSTER", "Cluster")]
    public void ShowReadsEveryTarget(string statement, string target)
    {
        Assert.Equal(new KafkaShow(Enum.Parse<KafkaShowTarget>(target)), KafkaQL.Parse(statement));
    }

    [Fact]
    public void DescribeReadsTopicsAndGroups()
    {
        Assert.Equal(new KafkaDescribeTopic("orders"), KafkaQL.Parse("DESCRIBE TOPIC orders"));
        Assert.Equal(new KafkaDescribeGroup("billing"), KafkaQL.Parse("DESC GROUP \"billing\""));
    }

    [Fact]
    public void CreateTopicReadsPartitionsReplicationAndConfig()
    {
        var create = Assert.IsType<KafkaCreateTopic>(KafkaQL.Parse("CREATE TOPIC orders PARTITIONS 6 REPLICATION 3 CONFIG cleanup.policy=compact CONFIG retention.ms=1000"));

        Assert.Equal("orders", create.Topic);
        Assert.Equal(6, create.Partitions);
        Assert.Equal(3, create.Replication);
        Assert.Equal("compact", create.Config["cleanup.policy"]);
        Assert.Equal("1000", create.Config["retention.ms"]);
    }

    [Fact]
    public void CreateTopicLeavesBrokerDefaults()
    {
        var create = Assert.IsType<KafkaCreateTopic>(KafkaQL.Parse("CREATE TOPIC t"));

        Assert.Equal(-1, create.Partitions);
        Assert.Equal(-1, create.Replication);
        Assert.Empty(create.Config);
    }

    [Fact]
    public void DropReadsATopic()
    {
        Assert.Equal(new KafkaDropTopic("old"), KafkaQL.Parse("DROP TOPIC old"));
    }

    [Theory]
    [InlineData("", "Empty statement")]
    [InlineData("   ", "Empty statement")]
    [InlineData("UPDATE t", "is not a Kafka command")]
    [InlineData("CONSUME", "needs a topic")]
    [InlineData("CONSUME t FROM", "FROM needs")]
    [InlineData("CONSUME t FROM YESTERDAY", "is not a start position")]
    [InlineData("CONSUME t FROM OFFSET", "OFFSET needs a value")]
    [InlineData("CONSUME t FROM OFFSET x", "whole number")]
    [InlineData("CONSUME t FROM TIME tuesday", "is not a time")]
    [InlineData("CONSUME t FROM ANCHOR(0-1)", "is not a partition:offset pair")]
    [InlineData("CONSUME t LIMIT 0", "LIMIT must be between")]
    [InlineData("CONSUME t LIMIT 50001", "LIMIT must be between")]
    [InlineData("CONSUME t SKIP -1", "SKIP must be between")]
    [InlineData("CONSUME t SKIP 50001", "SKIP must be between")]
    [InlineData("CONSUME t PARTITION a", "is not a partition number")]
    [InlineData("CONSUME t PARTITION", "needs at least one partition")]
    [InlineData("CONSUME t WHERE x", "Unexpected WHERE")]
    [InlineData("TAIL", "TAIL needs a topic")]
    [InlineData("TAIL t SKIP 3", "Unexpected SKIP")]
    [InlineData("PRODUCE", "needs a topic")]
    [InlineData("PRODUCE t", "at least a VALUE or a KEY")]
    [InlineData("PRODUCE t VALUE", "VALUE needs a value")]
    [InlineData("PRODUCE t HEADER onlyname", "HEADER needs a value")]
    [InlineData("PRODUCE t VALUE v COLOR red", "Unexpected COLOR")]
    [InlineData("SHOW", "SHOW needs")]
    [InlineData("SHOW TABLES", "SHOW TABLES is not supported")]
    [InlineData("SHOW TOPICS now", "takes nothing after it")]
    [InlineData("DESCRIBE", "DESCRIBE needs GROUP or TOPIC")]
    [InlineData("DESCRIBE TABLE t", "DESCRIBE TABLE is not supported")]
    [InlineData("DESCRIBE TOPIC", "needs a name")]
    [InlineData("DESCRIBE TOPIC a b", "takes nothing after it")]
    [InlineData("CREATE TABLE t", "CREATE needs TOPIC")]
    [InlineData("CREATE TOPIC", "needs a topic name")]
    [InlineData("CREATE TOPIC t PARTITIONS 0", "at least 1")]
    [InlineData("CREATE TOPIC t REPLICATION 0", "at least 1")]
    [InlineData("CREATE TOPIC t CONFIG compact", "needs key=value")]
    [InlineData("CREATE TOPIC t SIZE 3", "Unexpected SIZE")]
    [InlineData("DROP TABLE t", "DROP needs TOPIC")]
    [InlineData("DROP TOPIC", "needs a topic name")]
    [InlineData("DROP TOPIC a b", "takes one topic name")]
    [InlineData("PRODUCE t VALUE \"open", "never closed")]
    public void RefusesWhatItCannotRead(string statement, string message)
    {
        var error = Assert.Throws<KafkaQLException>(() => KafkaQL.Parse(statement));

        Assert.Contains(message, error.Message, StringComparison.OrdinalIgnoreCase);
    }
}
