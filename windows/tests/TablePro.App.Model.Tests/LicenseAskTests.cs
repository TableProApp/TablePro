using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class LicenseAskTests
{
    private static readonly DateOnly Today = new(2026, 11, 20);

    [Fact]
    public void EachLocalDayOfUseCountsOnce()
    {
        var first = LicenseAsk.RecordUse(new AppSettings(), Today);
        var again = LicenseAsk.RecordUse(first, Today);
        var next = LicenseAsk.RecordUse(again, Today.AddDays(1));

        Assert.Equal(1, first.UsageDays);
        Assert.Same(first, again);
        Assert.Equal(2, next.UsageDays);
        Assert.Equal(Today.AddDays(1), next.LastUsageDay);
    }

    [Fact]
    public void TheThirtiethDayOfUseOpensIt()
    {
        Assert.False(LicenseAsk.IsDue(Used(29), hasLicense: false, Today));
        Assert.True(LicenseAsk.IsDue(Used(30), hasLicense: false, Today));
        Assert.True(LicenseAsk.IsDue(Used(400), hasLicense: false, Today));
    }

    [Fact]
    public void ALicenseClosesItForGood()
    {
        Assert.False(LicenseAsk.IsDue(Used(300), hasLicense: true, Today));
    }

    [Fact]
    public void EachAskWaitsNinetyDays()
    {
        var asked = LicenseAsk.Asked(Used(40), Today);

        Assert.False(LicenseAsk.IsDue(asked, hasLicense: false, Today.AddDays(89)));
        Assert.True(LicenseAsk.IsDue(asked, hasLicense: false, Today.AddDays(90)));
        Assert.True(LicenseAsk.IsDue(asked with { LicenseAskAnswer = LicenseAskAnswer.NotNow }, false, Today.AddDays(90)));
    }

    [Fact]
    public void PersonalUseQuietsItForAYear()
    {
        var personal = LicenseAsk.Asked(Used(40), Today) with { LicenseAskAnswer = LicenseAskAnswer.Personal };

        Assert.False(LicenseAsk.IsDue(personal, hasLicense: false, Today.AddDays(364)));
        Assert.True(LicenseAsk.IsDue(personal, hasLicense: false, Today.AddDays(365)));
    }

    [Fact]
    public void ShowingItAgainForgetsTheLastAnswer()
    {
        var personal = Used(40) with { LicenseAskAnswer = LicenseAskAnswer.Personal };

        var asked = LicenseAsk.Asked(personal, Today);

        Assert.Equal(Today, asked.LicenseAskDay);
        Assert.Null(asked.LicenseAskAnswer);
    }

    [Fact]
    public void AClockSetBackNeverAsksEarly()
    {
        var asked = LicenseAsk.Asked(Used(40), Today);

        Assert.False(LicenseAsk.IsDue(asked, hasLicense: false, Today.AddDays(-30)));
    }

    [Fact]
    public void ItWaitsOutTheLaunchAndAnyRunningTab()
    {
        var minute = TimeSpan.FromMinutes(1);

        Assert.False(LicenseAsk.IsQuietMoment(4 * minute, LicenseAsk.LaunchQuietPeriod, running: false));
        Assert.False(LicenseAsk.IsQuietMoment(5 * minute, LicenseAsk.LaunchQuietPeriod, running: true));
        Assert.True(LicenseAsk.IsQuietMoment(5 * minute, LicenseAsk.LaunchQuietPeriod, running: false));
    }

    [Fact]
    public void OnlyWholeSecondsShortenTheQuietPeriod()
    {
        Assert.Equal(TimeSpan.Zero, LicenseAsk.QuietPeriod("0"));
        Assert.Equal(TimeSpan.FromSeconds(3), LicenseAsk.QuietPeriod("3"));
        Assert.Equal(LicenseAsk.LaunchQuietPeriod, LicenseAsk.QuietPeriod(null));
        Assert.Equal(LicenseAsk.LaunchQuietPeriod, LicenseAsk.QuietPeriod("-1"));
        Assert.Equal(LicenseAsk.LaunchQuietPeriod, LicenseAsk.QuietPeriod("soon"));
    }

    [Fact]
    public void AnEntitlementThatNamesALicenseCountsEvenOnceItHasLapsed()
    {
        var license = new AccountLicense("lic_01", "pro", "yearly", "subscription", "active", null, null, null);
        var lapsed = AccountStatus.SignedOut with
        {
            State = AccountState.SignedIn,
            Licenses = [license],
            Problem = EntitlementProblem.Expired.Instance,
        };

        Assert.True(LicenseAsk.HasLicense(lapsed));
        Assert.False(LicenseAsk.HasLicense(AccountStatus.SignedOut));
    }

    [Fact]
    public void TheCountAndTheAskSurviveTheSettingsFile()
    {
        var path = Path.Combine(Directory.CreateTempSubdirectory().FullName, "settings.json");
        var store = new SettingsStore(path);
        var settings = LicenseAsk.Asked(Used(31), Today) with { LicenseAskAnswer = LicenseAskAnswer.Personal };

        store.Save(settings);
        var read = store.Load();

        Assert.Equal(31, read.UsageDays);
        Assert.Equal(Today, read.LastUsageDay);
        Assert.Equal(Today, read.LicenseAskDay);
        Assert.Equal(LicenseAskAnswer.Personal, read.LicenseAskAnswer);
    }

    private static AppSettings Used(int days) => new() { UsageDays = days, LastUsageDay = Today };
}
