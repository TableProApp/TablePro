using MongoDB.Bson;
using TablePro.Drivers.MongoDb.Documents;
using TablePro.Drivers.MongoDb.Shell;

namespace TablePro.Drivers.MongoDb.Tests;

public sealed class ResultAndScriptTests
{
    private static BsonDocument Doc(string json) => BsonDocument.Parse(json);

    [Fact]
    public void AnUpdateReplyBecomesMatchedModifiedAndUpserted()
    {
        var plan = new CommandPlan("shop", Doc("{update: 'users', updates: []}"), ReplyShape.Write);

        var outcome = ReplyResults.FromReply(plan, Doc("{n: 3, nModified: 1, upserted: [{index: 0, _id: 9}], ok: 1}"), 100);

        var result = Assert.Single(outcome.ResultSets);
        Assert.Equal(["acknowledged", "insertedCount", "matchedCount", "modifiedCount", "upsertedCount", "deletedCount", "insertedIds", "upsertedIds"], result.Columns.Select(c => c.Name));
        Assert.Equal([true, 0L, 2L, 1L, 1L, 0L, null, "[9]"], result.Rows[0]);
        Assert.Equal(2, outcome.RecordsAffected);
    }

    [Fact]
    public void AnInsertReplyNamesTheIdsItGave()
    {
        var plan = new CommandPlan("shop", Doc("{insert: 'users', documents: []}"), ReplyShape.Write, InsertedIds: [1, 2]);

        var result = ReplyResults.FromReply(plan, Doc("{n: 2, ok: 1}"), 100).ResultSets[0];

        Assert.Equal(2L, result[0, 1]);
        Assert.Equal("[1, 2]", result[0, 6]);
    }

    [Fact]
    public void ADeleteReplyCountsDeletions()
    {
        var plan = new CommandPlan("shop", Doc("{delete: 'users', deletes: []}"), ReplyShape.Write);

        var outcome = ReplyResults.FromReply(plan, Doc("{n: 4, ok: 1}"), 100);

        Assert.Equal(4L, outcome.ResultSets[0][0, 5]);
        Assert.Equal(4, outcome.RecordsAffected);
    }

