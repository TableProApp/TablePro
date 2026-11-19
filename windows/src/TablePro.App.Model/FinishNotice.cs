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

    // "3m 12s", "45s", "1h 2m": the two largest units, as macOS writes a duration in a notification.
    public static string Duration(TimeSpan elapsed)
    {
        var seconds = (long)Math.Max(0, Math.Round(elapsed.TotalSeconds));
        var (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60);
        return hours > 0
            ? string.Create(CultureInfo.InvariantCulture, $"{hours}h {minutes}m")
            : minutes > 0
                ? string.Create(CultureInfo.InvariantCulture, $"{minutes}m {rest}s")
                : string.Create(CultureInfo.InvariantCulture, $"{rest}s");
    }
}
