using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.Windows.ApplicationModel.Resources;
using TerraFX.Interop.Windows;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Graphics;

// The hosting app's Strings/<language>/Resources.resw. The controls read the app's strings, as Microsoft's docs advise a
// library to, so one file per language words the app and its controls. A name the host lacks reads as empty.
public static unsafe class HostStrings
{
    private static readonly Lazy<ResourceMap?> s_map = new(OpenMap);

    public static string Get(string name) => Find(name)?.ValueAsString ?? string.Empty;

    public static string Format(string name, params object?[] values) =>
        string.Format(CultureInfo.CurrentCulture, Get(name), values);

    // The count picks the form by the plural rules of the language the strings are in: name_one, name_few and so on,
    // else name_other. The count is only the chooser, so the values hold it wherever the sentence shows it.
    public static string Plural(string name, long count, params object?[] values)
    {
        ArgumentNullException.ThrowIfNull(name);
        if (Find(name + "_other") is not { } other)
        {
            return string.Empty;
        }
        var language = LanguageOf(other);
        var category = PluralRules.Select(language, count);
        var form = category == PluralRules.Other ? null : Find(name + "_" + category);
        // MRT fills a form the language lacks from the default language's file, which is not this language's form.
        if (form is null || !string.Equals(LanguageOf(form), language, StringComparison.OrdinalIgnoreCase))
        {
            form = other;
        }
        return string.Format(CultureInfo.CurrentCulture, form.ValueAsString, values);
    }

    // A size as File Explorer words it in the user's language: "532 bytes", "1.50 KB".
    public static string FileSize(long bytes)
    {
        const int Capacity = 64;
        var text = stackalloc char[Capacity];
        var flags = (int)tagSFBS_FLAGS.SFBS_FLAGS_ROUND_TO_NEAREST_DISPLAYED_DIGIT;
        return StrFormatByteSizeEx((ulong)Math.Max(0, bytes), flags, text, Capacity).SUCCEEDED
            ? new string(text)
            : bytes.ToString("N0", CultureInfo.CurrentCulture);
    }

    private static ResourceCandidate? Find(string name)
    {
        try
        {
            return s_map.Value?.TryGetValue(name);
        }
        catch (COMException)
        {
            return null;
        }
    }

    private static string LanguageOf(ResourceCandidate candidate) =>
        candidate.QualifierValues.TryGetValue("Language", out var language) && !string.IsNullOrEmpty(language)
            ? language
            : CultureInfo.CurrentUICulture.Name;

    private static ResourceMap? OpenMap()
    {
        try
        {
            return new ResourceManager().MainResourceMap.TryGetSubtree("Resources");
        }
        catch (Exception exception) when (exception is COMException or FileNotFoundException)
        {
            // A host built without a resources.pri, such as the grid's gate.
            return null;
        }
    }
}
