using System.Globalization;
using TablePro.Core.Localization;

namespace TablePro.Core.Tests.Localization;

public sealed class FormattingCultureTests
{
    private static readonly CultureInfo UnitedStates = CultureInfo.GetCultureInfo("en-US");

    [Fact]
    public void FrenchOnAnEnglishRegionGroupsDigitsTheFrenchWay()
    {
        var culture = FormattingCulture.For("fr", "US", UnitedStates);

        Assert.Equal("fr", culture.TwoLetterISOLanguageName);
        Assert.NotEqual("1,200", 1200.ToString("N0", culture));
    }

    [Fact]
    public void FollowingWindowsKeepsTheWindowsCulture() =>
        Assert.Same(UnitedStates, FormattingCulture.For(string.Empty, "US", UnitedStates));

    [Fact]
    public void TheSameLanguageAsTheRegionKeepsTheUsersOwnFormats()
    {
        var custom = (CultureInfo)CultureInfo.GetCultureInfo("fr-FR").Clone();
        custom.NumberFormat.NumberGroupSeparator = "'";

        Assert.Same(custom, FormattingCulture.For("fr", "FR", custom));
        Assert.Same(UnitedStates, FormattingCulture.For("en-US", "US", UnitedStates));
    }

    [Fact]
    public void TheTwoChineseScriptsAreDifferentLanguages()
    {
        var mainland = CultureInfo.GetCultureInfo("zh-CN");

        Assert.Same(mainland, FormattingCulture.For("zh-Hans", "CN", mainland));
        Assert.NotSame(mainland, FormattingCulture.For("zh-Hant", "CN", mainland));
    }

    [Fact]
    public void AnUnknownRegionFallsBackToTheLanguage() =>
        Assert.Equal("ko", FormattingCulture.For("ko", "QQ-NOPE", UnitedStates).TwoLetterISOLanguageName);
}