    [Fact]
    public void AWriteErrorIsTheStatementsError()
    {
        var plan = new CommandPlan("shop", Doc("{insert: 'users', documents: []}"), ReplyShape.Write);

        var error = Assert.Throws<ShellWriteException>(() => ReplyResults.FromReply(plan, Doc("{n: 0, writeErrors: [{index: 0, code: 11000, errmsg: 'E11000 duplicate key'}], ok: 1}"), 100));

        Assert.Contains("E11000", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void BulkCountsAddUp()
    {
        var tally = new WriteTally();
        tally.Add(Doc("{insert: 'a'}"), Doc("{n: 2}"), [1, 2]);
        tally.Add(Doc("{update: 'a'}"), Doc("{n: 1, nModified: 1}"), null);
        tally.Add(Doc("{delete: 'a'}"), Doc("{n: 3}"), null);

        Assert.Equal(2, tally.Inserted);
        Assert.Equal(1, tally.Matched);
        Assert.Equal(3, tally.Deleted);
        Assert.Equal(6, tally.Affected);
    }

    [Theory]
    [InlineData("{n: 12, ok: 1}", 12L)]
    [InlineData("{cursor: {firstBatch: [{_id: 1, n: 5}], id: 0}, ok: 1}", 5L)]
    [InlineData("{cursor: {firstBatch: [], id: 0}, ok: 1}", 0L)]
    public void CountsReadEitherForm(string reply, long expected)
    {
        Assert.Equal(expected, ReplyResults.Count(Doc(reply))[0, 0]);
    }

    [Fact]
    public void ACommandWithACursorShowsItsFirstBatch()
    {
        var plan = new CommandPlan("shop", Doc("{listIndexes: 'users'}"), ReplyShape.Auto);

        var outcome = ReplyResults.FromReply(plan, Doc("{cursor: {firstBatch: [{name: 'a'}, {name: 'b'}], id: NumberLong(7)}, ok: 1}"), 100);

        Assert.Equal(2, outcome.ResultSets[0].RowCount);
        Assert.True(outcome.ResultSets[0].IsTruncated);
        Assert.Single(outcome.Messages);
    }

    [Fact]
    public void OtherShapes()
    {
        var reply = ReplyResults.FromReply(new CommandPlan("shop", Doc("{ping: 1}"), ReplyShape.Auto), Doc("{ok: 1}"), 100);
        Assert.Equal("ok", reply.ResultSets[0].Columns[0].Name);

        var field = ReplyResults.FromReply(new CommandPlan("admin", Doc("{buildInfo: 1}"), ReplyShape.Field, "version"), Doc("{version: '8.0.1', ok: 1}"), 100);
        Assert.Equal("8.0.1", field.ResultSets[0][0, 0]);

        var values = ReplyResults.FromReply(new CommandPlan("shop", Doc("{distinct: 'u'}"), ReplyShape.Values, "values"), Doc("{values: ['a', 'b', 'c'], ok: 1}"), 2);
        Assert.Equal(2, values.ResultSets[0].RowCount);
        Assert.True(values.ResultSets[0].IsTruncated);

        var rows = ReplyResults.FromReply(new CommandPlan("admin", Doc("{currentOp: 1}"), ReplyShape.Rows, "inprog"), Doc("{inprog: [{opid: 1}, {opid: 2}], ok: 1}"), 100);
        Assert.Equal(2, rows.ResultSets[0].RowCount);

        var modified = ReplyResults.FromReply(new CommandPlan("shop", Doc("{findAndModify: 'u'}"), ReplyShape.FindAndModify), Doc("{value: {_id: 1, n: 2}, lastErrorObject: {n: 1}, ok: 1}"), 100);
        Assert.Equal(1, modified.RecordsAffected);
        Assert.Equal(2, modified.ResultSets[0][0, 1]);

        var missed = ReplyResults.FromReply(new CommandPlan("shop", Doc("{findAndModify: 'u'}"), ReplyShape.FindAndModify), Doc("{value: null, lastErrorObject: {n: 0}, ok: 1}"), 100);
        Assert.Empty(missed.ResultSets);
    }

    [Fact]
    public void TheDefinitionRecreatesOptionsValidatorAndIndexes()
    {
        var info = Doc("""
            {name: 'users', type: 'collection',
             options: {validator: {$jsonSchema: {bsonType: 'object', required: ['email']}}, validationLevel: 'strict', uuid: 1},
             info: {readOnly: false}}
            """);
        BsonDocument[] indexes =
        [
            Doc("{v: 2, key: {_id: 1}, name: '_id_'}"),
            Doc("{v: 2, key: {email: 1}, name: 'email_1', unique: true}"),
            Doc("{v: 2, key: {bio: 'text'}, name: 'bio_text', weights: {bio: 1}}"),
        ];

        var script = CollectionScript.Build(info, indexes);

        Assert.Equal(
            """
            db.createCollection("users", {
              "validator": {
                "$jsonSchema": {
                  "bsonType": "object",
                  "required": [
                    "email"
                  ]
                }
              },
              "validationLevel": "strict"
            });
            db.getCollection("users").createIndex({"email": 1}, {"name": "email_1", "unique": true});
            db.getCollection("users").createIndex({"bio": "text"}, {"name": "bio_text", "weights": {"bio": 1}});

            """.ReplaceLineEndings("\n"),
            script);

        // The script is one the editor runs: each statement plans without error.
        foreach (var statement in TablePro.Core.Sql.MongoDialect.Instance.Split(script))
        {
            ShellPlanner.Plan(statement.Text, "shop");
        }
    }

    [Fact]
    public void AViewIsRecreatedWithCreateView()
    {
        var info = Doc("{name: 'adults', type: 'view', options: {viewOn: 'users', pipeline: [{$match: {age: {$gte: 18}}}]}}");

        var script = CollectionScript.Build(info, []);

        Assert.StartsWith("db.createView(\"adults\", \"users\", [", script, StringComparison.Ordinal);
        var plan = Assert.IsType<CommandPlan>(ShellPlanner.Plan(script.TrimEnd().TrimEnd(';'), "shop"));
        Assert.Equal("users", plan.Command["viewOn"].AsString);
    }

    [Fact]
    public void ACollectionWithoutOptionsIsOneCall()
    {
        Assert.Equal("db.createCollection(\"logs\");\n", CollectionScript.Build(Doc("{name: 'logs', type: 'collection', options: {}}"), []));
    }

    [Fact]
    public void CreateAndDropDatabaseAreShellStatementsTheChannelRuns()
    {
        var create = CollectionScript.CreateDatabase("crm");
        var drop = CollectionScript.DropDatabase("crm");

        Assert.Equal("db.getSiblingDB(\"crm\").createCollection(\"crm\")", create);
        Assert.Equal("crm", Assert.IsType<CommandPlan>(ShellPlanner.Plan(create, "shop")).Database);
        Assert.Equal(Doc("{dropDatabase: 1}"), Assert.IsType<CommandPlan>(ShellPlanner.Plan(drop, "shop")).Command);
    }
}
