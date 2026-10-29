using TablePro.Core.Schema;
using TablePro.Drivers.Kafka;

namespace TablePro.Drivers.Services.Tests;

public sealed class KafkaTopicDdlTests
{
    [Fact]
    public void DeletingATopicIsQuotedKafkaQL()
    {
        var topic = new DatabaseObject(new ObjectName(null, "orders \"eu\""), ObjectKind.Topic, 10, "3 partitions");

        var statements = KafkaSession.TopicDdl(topic.Name, new DropObject(topic));

        Assert.Equal(["DROP TOPIC \"orders \\\"eu\\\"\""], statements);
        Assert.IsType<KafkaDropTopic>(KafkaQL.Parse(statements[0]));
        Assert.Equal("orders \"eu\"", ((KafkaDropTopic)KafkaQL.Parse(statements[0])).Topic);
    }

    [Fact]
    public void RenameAndTruncateAreNotOffered()
    {
        var name = new ObjectName(null, "orders");

        Assert.Empty(KafkaSession.TopicDdl(name, new RenameTable("orders2")));
        Assert.Empty(KafkaSession.TopicDdl(name, new TruncateTable()));
    }
}
