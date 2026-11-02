using System.Globalization;

namespace TablePro.App.Services;

// crash.log in the data folder: what ended the app, for a report and for the UI tests to print.
internal static class CrashLog
{
    public static string Path => System.IO.Path.Combine(AppStorage.DataFolder, "crash.log");

    public static void Write(Exception? exception)
    {
        if (exception is null)
        {
            return;
        }

        try
        {
            Directory.CreateDirectory(AppStorage.DataFolder);
            var stamp = DateTimeOffset.Now.ToString("O", CultureInfo.InvariantCulture);
            File.AppendAllText(Path, $"{stamp} {AppStorage.Version}{Environment.NewLine}{exception}{Environment.NewLine}");
        }
        catch (IOException)
        {
            // Nothing is left to tell when the log itself cannot be written.
        }
    }
}
