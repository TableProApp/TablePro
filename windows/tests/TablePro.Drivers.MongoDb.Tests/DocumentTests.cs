using MongoDB.Bson;
using TablePro.Drivers.MongoDb.Documents;

namespace TablePro.Drivers.MongoDb.Tests;

public sealed class DocumentTests
{
    private static readonly ObjectId Id = new("507f1f77bcf86cd799439011");

    [Fact]
    public void InfersColumnsFromSampleDocumentsWithIdFirst()
    {
        BsonDocument[] documents =
        [
            new() { { "name", "Ada" }, { "_id", Id }, { "age", 36 } },
            new() { { "_id", ObjectId.GenerateNewId() }, { "age", new BsonInt64(5_000_000_000) }, { "tags", new BsonArray { "x" } }, { "mixed", 1 } },
            new() { { "_id", ObjectId.GenerateNewId() }, { "name", BsonNull.Value }, { "mixed", "one" }, { "born", new BsonDateTime(0) }, { "rich", true } },
        ];

        var columns = FieldCensus.FromDocuments(documents).Columns(ensureId: false);

        Assert.Equal(["_id", "name", "age", "tags", "mixed", "born", "rich"], columns.Select(c => c.Name));
        Assert.Equal(FieldKind.ObjectId, columns[0].Kind);
        Assert.Equal(FieldKind.String, columns[1].Kind);
        Assert.Equal(FieldKind.Long, columns[2].Kind);
        Assert.Equal(typeof(long), columns[2].ClrType);
        Assert.Equal(FieldKind.Json, columns[3].Kind);
        Assert.Equal("array", columns[3].DataType);
        Assert.Equal(FieldKind.Json, columns[4].Kind);
        Assert.Equal("mixed", columns[4].DataType);
        Assert.Equal(FieldKind.Date, columns[5].Kind);
        Assert.Equal(FieldKind.Bool, columns[6].Kind);
    }

    [Fact]
    public void OnlyTheFirstThousandDocumentsAreSampled()
    {
        var documents = Enumerable.Range(0, 1001).Select(i => i < 1000 ? new BsonDocument("a", i) : new BsonDocument("late", i));

        var columns = FieldCensus.FromDocuments(documents).Columns(ensureId: false);

        Assert.Equal(["a"], columns.Select(c => c.Name));
    }

    [Theory]
    [InlineData(new[] { "int" }, "Int")]
    [InlineData(new[] { "int", "long" }, "Long")]
    [InlineData(new[] { "int", "double", "null" }, "Double")]
    [InlineData(new[] { "decimal", "int" }, "Decimal")]
    [InlineData(new[] { "string", "null" }, "String")]
    [InlineData(new[] { "string", "int" }, "Json")]
    [InlineData(new[] { "object" }, "Json")]
    [InlineData(new[] { "binData" }, "Json")]
    [InlineData(new[] { "timestamp" }, "Json")]
    [InlineData(new[] { "null" }, "Json")]
    [InlineData(new[] { "objectId" }, "ObjectId")]
    public void AFieldTakesTheTypeItsValuesShare(string[] types, string expected)
    {
        Assert.Equal(expected, FieldCensus.SharedType(types).Kind.ToString());
    }

    [Fact]
    public void ReadsTheServersTallyInTheOrderDocumentsPlaceFields()
    {
        BsonDocument Tally(string name, string type, long position) =>
            new() { { "_id", new BsonDocument { { "name", name }, { "type", type } } }, { "position", position } };

        var columns = FieldCensus.FromTallies(
        [
            Tally("b", "string", 2),
            Tally("_id", "objectId", 0),
            Tally("a", "int", 1),
            Tally("a", "long", 3),
            Tally("c", "string", 1),
            Tally("c", "int", 4),
            new BsonDocument("junk", 1),
        ]).Columns(ensureId: true);

        Assert.Equal(["_id", "a", "c", "b"], columns.Select(c => c.Name));
        Assert.Equal(FieldKind.Long, columns[1].Kind);
        Assert.Equal(FieldKind.Json, columns[2].Kind);
    }

