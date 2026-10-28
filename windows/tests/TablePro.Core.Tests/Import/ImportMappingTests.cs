using System.Text;
using TablePro.Core.Connections;
using TablePro.Core.Import;

namespace TablePro.Core.Tests.Import;

public sealed class ImportMappingTests
{
    private static ImportField Field(string name, ImportFieldType type = ImportFieldType.Text) => new(name, null, type);

    private static ImportTargetColumn Column(string name, Type? type = null) => new(name, "text", type ?? typeof(string));

    private static Task<ImportPreview> Preview(string text, ImportFileFormat format, CsvImportOptions? options = null) =>
        ImportPreview.ReadAsync(new MemoryStream(Encoding.UTF8.GetBytes(text)), format, options, cancellationToken: TestContext.Current.CancellationToken);

    [Theory]
    [InlineData(new[] { "1", "-20", "" }, ImportFieldType.Integer)]
    [InlineData(new[] { "1", "2.5", "1e3" }, ImportFieldType.Real)]
    [InlineData(new[] { "yes", "No", "t" }, ImportFieldType.Boolean)]
    [InlineData(new[] { "1", "abc" }, ImportFieldType.Text)]
    [InlineData(new[] { "2024-01-02" }, ImportFieldType.Text)]
    [InlineData(new string[0], ImportFieldType.Text)]
    public void InfersTextFieldTypes(string[] values, ImportFieldType expected) => Assert.Equal(expected, ImportTypeInference.InferText(values));

    [Fact]
    public void InfersJsonFieldTypesFromTheirKinds()
    {
        Assert.Equal(ImportFieldType.Integer, ImportTypeInference.InferJson([1L, null, 2L]));
        Assert.Equal(ImportFieldType.Real, ImportTypeInference.InferJson([1L, 2.5m]));
        Assert.Equal(ImportFieldType.Boolean, ImportTypeInference.InferJson([true, false]));
        Assert.Equal(ImportFieldType.Json, ImportTypeInference.InferJson([new JsonText("{}"), new JsonText("[1]")]));
        Assert.Equal(ImportFieldType.Text, ImportTypeInference.InferJson(["12", 3L]));
    }

    [Fact]
    public void NamesBlankAndRepeatedHeaders() =>
        Assert.Equal(["id", "Column 2", "id 2", "name"], ImportFieldNaming.UniqueNames([" id ", "", "id", "name"]));

    [Fact]
    public async Task PreviewsCsvFieldsTypesAndFirstRows()
    {
        var preview = await Preview("id;name;price\n1;Ann;9.5\n2;;10\n", ImportFileFormat.Csv);

        Assert.Equal(["id", "name", "price"], preview.Fields.Select(f => f.Name));
        Assert.Equal([ImportFieldType.Integer, ImportFieldType.Text, ImportFieldType.Real], preview.Fields.Select(f => f.InferredType));
        Assert.Equal("Ann", preview.Fields[1].SampleValue);
        Assert.Equal(2, preview.Rows.Count);
        Assert.Equal(["2", null, "10"], preview.Rows[1]);
    }

    [Fact]
    public async Task CsvOptionsNameHeaderlessFieldsAndCleanValues()
    {
        var preview = await Preview(" a ,NULL\n b ,x\n", ImportFileFormat.Csv, new CsvImportOptions(Delimiter: ',', HasHeaderRow: false, TrimWhitespace: true, NullText: "NULL"));

        Assert.Equal(["Column 1", "Column 2"], preview.Fields.Select(f => f.Name));
        Assert.Equal(["a", null], preview.Rows[0]);
        Assert.Equal(["b", "x"], preview.Rows[1]);
    }

    [Fact]
    public async Task PreviewsJsonKeysInTheOrderTheyFirstAppear()
    {
        var preview = await Preview("[{\"b\": 1, \"a\": {\"x\": 1}}, {\"c\": true, \"b\": 2}]", ImportFileFormat.Json);

        Assert.Equal(["b", "a", "c"], preview.Fields.Select(f => f.Name));
        Assert.Equal([ImportFieldType.Integer, ImportFieldType.Json, ImportFieldType.Boolean], preview.Fields.Select(f => f.InferredType));
        Assert.Equal("{\"x\": 1}", preview.Rows[0][1]);
        Assert.Null(preview.Rows[1][1]);
    }

    [Theory]
    [InlineData("data.csv", ImportFileFormat.Csv)]
    [InlineData("data.TSV", ImportFileFormat.Csv)]
    [InlineData("rows.ndjson", ImportFileFormat.Json)]
    [InlineData("dump.sql", ImportFileFormat.Sql)]
    [InlineData("dump.sql.gz", ImportFileFormat.Sql)]
    public void DetectsTheFormatFromTheExtension(string path, ImportFileFormat format) => Assert.Equal(format, ImportFile.DetectFormat(path));

    [Fact]
    public void MatchesExactNamesBeforeCaseInsensitiveOnesAndEachColumnOnce()
    {
        var choices = ImportColumnMatcher.ByName(["Email", "email", "Name", "extra"], ["email", "name"]);

        Assert.Equal(ImportFieldChoice.Skipped, choices[0]);
        Assert.Equal("email", choices[1].MappedColumn);
        Assert.Equal("name", choices[2].MappedColumn);
        Assert.Null(choices[3].MappedColumn);
    }

