using TablePro.Core.Localization;

namespace TablePro.Drivers.Typesense.Localization;

/// <summary>
/// The text only the Typesense driver composes, in <c>src/TablePro.Drivers.Typesense/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class TypesenseStrings
{
    private static readonly ResourceStrings Text = new(typeof(TypesenseStrings).Assembly, "TablePro.Drivers.Typesense.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
