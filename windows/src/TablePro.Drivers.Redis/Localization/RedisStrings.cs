using TablePro.Core.Localization;

namespace TablePro.Drivers.Redis.Localization;

/// <summary>
/// The text only the Redis driver composes (command refusals, topology and cluster advice, grid save errors), in
/// src/TablePro.Drivers.Redis/Resources/&lt;Area&gt;.resx. Phrases other drivers share come from <see cref="CoreStrings"/>;
/// replies the server sends pass through untouched.
/// </summary>
internal static class RedisStrings
{
    private static readonly ResourceStrings Text = new(typeof(RedisStrings).Assembly, "TablePro.Drivers.Redis.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);

    public static string Plural(string key, long count, params ReadOnlySpan<object?> args) => Text.Plural(key, count, args);
}
