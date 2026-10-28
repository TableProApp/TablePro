using MongoDB.Bson;
using TablePro.Drivers.MongoDb.Shell;

namespace TablePro.Drivers.MongoDb.Tests;

public sealed class ShellPlannerTests
{
    private static T Plan<T>(string statement, string database = "shop")
        where T : ShellPlan => Assert.IsType<T>(ShellPlanner.Plan(statement, database));

    private static BsonDocument Doc(string json) => BsonDocument.Parse(json);

    [Fact]
    public void FindCollectsItsArgumentsAndChainedCursorCalls()
    {
        var plan = Plan<FindPlan>("db.users.find({age: {$gte: 18}}, {name: 1}).sort({name: 1}).skip(10).limit(5).toArray()");

        Assert.Equal("shop", plan.Database);
        Assert.Equal("users", plan.Collection);
        Assert.Equal(Doc("{age: {$gte: 18}}"), plan.Filter);
        Assert.Equal(Doc("{name: 1}"), plan.Spec.Projection);
        Assert.Equal(Doc("{name: 1}"), plan.Spec.Sort);
        Assert.Equal(10, plan.Spec.Skip);
        Assert.Equal(5, plan.Spec.Limit);
        Assert.False(plan.Single);
    }

    [Fact]
    public void ProjectAndOtherCursorOptionsApply()
    {
        var plan = Plan<FindPlan>("db.users.find().project({a: 1}).hint('a_1').maxTimeMS(500).batchSize(20).comment('x').collation({locale: 'fr'}).allowDiskUse()");

        Assert.Equal(Doc("{a: 1}"), plan.Spec.Projection);
        Assert.Equal("a_1", plan.Spec.Hint!.AsString);
        Assert.Equal(500, plan.Spec.MaxTimeMs);
        Assert.Equal(20, plan.Spec.BatchSize);
        Assert.Equal("x", plan.Spec.Comment!.AsString);
        Assert.Equal(Doc("{locale: 'fr'}"), plan.Spec.Collation);
        Assert.True(plan.Spec.AllowDiskUse);
    }

    [Fact]
    public void ABareCollectionFindsEveryDocument()
    {
        var plan = Plan<FindPlan>("db.users");

        Assert.Equal("users", plan.Collection);
        Assert.Empty(plan.Filter);
    }

    [Theory]
    [InlineData("db.system.users.find()", "admin", "system.users")]
    [InlineData("db.getCollection('order items').find()", "admin", "order items")]
    [InlineData("db['a.b'].find()", "admin", "a.b")]
    [InlineData("db.getSiblingDB('crm').contacts.find()", "crm", "contacts")]
    [InlineData("db.getSiblingDB('crm').getCollection('x-y').find()", "crm", "x-y")]
    [InlineData("db.getCollection('a').b.find()", "admin", "a.b")]
    public void NamesTheDatabaseAndCollectionEveryWay(string statement, string database, string collection)
    {
        var plan = Plan<FindPlan>(statement, "admin");

        Assert.Equal(database, plan.Database);
        Assert.Equal(collection, plan.Collection);
    }

    [Fact]
    public void FindOneReadsOneDocument()
    {
        var plan = Plan<FindPlan>("db.users.findOne({_id: ObjectId('507f1f77bcf86cd799439011')})");

        Assert.True(plan.Single);
        Assert.Equal(1, plan.Spec.Limit);
        Assert.Equal(BsonType.ObjectId, plan.Filter["_id"].BsonType);
    }

    [Fact]
    public void AggregateTakesAPipelineOrStagesAndAppendsChainedStages()
    {
        var plan = Plan<AggregatePlan>("db.orders.aggregate([{$match: {status: 'A'}}], {allowDiskUse: true}).sort({total: -1}).limit(3)");

        Assert.Equal("orders", plan.Collection);
        Assert.Equal(3, plan.Pipeline.Count);
        Assert.Equal(Doc("{$sort: {total: -1}}"), plan.Pipeline[1]);
        Assert.Equal(Doc("{$limit: 3}"), plan.Pipeline[2]);
        Assert.True(plan.Options["allowDiskUse"].AsBoolean);

        var stages = Plan<AggregatePlan>("db.orders.aggregate({$match: {}}, {$limit: 1})");
        Assert.Equal(2, stages.Pipeline.Count);
    }

