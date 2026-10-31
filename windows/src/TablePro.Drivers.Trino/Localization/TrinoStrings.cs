using TablePro.Core.Localization;

namespace TablePro.Drivers.Trino.Localization;

/// <summary>
/// The text only the Trino driver composes, in <c>src/TablePro.Drivers.Trino/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class TrinoStrings
{
    private static readonly ResourceStrings Text = new(typeof(TrinoStrings).Assembly, "TablePro.Drivers.Trino.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
