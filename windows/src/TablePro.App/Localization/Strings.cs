using System.Globalization;
using Microsoft.Windows.ApplicationModel.Resources;
using TablePro.Core.Localization;

namespace TablePro.App.Localization;

/// <summary>
/// The app's translated text. Each <c>Strings\&lt;language&gt;\&lt;Area&gt;.resw</c> file becomes a resource map named
/// after the file, so a key is <c>Area/Name</c>, the same path an <c>x:Uid="/Area/Name"</c> in XAML uses. MRT Core picks
/// the language from <see cref="AppLanguages"/> and falls back to English for a key a translation lacks.
/// </summary>
internal static class Strings
{
    // Created on first use, after App has applied the language override, so the default context already carries it.
    private static readonly Lazy<(ResourceMap? Map, ResourceContext? Context)> Resources = new(Load);

    /// <summary>The text for <paramref name="key"/>, or the key itself when it is missing, so a typo shows on screen.</summary>
    public static string Get(string key)
    {
        var (map, context) = Resources.Value;
        if (map is null)
        {
            return key;
        }

        var candidate = context is null ? map.TryGetValue(key) : map.TryGetValue(key, context);
        return candidate?.ValueAsString ?? key;
    }

    /// <summary>The text for <paramref name="key"/> with its <c>{0}</c> placeholders filled in the user's regional format.</summary>
    public static string Format(string key, params ReadOnlySpan<object?> args) =>
        string.Format(CultureInfo.CurrentCulture, Get(key), args);

    /// <summary>
    /// A message about <paramref name="count"/> things, read from <c>key_One</c> or <c>key_Other</c> as the UI language's
    /// plural rule picks. <c>{0}</c> is the count; further arguments are <c>{1}</c> onwards.
    /// </summary>
    public static string Plural(string key, long count, params ReadOnlySpan<object?> args)
    {
        var form = PluralRules.IsOne(CultureInfo.CurrentUICulture, count) ? "_One" : "_Other";
        var values = new object?[args.Length + 1];
        values[0] = count;
        args.CopyTo(values.AsSpan(1));
        return string.Format(CultureInfo.CurrentCulture, Get(key + form), values);
    }

    private static (ResourceMap?, ResourceContext?) Load()
    {
        try
        {
            var manager = new ResourceManager();
            var context = manager.CreateResourceContext();
            if (AppLanguages.Override is { Length: > 0 } language)
            {
                // The default context follows the override too, but naming it keeps code and x:Uid text on one language.
                context.QualifierValues[KnownResourceQualifierName.Language] = language;
            }

            return (manager.MainResourceMap, context);
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or FileNotFoundException)
        {
            // A missing resources.pri leaves the keys on screen rather than failing the window that asked.
            Services.CrashLog.Write("Resource lookup failed", ex);
            return (null, null);
        }
    }
}
