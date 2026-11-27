namespace TablePro.App.Model.Tests;

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
