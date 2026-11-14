using TablePro.DataGrid.Model;

namespace TablePro.App.Model.Tests;

public sealed class CellValueTests
{
    [Fact]
    public void JsonIsLaidOutOneMemberPerLineKeepingEscapesAndNumbersAsStored()
    {
        const string stored = """{"name":"Zoë","n":1.50,"e":1E+2,"list":[1,{"a":null}],"empty":{},"arr":[],"t":true}""";

        Assert.Equal(
            """
            {
              "name": "Zoë",
              "n": 1.50,
              "e": 1E+2,
              "list": [
                1,
                {
                  "a": null
                }
              ],
              "empty": {},
              "arr": [],
              "t": true
            }
            """.ReplaceLineEndings("\n"),
            JsonText.Indent(stored)?.Text);
        Assert.Equal(("[\n  \"Zoë 👋\"\n]", false), JsonText.Indent("  [\"Zoë 👋\"]"));
    }

    [Fact]
    public void ALayoutPastItsLimitStopsThereButStillChecksTheRest()
    {
        var nested = string.Concat(Enumerable.Repeat("[", 40)) + string.Join(',', Enumerable.Repeat("1", 2_000))
            + string.Concat(Enumerable.Repeat("]", 40));

        var (laid, cut) = JsonText.Indent(nested, 10_000)!.Value;

        Assert.True(cut);
        Assert.Equal(10_000, laid.Length);
        Assert.Null(JsonText.Indent(nested + ",", 10_000));
        Assert.False(JsonText.Indent(nested)!.Value.Cut);
    }

    [Theory]
    [InlineData("{\"a\":")]
    [InlineData("42")]
    [InlineData("\"text\"")]
    [InlineData("{} x")]
    [InlineData("// note\n{}")]
    [InlineData("plain text")]
    public void TextThatIsNotOneObjectOrArrayHasNoJsonView(string text) => Assert.Null(JsonText.Indent(text));

    [Fact]
    public void BinaryShowsAndCopiesItsHexUpToItsLimitAndOnlyAWholeValueIsAPicture()
    {
        var small = new CellValue("body", null, false, new byte[] { 0xde, 0xad }, 2, IsDefault: false);
        var large = new CellValue("body", null, false, new byte[CellValue.MaximumHexBytes + 1], 40_000_000, IsDefault: false);

        Assert.Equal(("0xdead", false), small.Hex());
        Assert.Equal("0xdead", small.CopyText());
        Assert.True(small.IsWholeBinary);
        var (hex, cut) = large.Hex();
        Assert.True(cut);
        Assert.Equal(2 + (CellValue.MaximumHexBytes * 2), hex.Length);
        Assert.Equal(hex, large.CopyText());
        Assert.False(large.IsWholeBinary);
        Assert.False(small.IsNull);
        Assert.Null(small.Json());
    }

    [Fact]
    public void LongTextKeepsItsStartWithoutSplittingACharacterAndHasNoJsonLayout()
    {
        var text = "[" + new string('1', CellValue.MaximumShownCharacters - 2) + "👋" + "]";

        var value = CellValue.Of("note", text);

        Assert.True(value.TextCut);
        Assert.Equal(CellValue.MaximumShownCharacters - 1, value.Text!.Length);
        Assert.Equal(value.Text, value.CopyText());
        Assert.Null(value.Json());
        Assert.False(CellValue.Of("note", "[1]").TextCut);
        Assert.True(CellValue.Of("note", null).IsNull);
        Assert.False(new CellValue("note", null, false, null, 0, IsDefault: true).IsNull);
        Assert.False(new CellValue("note", null, false, null, 0, IsDefault: true).CanCopy);
    }

    [Fact]
    public void ACellTheAppHoldsReadsThroughTheGridsData()
    {
        var data = new TextGridData(["doc", "note"], [["{\"a\":1}", null]]);

        var doc = CellValue.Read(data, null, 0, 0)!;

        Assert.Equal(CellValue.Of("doc", "{\"a\":1}"), doc);
        Assert.Equal(("{\n  \"a\": 1\n}", false), doc.Json());
        Assert.True(CellValue.Read(data, null, 0, 1)!.IsNull);
        Assert.Null(CellValue.Read(data, null, 1, 0));
        Assert.Null(CellValue.Read(data, null, 0, 2));
    }
}
