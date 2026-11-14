using System.Runtime.InteropServices;

namespace TablePro.App.Services;

// Restart Manager starts the app again after closing it for an update or a restart; the session file holds the work.
internal static partial class AppRestart
{
    private const uint NoCrash = 0x1;
    private const uint NoHang = 0x2;

    // Not after a crash or a hang, which the same session could bring on again; no arguments, so it starts as a launch.
    public static void Register()
    {
        var result = RegisterApplicationRestart(null, NoCrash | NoHang);
        if (result != 0)
        {
            CrashLog.Write(Marshal.GetExceptionForHR(result));
        }
    }

    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int RegisterApplicationRestart(string? commandLine, uint flags);
}
