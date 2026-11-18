using System.Globalization;
using System.Text.Json;
using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class RowsJsonTests
{
    [Fact]
    public void EachValueIsWrittenByItsKindKeepingNumbersAndNestedJsonAsStored()
    {
        var data = new TextGridData(
            ["id", "price", "big", "ratio", "flag", "doc", "blob", "note", "missing"],
            [["1", "12.50", "123456789012345678901234567890", "NaN", "true", "{\"a\":[1,2.0],\"a\":\"Zoë\"}", "0xdead",
                "a\tb", null]]);
        IReadOnlyList<ResultColumn> columns =
        [
            Column("id", ValueKind.Integer),
            Column("price", ValueKind.Decimal),
            Column("big", ValueKind.WideInteger),
            Column("ratio", ValueKind.Float),
            Column("flag", ValueKind.Bool),
            Column("doc", ValueKind.Json),
            Column("blob", ValueKind.Bytes),
            Column("note", ValueKind.Text),
            Column("missing", ValueKind.Text),
        ];

        var json = Write(data, null, columns, null);

        Assert.Equal(
            """
            [
              {
                "id": 1,
                "price": 12.50,
                "big": 123456789012345678901234567890,
                "ratio": "NaN",
                "flag": true,
                "doc": {
                  "a": [
                    1,
                    2.0
                  ],
                  "a": "Zoë"
                },
                "blob": "0xdead",
                "note": "a\tb",
                "missing": null
              }
            ]
            """.ReplaceLineEndings("\n"),
            json.Text);
        Assert.Equal(new RowsJson(json.Text, 1, 1, 0, false), json);
    }

    [Theory]
    [InlineData("0", true)]
    [InlineData("-0", true)]
    [InlineData("12.50", true)]
    [InlineData("1e5", true)]
    [InlineData("1E+2", true)]
    [InlineData("-1.5e-3", true)]
    [InlineData("01", false)]
    [InlineData("1.", false)]
    [InlineData(".5", false)]
    [InlineData("+1", false)]
    [InlineData("1e", false)]
    [InlineData("-", false)]
    [InlineData("", false)]
    [InlineData(" 1", false)]
    [InlineData("1,5", false)]
    [InlineData("NaN", false)]
    [InlineData("inf", false)]
    public void OnlyJsonsOwnNumberGrammarIsWrittenBare(string text, bool bare) =>
        Assert.Equal(bare, RowsJson.IsJsonNumber(text));

    [Fact]
    public void ACellsOwnKindDecidesWhereItsColumnHasNone()
    {
        var data = new TextGridData(["value"], [["{\"x\":1}"], ["{\"x\":1}"], ["7"], ["true"]]);

        var json = Write(
            data,
            null,
            [Column("value", ValueKind.Other)],
            new Kinds([ValueKind.Json], [ValueKind.Text], [ValueKind.Integer], [ValueKind.Bool]));

        Assert.Equal(
            """
            [
              {
                "value": {
                  "x": 1
                }
              },
              {
                "value": "{\"x\":1}"
              },
              {
                "value": 7
              },
              {
                "value": true
              }
            ]
            """.ReplaceLineEndings("\n"),
            json.Text);
    }

    [Fact]
    public void JsonThatDoesNotParseOrIsTooLongIsWrittenAsItsText()
    {
        var tooLong = "[" + string.Join(',', Enumerable.Repeat("1", (RowsJson.MaximumNestedCharacters / 2) + 1)) + "]";
        var data = new TextGridData(["broken", "long", "scalar", "count"], [["{\"a\":", tooLong, "5", "1,5"]]);

        var json = Write(
            data,
            null,
            [
                Column("broken", ValueKind.Json),
                Column("long", ValueKind.Json),
                Column("scalar", ValueKind.Json),
                Column("count", ValueKind.Integer),
            ],
            null);

        using var parsed = JsonDocument.Parse(json.Text);
        var row = parsed.RootElement[0];
        Assert.Equal("{\"a\":", row.GetProperty("broken").GetString());
        // Read again only up to the cap, so it goes out cut, as the grid shows a cut value.
        Assert.Equal(tooLong[..RowsJson.MaximumNestedCharacters] + CellBlock.Ellipsis, row.GetProperty("long").GetString());
        Assert.Equal(5, row.GetProperty("scalar").GetInt32());
        Assert.Equal("1,5", row.GetProperty("count").GetString());
    }

    [Fact]
    public void AnEditedCellTakesItsColumnsKindNotTheOldValues()
    {
        var rows = new TextGridData(["n"], [["old"], ["7"]]);
        var edits = new GridEdits(
            new Dictionary<(int Row, int Column), PendingCell> { [(0, 0)] = new(PendingKind.Value, "42") },
            new HashSet<int>(),
            []);
        var edited = new EditedGridData(rows, edits);

        var json = Write(edited, null, [Column("n", ValueKind.Integer)], new Kinds([ValueKind.Text], [ValueKind.Integer]));

        using var parsed = JsonDocument.Parse(json.Text);
        Assert.Equal(JsonValueKind.Number, parsed.RootElement[0].GetProperty("n").ValueKind);
        Assert.Equal(42, parsed.RootElement[0].GetProperty("n").GetInt32());
        Assert.Equal(7, parsed.RootElement[1].GetProperty("n").GetInt32());
    }

    [Fact]
    public void ABooleanInAnySpellingTheCoreReadsIsWrittenAsOne()
    {
        var rows = new TextGridData(["b"], [["1"], ["t"], ["maybe"], ["2"]]);
        var edits = new GridEdits(
            new Dictionary<(int Row, int Column), PendingCell> { [(1, 0)] = new(PendingKind.Value, "off") },
            new HashSet<int>(),
            []);

        var json = Write(new EditedGridData(rows, edits), null, [Column("b", ValueKind.Bool)], null);

        using var parsed = JsonDocument.Parse(json.Text);
        Assert.True(parsed.RootElement[0].GetProperty("b").GetBoolean());
        Assert.False(parsed.RootElement[1].GetProperty("b").GetBoolean());
        Assert.Equal("maybe", parsed.RootElement[2].GetProperty("b").GetString());
        Assert.Equal(2, parsed.RootElement[3].GetProperty("b").GetInt32());
    }

    [Fact]
    public void ATableTabsLayoutAndPendingEditsAreWrittenAsTheGridShowsThem()
    {
        var rows = new TextGridData(["id", "name", "note"], [["1", "a", "x"], ["2", "b", "y"], ["3", "c", "z"]]);
        var edits = new GridEdits(
            new Dictionary<(int Row, int Column), PendingCell>
            {
                [(0, 1)] = new(PendingKind.Value, "renamed"),
                [(2, 0)] = new(PendingKind.Default, string.Empty),
            },
            new HashSet<int> { 1 },
            [[new(PendingKind.Value, "4"), new(PendingKind.Value, "d"), new(PendingKind.Null, string.Empty)]]);
        var edited = new EditedGridData(rows, edits);
        edited.Arrange([1, 0]);
        IReadOnlyList<ResultColumn> columns =
            [Column("id", ValueKind.Integer), Column("name", ValueKind.Text), Column("note", ValueKind.Text)];

        var json = Write(edited, null, columns, null);

        Assert.Equal(
            """
            [
              {
                "name": "renamed",
                "id": 1
              },
              {
                "name": "c",
                "id": null
              },
              {
                "name": "d",
                "id": 4
              }
            ]
            """.ReplaceLineEndings("\n"),
            json.Text);
        Assert.Equal((3, 4, 1, false), (json.Rows, json.Total, json.Deleted, json.Capped));

        // Edits taken on the UI thread are the ones read, whatever the data holds by then.
        var before = Write(edited, GridEdits.None, columns, null);
        Assert.Equal((3, 3, 0), (before.Rows, before.Total, before.Deleted));
        Assert.Contains("\"name\": \"a\"", before.Text, StringComparison.Ordinal);
    }

    [Fact]
    public void ARepeatedColumnNameKeepsBothValues()
    {
        var json = Write(
            new TextGridData(["a", "a"], [["1", "2"]]),
            null,
            [Column("a", ValueKind.Integer), Column("a", ValueKind.Integer)],
            null);

        Assert.Equal("[\n  {\n    \"a\": 1,\n    \"a\": 2\n  }\n]", json.Text);
    }

    [Fact]
    public void SelectedRowsNarrowItAndRowsPastTheCapAreLeftOut()
    {
        var data = new TextGridData(
            ["n"],
            Enumerable.Range(0, RowsJson.MaximumRows + 5)
                .Select(n => new string?[] { n.ToString(CultureInfo.InvariantCulture) })
                .ToArray());
        IReadOnlyList<ResultColumn> columns = [Column("n", ValueKind.Integer)];

        var all = Write(data, null, columns, null);
        var some = Write(data, null, columns, null, firstRow: 2, rowCount: 3);

        Assert.Equal((RowsJson.MaximumRows, RowsJson.MaximumRows + 5, true), (all.Rows, all.Total, all.Capped));
        using (var parsed = JsonDocument.Parse(all.Text))
        {
            Assert.Equal(RowsJson.MaximumRows, parsed.RootElement.GetArrayLength());
            var last = parsed.RootElement[RowsJson.MaximumRows - 1];
            Assert.Equal(RowsJson.MaximumRows - 1, last.GetProperty("n").GetInt32());
        }

        Assert.Equal((3, RowsJson.MaximumRows + 5, false), (some.Rows, some.Total, some.Capped));
        using (var parsed = JsonDocument.Parse(some.Text))
        {
            Assert.Equal([2, 3, 4], parsed.RootElement.EnumerateArray().Select(row => row.GetProperty("n").GetInt32()));
        }
    }

    [Fact]
    public void RowsStopOnceTheTextPassesItsSizeAndTheLastWrittenIsWhole()
    {
        var large = new string('x', 90_000);
        var data = new TextGridData(["text"], [.. Enumerable.Repeat<IReadOnlyList<string?>>([large], 13)]);

        var json = Write(data, null, [Column("text", ValueKind.Text)], null);

        Assert.Equal((12, 13, true), (json.Rows, json.Total, json.Capped));
        using var parsed = JsonDocument.Parse(json.Text);
        Assert.Equal(large, parsed.RootElement[11].GetProperty("text").GetString());
    }

    [Fact]
    public void AWideRowOfDeepDocumentsStaysNearTheCap()
    {
        var deep = new string('[', 100) + string.Join(',', Enumerable.Repeat("0", 49_000)) + new string(']', 100);
        var names = Enumerable.Range(0, 128).Select(index => "c" + index.ToString(CultureInfo.InvariantCulture)).ToArray();
        var data = new TextGridData(names, [[.. names.Select(_ => deep)]]);

        var json = Write(data, null, [.. names.Select(name => Column(name, ValueKind.Json))], null);

        Assert.InRange(json.Text.Length, 1, 3 * RowsJson.MaximumBytes);
        using var parsed = JsonDocument.Parse(json.Text);
        Assert.Equal(JsonValueKind.String, parsed.RootElement[0].GetProperty("c0").ValueKind);
        Assert.Equal(deep, parsed.RootElement[0].GetProperty("c0").GetString());
    }

    [Fact]
    public void AValuePastTheCapIsReadOnlyThatFarAndGoesOutCut()
    {
        var huge = new string('x', RowsJson.MaximumNestedCharacters * 5);
        var data = new TextGridData(["text"], [[huge]]);

        var json = Write(data, null, [Column("text", ValueKind.Text)], null);

        using var parsed = JsonDocument.Parse(json.Text);
        Assert.Equal(huge[..RowsJson.MaximumNestedCharacters] + CellBlock.Ellipsis, parsed.RootElement[0].GetProperty("text").GetString());
    }

    [Fact]
    public void NoRowsAreAnEmptyArrayAndALongTextIsCutWithoutSplittingACharacter()
    {
        var json = Write(new TextGridData(["a"], []), null, [Column("a", ValueKind.Text)], null);
        var wave = new RowsJson("ab👋", 1, 1, 0, false);

        Assert.Equal(new RowsJson("[]", 0, 0, 0, false), json);
        Assert.Equal(("ab", true), wave.TextUpTo(3));
        Assert.Equal(("ab👋", false), wave.TextUpTo(4));
    }

    [Fact]
    public void ATreeHasARootPerRowAndMakesChildrenWhenAsked()
    {
        using var tree = JsonTree.Parse(
            """[{"id": 1, "name": "AC/DC", "tags": ["a", null], "doc": {"x": true}, "id": 2.50}, {"id": 2}]""");

        Assert.Equal(["[0]: {5}", "[1]: {1}"], tree.Roots.Select(node => node.Text));
        var fields = tree.Roots[0].Children();
        Assert.Equal(
            ["id: 1", "name: \"AC/DC\"", "tags: [2]", "doc: {1}", "id: 2.50"],
            fields.Select(node => node.Text));
        Assert.Equal(["[0]: \"a\"", "[1]: null"], fields[2].Children().Select(node => node.Text));
        Assert.Equal(JsonValueKind.True, fields[3].Children()[0].Kind);
        Assert.Equal((0, "1"), (fields[0].ChildCount, fields[0].Value));
        Assert.Empty(fields[0].Children());
    }

    [Fact]
    public void ATreeRowShowsALongValuesStart()
    {
        var text = new string('a', JsonTreeNode.MaximumValueCharacters * 2);

        using var tree = JsonTree.Parse($$"""[{"note": "{{text}}"}]""");

        var note = tree.Roots[0].Children()[0];
        Assert.Equal(JsonTreeNode.MaximumValueCharacters + 1, note.Value.Length);
        Assert.StartsWith("\"aaa", note.Value, StringComparison.Ordinal);
        Assert.EndsWith("…", note.Value, StringComparison.Ordinal);
    }

    private static ResultColumn Column(string name, ValueKind kind) => new(name, "type", kind);

    private sealed class Kinds(params ValueKind?[][] rows) : ICellKinds
    {
        public ValueKind? Kind(int row, int column) => row < rows.Length ? rows[row][column] : null;
    }

    private static RowsJson Write(
        IGridData data,
        GridEdits? edits,
        IReadOnlyList<ResultColumn> columns,
        ICellKinds? kinds,
        int firstRow = 0,
        int rowCount = int.MaxValue) =>
        RowsJson.Write(data, edits, columns, kinds, firstRow, rowCount, TestContext.Current.CancellationToken);
}
