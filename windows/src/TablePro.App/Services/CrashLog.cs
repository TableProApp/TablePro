using System.Globalization;
using System.Text;

namespace TablePro.App.Services;

/// <summary>
/// Appends unexpected exceptions to <c>%LOCALAPPDATA%\TablePro\logs\errors.log</c>, which stays on disk until the user
/// attaches it to a bug report. Nothing is uploaded.
/// </summary>
public static class CrashLog
{
    private static readonly Lock Gate = new();

    public static string FilePath { get; } = Path.Combine(Storage.AppPaths.Default.Root, "logs", "errors.log");

    public static void Write(string context, Exception exception)
    {
        try
        {
            var entry = new StringBuilder()
                .Append(DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss.fff zzz", CultureInfo.InvariantCulture))
                .Append("  ").AppendLine(context)
                .AppendLine(exception.ToString())
                .AppendLine();
            lock (Gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.AppendAllText(FilePath, entry.ToString());
            }
        }
        catch (IOException)
        {
            // A log that cannot be written must not turn one failure into two.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
