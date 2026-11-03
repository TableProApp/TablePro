using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.Windows.ApplicationModel.Resources;
using TablePro.Interop;

namespace TablePro.App.Services;

// Strings/en-US/Resources.resw, the same resources XAML reads through x:Uid.
internal static class Strings
{
    private static readonly ResourceLoader Loader = new();

    public static string Get(string name)
    {
        try
        {
            return Loader.GetString(name);
        }
        catch (COMException)
        {
            // An error code with no wording yet; the caller falls back to a general sentence.
            return string.Empty;
        }
    }

    public static string Format(string name, params object?[] values) =>
        string.Format(CultureInfo.CurrentCulture, Get(name), values);

    // A code with no wording here falls back to the server's own message, then a general one.
    public static string Error(CoreError error)
    {
        ArgumentNullException.ThrowIfNull(error);
        for (var index = error.Codes.Count - 1; index >= 0; index--)
        {
            var text = Get("Error_" + error.Codes[index].Replace('.', '_'));
            if (!string.IsNullOrEmpty(text))
            {
                return error.Server is { } server ? $"{text} {server.Message}" : text;
            }
        }

        return error.Server?.Message ?? Format("Error_Unknown", error.Code);
    }

    public static string Error(Exception exception) => exception switch
    {
        TableProException core => Error(core.Error),
        _ => exception.Message,
    };
}
