using System.Globalization;
using System.Text;

namespace TablePro.App.Services;

// The tablepro command talks only to the process whose id this file holds (core/crates/ffi/src/command_line).
internal sealed class AppPresence : IDisposable
{
    private readonly FileStream? _held;

    private AppPresence(FileStream? held) => _held = held;

    public static string FileIn(string dataFolder) => Path.Combine(dataFolder, "runtime", "app.lock");

    // Shared for reading only, so the command can read the id and tell a held file from one a crash left behind.
    public static AppPresence Hold(string dataFolder)
    {
        var path = FileIn(dataFolder);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var held = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.Read);
            held.Write(Encoding.ASCII.GetBytes(Environment.ProcessId.ToString(CultureInfo.InvariantCulture)));
            held.Flush();
            return new AppPresence(held);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Another program holding the file leaves the command saying the app is not running; the app runs as before.
            CrashLog.Write(exception);
            return new AppPresence(null);
        }
    }

    public void Dispose() => _held?.Dispose();
}
