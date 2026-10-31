using TablePro.Core.Localization;

namespace TablePro.Drivers.ClickHouse.Localization;

/// <summary>
/// The text only the ClickHouse driver composes, in <c>src/TablePro.Drivers.ClickHouse/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class ClickHouseStrings
{
    private static readonly ResourceStrings Text = new(typeof(ClickHouseStrings).Assembly, "TablePro.Drivers.ClickHouse.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