    [Fact]
    public void MatchesByPosition()
    {
        var choices = ImportColumnMatcher.ByPosition(["x", "y", "z"], ["a", "b"]);
        Assert.Equal(["a", "b", null], choices.Select(c => c.MappedColumn));
    }

    [Fact]
    public void AHigherTierWinsAColumnWhateverTheFieldOrder()
    {
        var tier = new Dictionary<string, ImportFieldChoice> { ["second"] = new(true, "a") };
        var choices = ImportColumnMatcher.Resolve(["a", "second"], ["a", "b"], [tier]);

        Assert.Null(choices[0].MappedColumn);
        Assert.Equal("a", choices[1].MappedColumn);
    }

    [Fact]
    public void MappingReportsProblemsAndKeepsChoicesAcrossAReload()
    {
        var mapping = new ImportMapping([Field("id"), Field("name")], [Column("id", typeof(long)), Column("label")]);
        Assert.Equal("id", mapping[0].MappedColumn);
        Assert.Null(mapping[1].MappedColumn);
        Assert.Null(mapping.Problem);

        mapping[1] = new ImportFieldChoice(true, "id");
        Assert.True(mapping.MapsOneColumnTwice);
        Assert.Equal("Each column can be mapped from only one field.", mapping.Problem);

        mapping[1] = new ImportFieldChoice(true, "label");
        mapping.Reload([Field("name"), Field("id"), Field("new")]);
        Assert.Equal(["label", "id", null], mapping.Choices.Select(c => c.MappedColumn));

        mapping.SetAllIncluded(false);
        Assert.Equal("Map at least one field to a column.", mapping.Problem);
    }

    [Fact]
    public void RowBuilderParsesTextForTheColumnTypeAndSkipsMissingKeys()
    {
        var mapping = new ImportMapping([Field("id"), Field("tags"), Field("note")], [Column("id", typeof(long)), Column("tags"), Column("note")]);
        var row = mapping.CreateRowBuilder().Build(new Dictionary<string, object?> { ["id"] = "42", ["tags"] = new JsonText("[1]") });

        Assert.Equal(42L, row["id"]);
        Assert.Equal("[1]", row["tags"]);
        Assert.False(row.ContainsKey("note"));
    }

    [Fact]
    public void NewTableDraftKeepsEditsAcrossAReadAndBuildsTheDefinition()
    {
        var draft = new NewTableDraft();
        string Propose(ImportFieldType type) => ImportTypeMapper.SqlType(type, DatabaseEngine.PostgreSql);
        draft.Load([Field("id", ImportFieldType.Integer), Field("name"), Field("junk")], Propose);
        draft.Columns[0].Settings = draft.Columns[0].Settings with { IsPrimaryKey = true };
        draft.Columns[1].Settings = draft.Columns[1].Settings with { Name = "full_name", DefaultValue = "'n/a'" };
        draft.Columns[2].Settings = draft.Columns[2].Settings with { Include = false };

        // A wrong delimiter reads one field; correcting it brings the edits back.
        draft.Load([Field("id;name;junk")], Propose);
        draft.Load([Field("id", ImportFieldType.Integer), Field("name"), Field("junk")], Propose);

        var definition = draft.Definition();
        Assert.Equal(["id", "full_name"], definition.Select(c => c.Name));
        Assert.Equal("BIGINT", definition[0].DataType);
        Assert.True(definition[0].IsPrimaryKey);
        Assert.False(definition[0].IsNullable);
        Assert.Equal("'n/a'", definition[1].DefaultExpression);
        Assert.Equal("full_name", draft.ColumnMapping["name"]);
        Assert.Null(draft.Problem);

        draft.Columns[1].Settings = draft.Columns[1].Settings with { Name = "ID" };
        Assert.Equal("Column names must be unique.", draft.Problem);
    }

    [Fact]
    public void ChoosingTheShownTypeAgainInAnotherCaseIsNotAnEdit()
    {
        var column = new NewTableColumn(Field("n"), NewTableColumnSettings.Proposed("n", "BIGINT"));
        column.Settings = column.Settings with { Type = "bigint" };
        Assert.True(column.Edits.IsEmpty);
    }

    [Theory]
    [InlineData(ImportFieldType.Boolean, DatabaseEngine.MySql, null, "TINYINT(1)")]
    [InlineData(ImportFieldType.Text, DatabaseEngine.SqlServer, null, "NVARCHAR(MAX)")]
    [InlineData(ImportFieldType.Real, DatabaseEngine.Sqlite, null, "REAL")]
    [InlineData(ImportFieldType.Json, DatabaseEngine.PostgreSql, null, "JSONB")]
    [InlineData(ImportFieldType.Boolean, DatabaseEngine.Oracle, "Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production", "VARCHAR2(5 CHAR)")]
    [InlineData(ImportFieldType.Boolean, DatabaseEngine.Oracle, "Oracle Database 23ai Free Release 23.0.0.0.0", "BOOLEAN")]
    public void ProposesEngineTypes(ImportFieldType type, DatabaseEngine engine, string? version, string expected) =>
        Assert.Equal(expected, ImportTypeMapper.SqlType(type, engine, version));
}
