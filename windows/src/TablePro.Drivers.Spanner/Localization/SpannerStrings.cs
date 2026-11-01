using TablePro.Core.Localization;

namespace TablePro.Drivers.Spanner.Localization;

/// <summary>
/// The text only the Spanner driver composes, in <c>src/TablePro.Drivers.Spanner/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class SpannerStrings
{
    private static readonly ResourceStrings Text = new(typeof(SpannerStrings).Assembly, "TablePro.Drivers.Spanner.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
