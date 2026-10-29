using System.Collections.Concurrent;
using System.Globalization;
using System.Reflection;
using System.Resources;

namespace TablePro.Core.Localization;

/// <summary>
/// One assembly's translated text, read from its <c>Resources\&lt;Area&gt;.resx</c> files and their satellite
/// assemblies. A key is <c>Area/Name</c>, the shape the app's MRT Core keys have, so code reads the same in every
/// project. MRT Core needs the app's PRI and cannot serve libraries the tests load on their own, which is why the
/// libraries use .NET resources instead.
/// </summary>
/// <remarks>
/// The lookup follows <see cref="CultureInfo.CurrentUICulture"/>, which the app points at the chosen language for every
/// thread, and falls back to English. Numbers and dates in a message follow <see cref="CultureInfo.CurrentCulture"/>,
/// the user's regional format.
/// </remarks>
public sealed class ResourceStrings
{
    private readonly Assembly _assembly;
    private readonly string _baseNamespace;
    private readonly ConcurrentDictionary<string, ResourceManager> _areas = new(StringComparer.Ordinal);

    /// <param name="assembly">The assembly whose manifest holds the English resources.</param>
    /// <param name="baseNamespace">The manifest name prefix of its Resources folder, such as <c>TablePro.Core.Resources</c>.</param>
    public ResourceStrings(Assembly assembly, string baseNamespace)
    {
        ArgumentNullException.ThrowIfNull(assembly);
        ArgumentException.ThrowIfNullOrEmpty(baseNamespace);
        _assembly = assembly;
        _baseNamespace = baseNamespace;
    }

    /// <summary>The text for <paramref name="key"/>, or the key itself when it is missing, so a typo shows on screen.</summary>
    public string Get(string key)
    {
        ArgumentNullException.ThrowIfNull(key);
        var slash = key.IndexOf('/', StringComparison.Ordinal);
        if (slash <= 0)
        {
            return key;
        }

        var manager = _areas.GetOrAdd(key[..slash], static (area, self) =>
            new ResourceManager($"{self._baseNamespace}.{area}", self._assembly), this);
        try
        {
            return manager.GetString(key[(slash + 1)..], CultureInfo.CurrentUICulture) ?? key;
        }
        catch (MissingManifestResourceException)
        {
            // An unknown area is a typo the tests catch; at run time the key on screen beats a crash.
            return key;
        }
    }

    /// <summary>The text for <paramref name="key"/> with its <c>{0}</c> placeholders filled in the user's regional format.</summary>
    public string Format(string key, params ReadOnlySpan<object?> args) =>
        string.Format(CultureInfo.CurrentCulture, Get(key), args);

    /// <summary>
    /// A message about <paramref name="count"/> things, read from <c>key_One</c> or <c>key_Other</c> as the UI language's
    /// plural rule picks. <c>{0}</c> is the count; further arguments are <c>{1}</c> onwards.
    /// </summary>
    public string Plural(string key, long count, params ReadOnlySpan<object?> args)
    {
        var form = PluralRules.IsOne(CultureInfo.CurrentUICulture, count) ? "_One" : "_Other";
        var values = new object?[args.Length + 1];
        values[0] = count;
        args.CopyTo(values.AsSpan(1));
        return string.Format(CultureInfo.CurrentCulture, Get(key + form), values);
    }
}
