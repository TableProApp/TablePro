using MongoDB.Bson;
using TablePro.Drivers.MongoDb.Shell;

namespace TablePro.Drivers.MongoDb.Tests;

public sealed class SessionRulesTests
{
    [Theory]
    [InlineData("db.users.find({a: 1})", false)]
    [InlineData("db.users", false)]
    [InlineData("db.users.countDocuments({})", false)]
    [InlineData("db.users.aggregate([{$match: {}}])", false)]
    [InlineData("show dbs", false)]
    [InlineData("use crm", false)]
    [InlineData("db.users.insertOne({a: 1})", true)]
    [InlineData("db.users.updateMany({}, {$set: {a: 1}})", true)]
    [InlineData("db.users.deleteOne({a: 1})", true)]
    [InlineData("db.users.drop()", true)]
    [InlineData("db.users.aggregate([{$match: {}}, {$out: 'copy'}])", true)]
    [InlineData("db.runCommand({drop: 'users'})", true)]
    [InlineData("db.dropDatabase()", true)]
    public void ReadOnlyRefusesEverythingButReads(string statement, bool refused)
    {
        var plan = ShellPlanner.Plan(statement, "shop");

        Assert.Equal(refused, MongoQueryChannel.ReadOnlyRefusal(statement, plan) is not null);
    }

    [Theory]
    [InlineData("{setName: 'rs0', maxWireVersion: 17}", true)]
    [InlineData("{setName: 'rs0', maxWireVersion: 6}", false)]
    [InlineData("{msg: 'isdbgrid', maxWireVersion: 8}", true)]
    [InlineData("{msg: 'isdbgrid', maxWireVersion: 7}", false)]
    [InlineData("{maxWireVersion: 21}", false)]
    public void TransactionsNeedAReplicaSetOrShardedCluster(string hello, bool expected)
    {
        Assert.Equal(expected, MongoDbSession.SupportsTransactions(BsonDocument.Parse(hello)));
    }

    [Fact]
    public void OperationIdsKeepTheirTypeForKillOp()
    {
        Assert.Equal(new BsonInt32(5), MongoDbSession.OperationId(5));
        Assert.Equal(new BsonInt64(5_000_000_000), MongoDbSession.OperationId(5_000_000_000L));
        Assert.Equal(new BsonInt32(12), MongoDbSession.OperationId("12"));
        Assert.Equal(new BsonString("shard01:12"), MongoDbSession.OperationId("shard01:12"));
    }

    [Fact]
    public void IndexesListTheirKeysAndKind()
    {
        var id = MongoDbSession.ToIndexInfo(BsonDocument.Parse("{v: 2, key: {_id: 1}, name: '_id_'}"));
        Assert.True(id.IsPrimary);
        Assert.True(id.IsUnique);

        var compound = MongoDbSession.ToIndexInfo(BsonDocument.Parse("{v: 2, key: {a: 1, b: -1}, name: 'a_1_b_-1', unique: true}"));
        Assert.Equal(["a", "b"], compound.Columns);
        Assert.True(compound.IsUnique);
        Assert.False(compound.IsPrimary);
        Assert.Null(compound.Method);

        Assert.Equal("text", MongoDbSession.ToIndexInfo(BsonDocument.Parse("{key: {bio: 'text'}, name: 'bio_text'}")).Method);
    }

    [Fact]
    public void TheDriverServesMongoDb()
    {
        Assert.Equal([TablePro.Core.Connections.DatabaseEngine.MongoDb], new MongoDbDriver().Engines);
    }
}
