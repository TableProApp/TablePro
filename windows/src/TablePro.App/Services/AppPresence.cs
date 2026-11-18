namespace TablePro.App.Services;

// The tablepro command reads the app as running while this file is held, in command_line/app_files.rs.
internal sealed class AppPresence : IDisposable
{
    private readonly FileStream? _held;

    private AppPresence(FileStream? held) => _held = held;

    public static string FileIn(string dataFolder) => Path.Combine(dataFolder, "runtime", "app.lock");

    // A file another program holds leaves the command saying the app is not running; the app itself runs as before.
    public static AppPresence Hold(string dataFolder)
    {
        var path = FileIn(dataFolder);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            return new AppPresence(new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            CrashLog.Write(exception);
            return new AppPresence(null);
        }
    }

    public void Dispose() => _held?.Dispose();
}
