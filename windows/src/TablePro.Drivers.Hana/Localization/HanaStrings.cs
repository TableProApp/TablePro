using TablePro.Core.Localization;

namespace TablePro.Drivers.Hana.Localization;

/// <summary>
/// The text only the SAP HANA driver composes, in <c>src/TablePro.Drivers.Hana/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class HanaStrings
{
    private static readonly ResourceStrings Text = new(typeof(HanaStrings).Assembly, "TablePro.Drivers.Hana.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
