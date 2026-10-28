using System.Globalization;
using TablePro.Core.Results;

namespace TablePro.Core.Tests.Results;

public sealed class CellFormatterTests
{
    [Fact]
    public void NullAndDbNullShowNull()
    {
        Assert.Equal("NULL", CellFormatter.Format(null));
        Assert.Equal("NULL", CellFormatter.Format(DBNull.Value));
        Assert.Equal(CellFormatter.NullText, CellFormatter.FormatForCell(null));
    }

    [Fact]
    public void ScalarsFormatInvariantly()
    {
        var previous = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("de-DE");
        try
        {
            Assert.Equal("text", CellFormatter.Format("text"));
            Assert.Equal("true", CellFormatter.Format(true));
            Assert.Equal("false", CellFormatter.Format(false));
            Assert.Equal("42", CellFormatter.Format(42));
            Assert.Equal("-7", CellFormatter.Format(-7L));
            Assert.Equal("1234567.5", CellFormatter.Format(1234567.5m));
            Assert.Equal("0.1", CellFormatter.Format(0.1));
            Assert.Equal("1.5", CellFormatter.Format(1.5f));
            Assert.Equal("NaN", CellFormatter.Format(double.NaN));
            Assert.Equal("x", CellFormatter.Format('x'));
            Assert.Equal("0f8fad5b-d9cb-469f-a165-70867728950e", CellFormatter.Format(Guid.Parse("0f8fad5b-d9cb-469f-a165-70867728950e")));
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    [Fact]
    public void DatesShowIsoText()
    {
        Assert.Equal("2024-01-02", CellFormatter.Format(new DateTime(2024, 1, 2)));
        Assert.Equal("2024-01-02 00:00:00", CellFormatter.Format(new DateTime(2024, 1, 2, 0, 0, 0, DateTimeKind.Utc)));
        Assert.Equal("2024-01-02 03:04:05", CellFormatter.Format(new DateTime(2024, 1, 2, 3, 4, 5)));
        Assert.Equal("2024-01-02 03:04:05.1234567", CellFormatter.Format(new DateTime(2024, 1, 2, 3, 4, 5).AddTicks(1_234_567)));
        Assert.Equal("2024-01-02 03:04:05+02:00", CellFormatter.Format(new DateTimeOffset(2024, 1, 2, 3, 4, 5, TimeSpan.FromHours(2))));
        Assert.Equal("2024-01-02", CellFormatter.Format(new DateOnly(2024, 1, 2)));
        Assert.Equal("13:14:15.5", CellFormatter.Format(new TimeOnly(13, 14, 15, 500)));
        Assert.Equal("1.02:03:04", CellFormatter.Format(new TimeSpan(1, 2, 3, 4)));
    }

    [Fact]
    public void BytesShowAsHex()
    {
        Assert.Equal("0x0AFF", CellFormatter.Format(new byte[] { 0x0A, 0xFF }));
        Assert.Equal("0x", CellFormatter.Format(Array.Empty<byte>()));
    }

    [Fact]
    public void BytesAreTruncatedWithTheirLength()
    {
        var bytes = Enumerable.Range(0, 100).Select(i => (byte)i).ToArray();

        Assert.Equal("0x00010203… (100 bytes)", CellFormatter.FormatBytes(bytes, 4));
        Assert.Equal("0x0001", CellFormatter.FormatBytes([0, 1], 4));
        Assert.Equal("0x00010203", CellFormatter.FormatBytes([0, 1, 2, 3], 4));
    }

    [Fact]
    public void CellShowsAtMost64Bytes()
    {
        var big = Enumerable.Range(0, 100).Select(i => (byte)i).ToArray();
        var small = new byte[64];

        Assert.Equal("0x" + Convert.ToHexString(big, 0, 64) + "… (100 bytes)", CellFormatter.FormatForCell(big));
        Assert.Equal("0x" + new string('0', 128), CellFormatter.FormatForCell(small));
        Assert.Equal("0x" + Convert.ToHexString(big), CellFormatter.Format(big));
    }

    [Fact]
    public void ArraysShowAsBraces()
    {
        int[] numbers = [1, 2, 3];

        Assert.Equal("{1,2,3}", CellFormatter.Format(numbers));
        Assert.Equal("{a,NULL}", CellFormatter.Format(new object?[] { "a", null }));
        Assert.Equal("{}", CellFormatter.Format(Array.Empty<string>()));
    }

    [Fact]
    public void OtherObjectsUseToString() => Assert.Equal("custom", CellFormatter.Format(new Custom()));

    [Fact]
    public void CellFlattensLineBreaksAndTabs() =>
        Assert.Equal("a  b c d", CellFormatter.FormatForCell("a\r\nb\tc\nd"));

    [Fact]
    public void FullFormatKeepsLineBreaks() => Assert.Equal("a\nb", CellFormatter.Format("a\nb"));

    [Fact]
    public void ShortCellIsReturnedAsIs()
    {
        const string text = "plain";

        Assert.Same(text, CellFormatter.FormatForCell(text));
    }

    [Fact]
    public void LongCellIsTruncatedToThePreviewLength()
    {
        var text = new string('a', 400);

        var cell = CellFormatter.FormatForCell(text);

        Assert.Equal(CellFormatter.CellPreviewLength + 1, cell.Length);
        Assert.Equal(new string('a', CellFormatter.CellPreviewLength) + "…", cell);
    }

    [Fact]
    public void TextAtThePreviewLengthIsNotTruncated()
    {
        var text = new string('a', CellFormatter.CellPreviewLength);

        Assert.Equal(text, CellFormatter.FormatForCell(text));
    }

    [Fact]
    public void LongCellIsTruncatedThenFlattened()
    {
        var text = "line1\nline2\n" + new string('x', 500);

        var cell = CellFormatter.FormatForCell(text);

        Assert.StartsWith("line1 line2 x", cell, StringComparison.Ordinal);
        Assert.EndsWith("x…", cell, StringComparison.Ordinal);
        Assert.DoesNotContain('\n', cell);
    }

    [Fact]
    public void TruncationDoesNotSplitASurrogatePair()
    {
        var text = new string('a', CellFormatter.CellPreviewLength - 1) + "😀" + "tail";

        var cell = CellFormatter.FormatForCell(text);

        Assert.Equal(new string('a', CellFormatter.CellPreviewLength - 1) + "…", cell);
        Assert.All(cell, c => Assert.False(char.IsSurrogate(c)));
    }

    private sealed class Custom
    {
        public override string ToString() => "custom";
    }
}