    [Fact]
    public void CountDocumentsIsAnAggregationThatCounts()
    {
        var plan = Plan<CommandPlan>("db.users.countDocuments({active: true}, {skip: 1, limit: 10})");

        Assert.Equal(ReplyShape.Count, plan.Shape);
        Assert.Equal(
            Doc("{aggregate: 'users', pipeline: [{$match: {active: true}}, {$skip: 1}, {$limit: 10}, {$group: {_id: 1, n: {$sum: 1}}}], cursor: {}}"),
            plan.Command);
    }

    [Fact]
    public void CursorCountCountsTheFindFilter()
    {
        var plan = Plan<CommandPlan>("db.users.find({a: 1}).limit(5).count()");

        Assert.Equal(Doc("{$match: {a: 1}}"), plan.Command["pipeline"][0]);
        Assert.Equal(2, plan.Command["pipeline"].AsBsonArray.Count);

        var sized = Plan<CommandPlan>("db.users.find({a: 1}).skip(2).limit(5).size()");
        Assert.Equal(4, sized.Command["pipeline"].AsBsonArray.Count);
    }

    [Fact]
    public void EstimatedCountAndDistinct()
    {
        Assert.Equal(Doc("{count: 'users'}"), Plan<CommandPlan>("db.users.estimatedDocumentCount()").Command);

        var distinct = Plan<CommandPlan>("db.users.distinct('city', {active: true})");
        Assert.Equal(ReplyShape.Values, distinct.Shape);
        Assert.Equal(Doc("{distinct: 'users', key: 'city', query: {active: true}}"), distinct.Command);
    }

    [Fact]
    public void InsertsGiveEachDocumentAnIdItCanReport()
    {
        var plan = Plan<CommandPlan>("db.users.insertMany([{name: 'a'}, {_id: 7, name: 'b'}], {ordered: false})");

        Assert.Equal(ReplyShape.Write, plan.Shape);
        Assert.Equal("users", plan.Command["insert"].AsString);
        Assert.False(plan.Command["ordered"].AsBoolean);
        var documents = plan.Command["documents"].AsBsonArray;
        Assert.Equal("_id", documents[0].AsBsonDocument.GetElement(0).Name);
        Assert.Equal(BsonType.ObjectId, documents[0]["_id"].BsonType);
        Assert.Equal(7, documents[1]["_id"].AsInt32);
        Assert.Equal(new BsonArray { documents[0]["_id"], 7 }, plan.InsertedIds);
    }

    [Fact]
    public void UpdatesCarryTheirOptionsIntoTheCommand()
    {
        var plan = Plan<CommandPlan>("db.users.updateMany({a: 1}, {$set: {b: 2}}, {upsert: true, arrayFilters: [{'e.x': 1}], writeConcern: {w: 1}})");

        Assert.Equal(
            Doc("{update: 'users', updates: [{q: {a: 1}, u: {$set: {b: 2}}, multi: true, upsert: true, arrayFilters: [{'e.x': 1}]}], ordered: true, writeConcern: {w: 1}}"),
            plan.Command);
    }

    [Fact]
    public void UpdateOneTakesAPipelineAndReplaceOneADocument()
    {
        var pipeline = Plan<CommandPlan>("db.users.updateOne({}, [{$set: {a: 1}}])");
        Assert.IsType<BsonArray>(pipeline.Command["updates"][0]["u"]);
        Assert.False(pipeline.Command["updates"][0]["multi"].AsBoolean);

        var replace = Plan<CommandPlan>("db.users.replaceOne({_id: 1}, {name: 'x'})");
        Assert.Equal(Doc("{name: 'x'}"), replace.Command["updates"][0]["u"]);
    }

