using System.Globalization;
using TablePro.Interop;

namespace TablePro.App.Model;

// How someone answered the license ask. Stored, so the names never change.
public enum LicenseAskAnswer
{
    Buy,
    Personal,
    NotNow,
}

// When the app may ask someone without a license to buy one, as the macOS app's SupportAskSchedule: the 30th day of
// use opens it, each ask closes it for 90 days, or a year once TablePro is for personal use, and a license for good.
public static class LicenseAsk
{
    public const int FirstAskDay = 30;
    public const int DaysBetweenAsks = 90;
    public const int DaysAfterPersonalUse = 365;

    // Someone who just launched the app came to do something; the ask waits until they have.
    public static readonly TimeSpan LaunchQuietPeriod = TimeSpan.FromMinutes(5);

    // The distinct local days the app was in use; the count never leaves the computer.
    public static AppSettings RecordUse(AppSettings settings, DateOnly today)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return settings.LastUsageDay == today
            ? settings
            : settings with { UsageDays = settings.UsageDays + 1, LastUsageDay = today };
    }

    public static bool IsDue(AppSettings settings, bool hasLicense, DateOnly today)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (hasLicense || settings.UsageDays < FirstAskDay)
        {
            return false;
        }

        if (settings.LicenseAskDay is not { } asked)
        {
            return true;
        }

        var wait = settings.LicenseAskAnswer == LicenseAskAnswer.Personal ? DaysAfterPersonalUse : DaysBetweenAsks;
        return today >= asked.AddDays(wait);
    }

    // Recorded as it shows, so quitting while it shows still counts as an ask.
    public static AppSettings Asked(AppSettings settings, DateOnly today)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return settings with { LicenseAskDay = today, LicenseAskAnswer = null };
    }

    // Never over a run someone is waiting for, and not in the first minutes after launch.
    public static bool IsQuietMoment(TimeSpan sinceLaunch, TimeSpan quietPeriod, bool running) =>
        !running && sinceLaunch >= quietPeriod;

    // An entitlement that names a license, even one that has lapsed: someone offline past its end has still paid.
    public static bool HasLicense(AccountStatus status)
    {
        ArgumentNullException.ThrowIfNull(status);
        return status.Licenses.Count > 0;
    }

    // Whole seconds, for the UI tests; anything else keeps the five minutes.
    public static TimeSpan QuietPeriod(string? seconds) =>
        int.TryParse(seconds, NumberStyles.None, CultureInfo.InvariantCulture, out var value)
            ? TimeSpan.FromSeconds(value)
            : LaunchQuietPeriod;
}
