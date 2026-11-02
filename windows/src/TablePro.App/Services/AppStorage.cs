using System.Reflection;
using System.Runtime.InteropServices;

namespace TablePro.App.Services;

// Where the app keeps its files. A packaged app writes to its package's LocalState folder, which Windows removes
// with the app; an unpackaged development build uses %LOCALAPPDATA%\TablePro. TABLEPRO_DATA_DIR overrides both,
// which the UI tests use to start from an empty folder.
internal static partial class AppStorage
{
    private const int AppModelErrorNoPackage = 15700;

    public static bool IsPackaged { get; } = DetectPackage();

    public static string DataFolder { get; } = Resolve();

    public static string Version { get; } =
        typeof(AppStorage).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            .Split('+')[0]
        ?? "0.0.0";

    private static string Resolve()
    {
        var overridden = Environment.GetEnvironmentVariable("TABLEPRO_DATA_DIR");
        if (!string.IsNullOrWhiteSpace(overridden))
        {
            return Path.GetFullPath(overridden);
        }

        if (IsPackaged)
        {
            return Windows.Storage.ApplicationData.Current.LocalFolder.Path;
        }

        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TablePro");
    }

    private static bool DetectPackage()
    {
        uint length = 0;
        return GetCurrentPackageFullName(ref length, IntPtr.Zero) != AppModelErrorNoPackage;
    }

    [LibraryImport("kernel32.dll")]
    private static partial int GetCurrentPackageFullName(ref uint packageFullNameLength, IntPtr packageFullName);
}
