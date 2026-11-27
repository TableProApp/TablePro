using System.Globalization;
using TablePro.Graphics;

namespace TablePro.Editor.Tests;

// The plural rules are the ICU that Windows ships; the words are the app's, which this host links.
public sealed class HostStringsTests
{
    [Theory]
    [InlineData("en-US", 1, "one")]
    [InlineData("EN-US", 1, "one")]
    [InlineData("en-US", 0, "other")]
    [InlineData("en-US", 2, "other")]
    [InlineData("fr-FR", 0, "one")]
    [InlineData("pl-PL", 1, "one")]
    [InlineData("pl-PL", 3, "few")]
    [InlineData("pl-PL", 22, "few")]
    [InlineData("pl-PL", 5, "many")]
    [InlineData("pl-PL", 12, "many")]
    [InlineData("ar", 0, "zero")]
    [InlineData("ar", 2, "two")]
    [InlineData("ja-JP", 1, "other")]
    public void ACountTakesTheCategoryOfItsLanguagesRules(string language, int count, string category) =>
        Assert.Equal(category, PluralRules.Select(language, count));

    [Fact]
    public void ACountPicksItsFormFromTheAppsStrings()
    {
        Assert.Equal("1 statement", HostStrings.Plural("StatementCount", 1, 1));
        Assert.Equal(
            string.Format(CultureInfo.CurrentCulture, "{0:N0} statements", 1_204),
            HostStrings.Plural("StatementCount", 1_204, 1_204));
        Assert.Equal("Undo", HostStrings.Get("EditorMenuUndo"));
        Assert.Equal(string.Empty, HostStrings.Get("NoSuchString"));
        Assert.Equal(string.Empty, HostStrings.Plural("NoSuchString", 2, 2));
    }

    [Fact]
    public void ASizeReadsAsFileExplorerWordsIt()
    {
        // Three digits and the unit in the user's language, such as "1.50 KB" or "1,50 Ko".
        Assert.Matches(@"^1\D50 \S+$", HostStrings.FileSize(1_536));
        Assert.Matches(@"^5\D00 \S+$", HostStrings.FileSize(5_242_880));
        Assert.Matches(@"^0 \S+$", HostStrings.FileSize(0));
        Assert.NotEqual(HostStrings.FileSize(1_536), HostStrings.FileSize(1_536_000));
    }
}
