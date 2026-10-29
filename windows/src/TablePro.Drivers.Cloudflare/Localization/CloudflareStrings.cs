using TablePro.Core.Localization;

namespace TablePro.Drivers.Cloudflare.Localization;

/// <summary>
/// The text only the Cloudflare driver composes, in <c>src/TablePro.Drivers.Cloudflare/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class CloudflareStrings
{
    private static readonly ResourceStrings Text = new(typeof(CloudflareStrings).Assembly, "TablePro.Drivers.Cloudflare.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