    [Fact]
    public void AnEmptyCollectionStillHasItsId()
    {
        var columns = FieldCensus.FromTallies([]).Columns(ensureId: true);

        var id = Assert.Single(columns);
        Assert.Equal("_id", id.Name);
        Assert.Equal(FieldKind.ObjectId, id.Kind);
    }

    [Fact]
    public void TheTallyPipelineGroupsFieldsAndTypesOnTheServer()
    {
        var pipeline = FieldCensus.TallyPipeline();

        Assert.Equal(["$limit", "$project", "$unwind", "$group"], pipeline.Select(s => s.GetElement(0).Name));
        Assert.Equal(1000, pipeline[0]["$limit"].AsInt32);
        Assert.Equal("$$ROOT", pipeline[1]["$project"]["field"]["$objectToArray"].AsString);
    }

    [Fact]
    public void FlattensDocumentsToTheColumnsWithMissingFieldsAsNull()
    {
        var schema = new CollectionSchema(
        [
            new FieldColumn("_id", FieldKind.ObjectId, "objectId"),
            new FieldColumn("n", FieldKind.Long, "long"),
            new FieldColumn("at", FieldKind.Date, "date"),
            new FieldColumn("price", FieldKind.Decimal, "decimal"),
            new FieldColumn("meta", FieldKind.Json, "object"),
            new FieldColumn("gone", FieldKind.String, "string"),
        ], keyed: true);
        var document = new BsonDocument
        {
            { "_id", Id },
            { "n", 3 },
            { "at", new BsonDateTime(new DateTime(2024, 5, 6, 7, 8, 9, DateTimeKind.Utc)) },
            { "price", new BsonDecimal128(12.5m) },
            { "meta", new BsonDocument { { "a", new BsonInt64(1) }, { "b", new BsonArray { 1, 2 } } } },
            { "extra", "not shown" },
        };

        var row = DocumentCells.Flatten(document, schema.Columns);

        Assert.Equal("507f1f77bcf86cd799439011", row[0]);
        Assert.Equal(3L, row[1]);
        Assert.Equal(new DateTime(2024, 5, 6, 7, 8, 9, DateTimeKind.Utc), row[2]);
        Assert.Equal(DateTimeKind.Utc, Assert.IsType<DateTime>(row[2]).Kind);
        Assert.Equal(12.5m, row[3]);
        Assert.Equal("{\"a\": {\"$numberLong\": \"1\"}, \"b\": [1, 2]}", row[4]);
        Assert.Null(row[5]);
    }

    [Fact]
    public void AValueOfAnotherTypeThanItsColumnShowsAsExtendedJsonAndGoesBackUnchanged()
    {
        var column = new FieldColumn("n", FieldKind.Int, "int");

        var cell = DocumentCells.ToCell(new BsonString("seven"), column);

        Assert.Equal("\"seven\"", cell);
        Assert.Equal(new BsonString("seven"), DocumentCells.FromCell(cell, column));
    }

    [Fact]
    public void JsonCellsRoundTripEveryType()
    {
        var column = new FieldColumn("v", FieldKind.Json, "mixed");
        BsonValue[] values =
        [
            new BsonInt64(1), new BsonInt32(1), new BsonDouble(1), new BsonString("1"), new BsonObjectId(Id),
            new BsonDocument("a", new BsonDateTime(1234)), new BsonArray { BsonNull.Value, true }, new BsonDecimal128(Decimal128.Parse("1.0")),
        ];

        foreach (var value in values)
        {
            Assert.Equal(value, DocumentCells.FromCell(DocumentCells.ToCell(value, column), column));
        }
    }

    [Fact]
    public void ObjectIdKeysRoundTrip()
    {
        var column = new FieldColumn("_id", FieldKind.ObjectId, "objectId");

        var cell = DocumentCells.ToCell(new BsonObjectId(Id), column);

        Assert.Equal(new BsonObjectId(Id), DocumentCells.FromCell(cell, column));

        // A string _id among ObjectIds shows quoted, and stays a string.
        var stringCell = DocumentCells.ToCell(new BsonString("507f1f77bcf86cd799439011"), column);
        Assert.Equal("\"507f1f77bcf86cd799439011\"", stringCell);
        Assert.Equal(new BsonString("507f1f77bcf86cd799439011"), DocumentCells.FromCell(stringCell, column));
    }

