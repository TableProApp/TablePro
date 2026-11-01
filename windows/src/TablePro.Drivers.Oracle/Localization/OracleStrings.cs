using TablePro.Core.Localization;

namespace TablePro.Drivers.Oracle.Localization;

/// <summary>
/// The text only the Oracle driver composes, in <c>src/TablePro.Drivers.Oracle/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class OracleStrings
{
    private static readonly ResourceStrings Text = new(typeof(OracleStrings).Assembly, "TablePro.Drivers.Oracle.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
