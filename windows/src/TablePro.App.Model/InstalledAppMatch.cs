using System.Globalization;

namespace TablePro.App.Model;

// Reads another app's Uninstall entry, which is where its installer put the icon the setup guide shows.
public static class InstalledAppMatch
{
    // An installer names the app alone, or with a version or edition after a space.
    public static bool Matches(string? displayName, string appName)
    {
        ArgumentNullException.ThrowIfNull(appName);
        if (string.IsNullOrWhiteSpace(displayName) || string.IsNullOrWhiteSpace(appName))
        {
            return false;
        }

        var name = displayName.Trim();
        return name.Equals(appName, StringComparison.OrdinalIgnoreCase)
            || name.StartsWith(appName + " ", StringComparison.OrdinalIgnoreCase);
    }

    // DisplayIcon is a path, quoted or not, with an optional ",index" naming an icon inside the file.
    public static string? IconPath(string? displayIcon)
    {
        if (string.IsNullOrWhiteSpace(displayIcon))
        {
            return null;
        }

        var path = displayIcon.Trim();
        var comma = path.LastIndexOf(',');
        if (comma >= 0 && int.TryParse(
                path.AsSpan(comma + 1).Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out _))
        {
            path = path[..comma].TrimEnd();
        }

        path = path.Trim('"').Trim();
        return path.Length > 0 ? path : null;
    }
}
