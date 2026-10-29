using TablePro.Core.Localization;

namespace TablePro.Drivers.Dameng.Localization;

/// <summary>
/// The text only the Dameng driver composes, in <c>src/TablePro.Drivers.Dameng/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class DamengStrings
{
    private static readonly ResourceStrings Text = new(typeof(DamengStrings).Assembly, "TablePro.Drivers.Dameng.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