    [Fact]
    public void CellsOfNativeTypesBecomeTheirBson()
    {
        Assert.Equal(BsonNull.Value, DocumentCells.FromCell(null, null));
        Assert.Equal(new BsonInt32(5), DocumentCells.FromCell(5, null));
        Assert.Equal(new BsonInt64(5), DocumentCells.FromCell(5L, null));
        Assert.Equal(new BsonDouble(2.5), DocumentCells.FromCell(2.5, null));
        Assert.Equal(new BsonDecimal128(2.5m), DocumentCells.FromCell(2.5m, new FieldColumn("p", FieldKind.Decimal, "decimal")));
        Assert.Equal(BsonBoolean.True, DocumentCells.FromCell(true, null));
        Assert.Equal(new BsonBinaryData([1]), DocumentCells.FromCell(new byte[] { 1 }, null));

        // The grid shows dates in UTC, so a date typed without a zone is UTC.
        var typed = new DateTime(2024, 1, 2, 3, 4, 5, DateTimeKind.Unspecified);
        Assert.Equal(new DateTime(2024, 1, 2, 3, 4, 5, DateTimeKind.Utc), DocumentCells.FromCell(typed, new FieldColumn("at", FieldKind.Date, "date")).ToUniversalTime());
    }

    [Fact]
    public void AJsonCellThatDoesNotParseIsRefusedWithItsPlace()
    {
        var column = new FieldColumn("meta", FieldKind.Json, "object");

        var error = Assert.Throws<FormatException>(() => DocumentCells.FromCell("{a: }", column));

        Assert.Contains("meta holds JSON", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void QueryResultsUseTheUnionOfFieldsAndMarkTruncation()
    {
        var result = DocumentResults.Build(
        [
            new BsonDocument { { "_id", 1 }, { "a", "x" } },
            new BsonDocument { { "_id", 2 }, { "b", new BsonDocument("c", 1) } },
        ], truncated: true);

        Assert.Equal(["_id", "a", "b"], result.Columns.Select(c => c.Name));
        Assert.True(result.IsTruncated);
        Assert.Equal(2, result.RowCount);
        Assert.Null(result[0, 2]);
        Assert.Equal("{\"c\": 1}", result[1, 2]);
        Assert.Equal(typeof(int), result.Columns[0].ClrType);
    }

    [Fact]
    public void PreferredColumnsComeFirstAfterId()
    {
        var result = DocumentResults.Build([new BsonDocument { { "z", 1 }, { "opid", 2 }, { "_id", 3 } }], truncated: false, ["opid"]);

        Assert.Equal(["_id", "opid", "z"], result.Columns.Select(c => c.Name));
    }

    [Fact]
    public void NameValuesFlattenNestedDocumentsToPaths()
    {
        var result = DocumentResults.NameValues(new BsonDocument
        {
            { "host", "db1" },
            { "connections", new BsonDocument { { "current", 5 }, { "available", new BsonInt64(100) } } },
            { "list", new BsonArray { 1 } },
        });

        Assert.Equal(["host", "connections.current", "connections.available", "list"], result.Rows.Select(r => (string)r[0]!));
        Assert.Equal("5", result[1, 1]);
        Assert.Equal("[1]", result[3, 1]);
    }

    [Fact]
    public void StructureMarksIdAsTheKeyOnlyForKeyedCollections()
    {
        FieldColumn[] columns = [new("_id", FieldKind.ObjectId, "objectId"), new("a", FieldKind.Int, "int")];

        var keyed = new CollectionSchema(columns, keyed: true).ToColumnInfo();
        Assert.True(keyed[0].IsPrimaryKey);
        Assert.False(keyed[0].IsNullable);
        Assert.Equal("ObjectId()", keyed[0].DefaultValue);
        Assert.True(keyed[1].IsNullable);
        Assert.Equal(2, keyed[1].Ordinal);

        Assert.False(new CollectionSchema(columns, keyed: false).ToColumnInfo()[0].IsPrimaryKey);
    }
}
