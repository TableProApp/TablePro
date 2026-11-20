using System.Globalization;

namespace TablePro.App.Model;

// How a run the user started ended: Rows is the result's, null with no result set; Failure is worded already.
public sealed record RunEnd(TimeSpan Elapsed, bool Cancelled, string? Failure, long? Rows, long? RowsAffected);

// When finished work notifies, as macOS's Settings > Notifications decides it.
public static class FinishNotice
{
    // Work stopped on purpose, work that finished quickly, and a result already on screen never notify.
    public static bool Tells(AppSettings settings, RunEnd end, bool inView)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(end);
        return settings.NotifyLongWork
            && !end.Cancelled
            && !inView
            && end.Elapsed >= TimeSpan.FromSeconds(settings.NotifyAfterSeconds);
    }

    // The two largest units, as macOS writes a duration in a notification: "1h 2m", "3m 12s", "45s" in English.
    // Each pattern takes the larger unit as {0} and the smaller as {1}.
    public static string Duration(TimeSpan elapsed, string hoursMinutes, string minutesSeconds, string seconds)
    {
        var whole = (long)Math.Max(0, Math.Round(elapsed.TotalSeconds));
        var (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60);
        return hours > 0
            ? string.Format(CultureInfo.CurrentCulture, hoursMinutes, hours, minutes)
            : minutes > 0
                ? string.Format(CultureInfo.CurrentCulture, minutesSeconds, minutes, rest)
                : string.Format(CultureInfo.CurrentCulture, seconds, rest);
    }
}
