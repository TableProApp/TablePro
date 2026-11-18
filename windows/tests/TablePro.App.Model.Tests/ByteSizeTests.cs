using System.Globalization;

namespace TablePro.App.Model.Tests;

public sealed class ByteSizeTests
{
    [Theory]
    [InlineData(0, "0 bytes")]
    [InlineData(1023, "1023 bytes")]
    [InlineData(1024, "1 KB")]
    [InlineData(1536, "1.5 KB")]
    [InlineData(8192, "8 KB")]
    [InlineData(5_242_880, "5 MB")]
    [InlineData(1_610_612_736, "1.5 GB")]
    public void ASizeReadsAsFileExplorerWordsIt(long bytes, string expected) =>
        Assert.Equal(expected, ByteSize.Format(bytes, "{0} bytes", CultureInfo.InvariantCulture));

    [Fact]
    public void TheDecimalSeparatorIsTheCulturesOwn() =>
        Assert.Equal("1,5 KB", ByteSize.Format(1536, "{0} Bytes", CultureInfo.GetCultureInfo("de-DE")));
}

public sealed class LineBreaksTests
{
    [Theory]
    [InlineData("a\r\nb", "\r\n")]
    [InlineData("a\nb", "\n")]
    [InlineData("a\rb", "\r")]
    [InlineData("ab", "\n")]
    [InlineData(null, "\n")]
    public void AValueKeepsItsOwnLineBreak(string? original, string expected) => Assert.Equal(expected, LineBreaks.Of(original));

    [Fact]
    public void TheBoxsBreaksGoBackToTheValuesStyle()
    {
        Assert.Equal("one\r\ntwo\r\nthree", LineBreaks.Restore("one\rtwo\r\nthree", "\r\n"));
        Assert.Equal("one\ntwo", LineBreaks.Restore("one\rtwo", "\n"));
    }
}
