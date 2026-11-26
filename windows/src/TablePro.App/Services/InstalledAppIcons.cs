using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Win32;
using TablePro.App.Model;
using TablePro.Interop;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace TablePro.App.Services;

// Another app's own icon, from the file its installer registered; the core has none and the app ships none.
internal sealed class InstalledAppIcons
{
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall";
    private static readonly RegistryHive[] Hives = [RegistryHive.CurrentUser, RegistryHive.LocalMachine];
    private static readonly RegistryView[] Views = [RegistryView.Registry64, RegistryView.Registry32];

    // Read and written on the UI thread only, where the images are made.
    private readonly Dictionary<ForeignApp, Task<ImageSource?>> _icons = [];

    // Null for an app with no icon to read; the caller keeps its glyph then.
    public Task<ImageSource?> GetAsync(ForeignSource source, int pixels)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (!_icons.TryGetValue(source.App, out var icon))
        {
            icon = LoadAsync(source.Name, (uint)Math.Max(1, pixels));
            _icons[source.App] = icon;
        }

        return icon;
    }

    // Null until the icon is in.
    public ImageSource? Loaded(ForeignApp app) =>
        _icons.TryGetValue(app, out var icon) && icon.IsCompletedSuccessfully ? icon.Result : null;

    private static async Task<ImageSource?> LoadAsync(string appName, uint pixels)
    {
        try
        {
            using var thumbnail = await Task.Run(() => ThumbnailAsync(appName, pixels)).ConfigureAwait(true);
            if (thumbnail is null)
            {
                return null;
            }

            var image = new BitmapImage();
            await image.SetSourceAsync(thumbnail);
            return image;
        }
        // Whatever the registry, the file or the shell refuses, the card keeps its glyph.
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            return null;
        }
    }

    // The shell draws the file's own icon, an .ico or the icon inside an .exe, at the size asked.
    private static async Task<StorageItemThumbnail?> ThumbnailAsync(string appName, uint pixels)
    {
        if (IconFile(appName) is not { } path)
        {
            return null;
        }

        var file = await StorageFile.GetFileFromPathAsync(path);
        return await file.GetThumbnailAsync(ThumbnailMode.SingleItem, pixels);
    }

    // The first entry for the app, per user then per machine, in both registry views, that names an icon file.
    private static string? IconFile(string appName)
    {
        foreach (var hive in Hives)
        {
            foreach (var view in Views)
            {
                using var root = RegistryKey.OpenBaseKey(hive, view);
                using var uninstall = root.OpenSubKey(UninstallKey);
                if (uninstall is null)
                {
                    continue;
                }

                foreach (var name in uninstall.GetSubKeyNames())
                {
                    using var entry = uninstall.OpenSubKey(name);
                    if (entry?.GetValue("DisplayName") is not string displayName
                        || !InstalledAppMatch.Matches(displayName, appName)
                        || InstalledAppMatch.IconPath(entry.GetValue("DisplayIcon") as string) is not { } icon)
                    {
                        continue;
                    }

                    var path = Environment.ExpandEnvironmentVariables(icon);
                    if (File.Exists(path))
                    {
                        return path;
                    }
                }
            }
        }

        return null;
    }
}
