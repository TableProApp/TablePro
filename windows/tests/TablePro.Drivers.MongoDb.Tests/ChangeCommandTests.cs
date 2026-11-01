using MongoDB.Bson;
using TablePro.Core.Editing;
using TablePro.Drivers.MongoDb.Documents;

namespace TablePro.Drivers.MongoDb.Tests;

public sealed class ChangeCommandTests
{
    private const string Hex = "507f1f77bcf86cd799439011";

    private static readonly CollectionSchema Schema = new(
    [
        new FieldColumn("_id", FieldKind.ObjectId, "objectId"),
        new FieldColumn("name", FieldKind.String, "string"),
        new FieldColumn("n", FieldKind.Long, "long"),
        new FieldColumn("meta", FieldKind.Json, "object"),
    ], keyed: true);

    private static BsonDocument Doc(string json) => BsonDocument.Parse(json);

    [Fact]
    public void AnEditSetsTheChangedFieldsOfTheDocumentItsIdNames()
    {
        var change = new RowUpdate(
            new Dictionary<string, object?> { ["_id"] = Hex, ["name"] = "stale" },
            new Dictionary<string, object?> { ["name"] = "Ada", ["n"] = 5L, ["meta"] = "{\"a\": {\"$numberLong\": \"1\"}}", ["gone"] = null });

        var step = ChangeCommands.Build("users", change, Schema);

        Assert.Equal(
            Doc($"{{update: 'users', updates: [{{q: {{_id: ObjectId('{Hex}')}}, u: {{$set: {{name: 'Ada', n: NumberLong(5), meta: {{a: NumberLong(1)}}, gone: null}}}}, multi: false, upsert: false}}], ordered: true}}"),
            step.Command);
        Assert.Equal(BsonType.Int64, step.Command["updates"][0]["u"]["$set"]["meta"]["a"].BsonType);
        Assert.StartsWith("db.getCollection(\"users\").updateOne({\"_id\": ObjectId(\"507f1f77bcf86cd799439011\")}", step.Shell, StringComparison.Ordinal);
    }

    [Fact]
    public void ANewRowLeavesTheIdToTheServerUnlessOneIsTyped()
    {
        var step = ChangeCommands.Build("users", new RowInsert(new Dictionary<string, object?> { ["n"] = 1L, ["name"] = "x" }), Schema);

        var document = step.Command["documents"][0].AsBsonDocument;
        Assert.Equal(["name", "n"], document.Names);
        Assert.Equal("users", step.Command["insert"].AsString);

        var typed = ChangeCommands.Build("users", new RowInsert(new Dictionary<string, object?> { ["_id"] = Hex, ["extra"] = 2 }), Schema);
        Assert.Equal(Doc($"{{_id: ObjectId('{Hex}'), extra: 2}}"), typed.Command["documents"][0]);
    }

    [Fact]
    public void ADeleteRemovesAtMostTheOneDocument()
    {
        var step = ChangeCommands.Build("users", new RowDelete(new Dictionary<string, object?> { ["_id"] = Hex }), Schema);

        Assert.Equal(Doc($"{{delete: 'users', deletes: [{{q: {{_id: ObjectId('{Hex}')}}, limit: 1}}], ordered: true}}"), step.Command);
        Assert.Equal($"db.getCollection(\"users\").deleteOne({{\"_id\": ObjectId(\"{Hex}\")}})", step.Shell);
    }

    [Fact]
    public void ARowWithoutAnIdIsMatchedByEveryColumn()
    {
        var schema = new CollectionSchema([new FieldColumn("a", FieldKind.Int, "int"), new FieldColumn("b", FieldKind.String, "string")], keyed: false);

        var filter = ChangeCommands.Filter(new Dictionary<string, object?> { ["a"] = 1, ["b"] = null }, schema);

        Assert.Equal(Doc("{a: 1, b: null}"), filter);
    }

    [Fact]
    public void TheIdCannotBeEdited()
    {
        var change = new RowUpdate(new Dictionary<string, object?> { ["_id"] = Hex }, new Dictionary<string, object?> { ["_id"] = "x" });

        Assert.Throws<InvalidOperationException>(() => ChangeCommands.Build("users", change, Schema));
    }

    [Fact]
    public void AnUnparsableJsonCellStopsTheSaveBeforeAnythingIsSent()
    {
        var change = new RowUpdate(new Dictionary<string, object?> { ["_id"] = Hex }, new Dictionary<string, object?> { ["meta"] = "{broken" });

        Assert.Throws<FormatException>(() => ChangeCommands.Build("users", change, Schema));
    }

    [Theory]
    [InlineData("{n: 1, ok: 1}", 1)]
    [InlineData("{n: 0, nModified: 0, ok: 1}", 0)]
    [InlineData("{ok: 1}", 0)]
    public void CountsTheDocumentsAWriteReached(string reply, int expected)
    {
        Assert.Equal(expected, ChangeCommands.Affected(Doc(reply), "stmt"));
    }

    [Fact]
    public void AWriteErrorOrUnmetWriteConcernFailsTheSave()
    {
        var duplicate = Assert.Throws<InvalidOperationException>(() => ChangeCommands.Affected(Doc("{n: 0, writeErrors: [{index: 0, code: 11000, errmsg: 'E11000 duplicate key'}], ok: 1}"), "stmt"));
        Assert.Contains("E11000", duplicate.Message, StringComparison.Ordinal);
        Assert.Contains("11000", duplicate.Message, StringComparison.Ordinal);

        Assert.Throws<InvalidOperationException>(() => ChangeCommands.Affected(Doc("{n: 1, writeConcernError: {code: 64, errmsg: 'waiting for replication timed out'}, ok: 1}"), "stmt"));
    }
}