    [Theory]
    [InlineData("db.users.updateOne({}, {name: 'x'})", "needs update operators")]
    [InlineData("db.users.replaceOne({}, {$set: {a: 1}})", "without update operators")]
    [InlineData("db.users.deleteMany()", "needs a filter")]
    [InlineData("db.users.find('x')", "must be a document")]
    [InlineData("db.users.find().limit('x')", "needs a whole number")]
    [InlineData("db.users.insertOne()", "needs a document")]
    [InlineData("db.getCollection(5).find()", "as a quoted string")]
    [InlineData("db.users.dropIndex()", "needs the index name")]
    [InlineData("foo.bar()", "'foo' is not defined")]
    [InlineData("db", "db alone runs nothing")]
    [InlineData("db.users.find().limit", "Expected '(' after limit")]
    public void RefusesStatementsThatWouldNotDoWhatTheySay(string statement, string reason)
    {
        var error = Assert.Throws<ShellSyntaxException>(() => ShellPlanner.Plan(statement, "shop"));

        Assert.Contains(reason, error.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("db.users.find().forEach()")]
    [InlineData("db.users.insertOne({}).limit(1)")]
    [InlineData("db.users.watch()")]
    [InlineData("db.eval()")]
    [InlineData("rs.status()")]
    [InlineData("show profile")]
    public void RefusesWhatItDoesNotRun(string statement)
    {
        Assert.Throws<ShellUnsupportedException>(() => ShellPlanner.Plan(statement, "shop"));
    }

    [Fact]
    public void DeletesLimitToOneOrNone()
    {
        Assert.Equal(Doc("{delete: 'users', deletes: [{q: {a: 1}, limit: 1}], ordered: true}"), Plan<CommandPlan>("db.users.deleteOne({a: 1})").Command);
        Assert.Equal(Doc("{delete: 'users', deletes: [{q: {}, limit: 0}], ordered: true}"), Plan<CommandPlan>("db.users.deleteMany({})").Command);
        Assert.Equal(1, Plan<CommandPlan>("db.users.remove({a: 1}, true)").Command["deletes"][0]["limit"].AsInt32);
    }

    [Fact]
    public void FindOneAndFamilyBecomeFindAndModify()
    {
        var update = Plan<CommandPlan>("db.users.findOneAndUpdate({a: 1}, {$inc: {n: 1}}, {returnDocument: 'after', projection: {n: 1}, sort: {a: 1}, upsert: true})");
        Assert.Equal(ReplyShape.FindAndModify, update.Shape);
        Assert.Equal(
            Doc("{findAndModify: 'users', query: {a: 1}, update: {$inc: {n: 1}}, new: true, upsert: true, fields: {n: 1}, sort: {a: 1}}"),
            update.Command);

        var delete = Plan<CommandPlan>("db.users.findOneAndDelete({a: 1})");
        Assert.Equal(Doc("{findAndModify: 'users', query: {a: 1}, remove: true}"), delete.Command);

        var replace = Plan<CommandPlan>("db.users.findOneAndReplace({a: 1}, {a: 2})");
        Assert.False(replace.Command["new"].AsBoolean);
    }

    [Fact]
    public void BulkWriteRunsEachOperationAsItsOwnCommand()
    {
        var plan = Plan<BatchPlan>("""
            db.users.bulkWrite([
              {insertOne: {document: {a: 1}}},
              {updateOne: {filter: {a: 1}, update: {$set: {b: 1}}, upsert: true}},
              {replaceOne: {filter: {a: 2}, replacement: {a: 3}}},
              {deleteMany: {filter: {c: 1}}},
            ], {ordered: false})
            """);

        Assert.False(plan.Ordered);
        Assert.Equal(["insert", "update", "update", "delete"], plan.Steps.Select(s => s.Command.GetElement(0).Name));
        Assert.True(plan.Steps[1].Command["updates"][0]["upsert"].AsBoolean);
        Assert.Equal(0, plan.Steps[3].Command["deletes"][0]["limit"].AsInt32);
    }

    [Fact]
    public void IndexesAreCreatedWithTheServersNamesAndDropped()
    {
        var create = Plan<CommandPlan>("db.users.createIndex({email: 1, age: -1}, {unique: true})");
        Assert.Equal(Doc("{createIndexes: 'users', indexes: [{key: {email: 1, age: -1}, name: 'email_1_age_-1', unique: true}]}"), create.Command);

        var named = Plan<CommandPlan>("db.users.createIndex({bio: 'text'}, {name: 'bio_search'})");
        Assert.Equal("bio_search", named.Command["indexes"][0]["name"].AsString);

        Assert.Equal(Doc("{dropIndexes: 'users', index: 'email_1'}"), Plan<CommandPlan>("db.users.dropIndex('email_1')").Command);
        Assert.Equal(Doc("{dropIndexes: 'users', index: '*'}"), Plan<CommandPlan>("db.users.dropIndexes()").Command);
        Assert.IsType<ListIndexesPlan>(ShellPlanner.Plan("db.users.getIndexes()", "shop"));
    }

    [Fact]
    public void CollectionAdministration()
    {
        Assert.Equal(Doc("{drop: 'users'}"), Plan<CommandPlan>("db.users.drop()").Command);

        var rename = Plan<CommandPlan>("db.users.renameCollection('people', true)");
        Assert.Equal("admin", rename.Database);
        Assert.Equal(Doc("{renameCollection: 'shop.users', to: 'shop.people', dropTarget: true}"), rename.Command);

        Assert.Equal(Doc("{collStats: 'users'}"), Plan<CommandPlan>("db.users.stats()").Command);
        Assert.Equal(Doc("{create: 'logs', capped: true, size: 1024}"), Plan<CommandPlan>("db.createCollection('logs', {capped: true, size: 1024})").Command);
        Assert.Equal(
            Doc("{create: 'adults', viewOn: 'users', pipeline: [{$match: {age: {$gte: 18}}}]}"),
            Plan<CommandPlan>("db.createView('adults', 'users', [{$match: {age: {$gte: 18}}}])").Command);
    }

    [Fact]
    public void DatabaseCommands()
    {
        var run = Plan<CommandPlan>("db.runCommand({ping: 1})");
        Assert.Equal(ReplyShape.Auto, run.Shape);
        Assert.Equal("shop", run.Database);

        Assert.Equal("admin", Plan<CommandPlan>("db.adminCommand('listDatabases')").Database);
        Assert.Equal(Doc("{dropDatabase: 1}"), Plan<CommandPlan>("db.dropDatabase()").Command);
        Assert.Equal("crm", Plan<CommandPlan>("db.getSiblingDB('crm').dropDatabase()").Database);
        Assert.Equal("inprog", Plan<CommandPlan>("db.currentOp()").Field);
        Assert.Equal(Doc("{killOp: 1, op: 123}"), Plan<CommandPlan>("db.killOp(123)").Command);
        Assert.Equal("shop", Plan<MessagePlan>("db.getName()").Message);
        Assert.Equal(ReplyShape.Field, Plan<CommandPlan>("db.version()").Shape);
        Assert.True(Plan<ListCollectionsPlan>("db.getCollectionNames()").NamesOnly);
        Assert.Null(Plan<AggregatePlan>("db.aggregate([{$currentOp: {}}])").Collection);
    }

    [Fact]
    public void ExplainWrapsTheCommandItExplains()
    {
        var plan = Plan<CommandPlan>("db.users.find({a: 1}).sort({b: 1}).explain('executionStats')");

        Assert.Equal(Doc("{explain: {find: 'users', filter: {a: 1}, sort: {b: 1}}, verbosity: 'executionStats'}"), plan.Command);
    }

    [Fact]
    public void UseAndShow()
    {
        Assert.Equal("crm", Plan<UsePlan>("use crm").Database);
        Assert.IsType<ListDatabasesPlan>(ShellPlanner.Plan("show dbs", "shop"));
        Assert.Equal("shop", Plan<ListCollectionsPlan>("show collections").Database);
        Assert.Equal("users", Plan<CommandPlan>("show users").Field);
    }
}
