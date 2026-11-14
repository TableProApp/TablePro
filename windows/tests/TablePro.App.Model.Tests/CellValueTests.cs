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
    public void BinaryShowsAsHexUpToItsLimitAndCopiesWhole()
    {
        var small = new CellValue("body", null, [0xde, 0xad], IsDefault: false);
        var large = new CellValue("body", null, new byte[CellValue.MaximumHexBytes + 1], IsDefault: false);

        Assert.Equal(("0xdead", false), small.Hex());
        Assert.Equal("0xdead", small.CopyText());
        var (hex, cut) = large.Hex();
        Assert.True(cut);
        Assert.Equal(2 + (CellValue.MaximumHexBytes * 2), hex.Length);
        Assert.Equal(2 + ((CellValue.MaximumHexBytes + 1) * 2), large.CopyText()!.Length);
        Assert.False(small.IsNull);
        Assert.Null(small.Json());
    }

    [Fact]
    public void LongTextShowsItsStartWithoutSplittingACharacterAndCopiesWhole()
    {
        var text = new string('a', CellValue.MaximumShownCharacters - 1) + "👋" + "tail";
        var value = new CellValue("note", text, null, IsDefault: false);

        var (shown, cut) = value.ShownText();

        Assert.True(cut);
        Assert.Equal(CellValue.MaximumShownCharacters - 1, shown.Length);
        Assert.Equal(text, value.CopyText());
        Assert.Equal((string.Empty, false), new CellValue("note", null, null, IsDefault: false).ShownText());
        Assert.True(new CellValue("note", null, null, IsDefault: false).IsNull);
        Assert.False(new CellValue("note", null, null, IsDefault: true).IsNull);
    }

    [Fact]
    public void ACellReadsWholeThroughTheGridsData()
    {
        var data = new TextGridData(["doc", "note"], [["{\"a\":1}", null]]);

        var doc = CellValue.Read(data, null, 0, 0)!;

        Assert.Equal(new CellValue("doc", "{\"a\":1}", null, IsDefault: false), doc);
        Assert.Equal(("{\n  \"a\": 1\n}", false), doc.Json());
        Assert.True(CellValue.Read(data, null, 0, 1)!.IsNull);
        Assert.Null(CellValue.Read(data, null, 1, 0));
        Assert.Null(CellValue.Read(data, null, 0, 2));
    }
}
