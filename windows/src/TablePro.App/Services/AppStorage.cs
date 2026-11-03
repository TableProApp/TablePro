using System.Reflection;
using System.Runtime.InteropServices;

namespace TablePro.App.Services;

// Windows removes a packaged app's LocalState with it; TABLEPRO_DATA_DIR gives each UI test an empty folder.
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
