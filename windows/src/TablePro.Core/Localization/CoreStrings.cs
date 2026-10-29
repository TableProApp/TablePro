namespace TablePro.Core.Localization;

/// <summary>
/// The text Core composes, in <c>src/TablePro.Core/Resources/&lt;Area&gt;.resx</c>. It is public because the
/// <c>Driver</c> area holds the phrases every driver shares (connection failures, unsupported operations, read-only
/// refusals), so thirty driver projects do not each carry seven copies of them.
/// </summary>
public static class CoreStrings
{
    private static readonly ResourceStrings Text = new(typeof(CoreStrings).Assembly, "TablePro.Core.Resources");

    /// <inheritdoc cref="ResourceStrings.Get"/>
    public static string Get(string key) => Text.Get(key);

    /// <inheritdoc cref="ResourceStrings.Format"/>
    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);

    /// <inheritdoc cref="ResourceStrings.Plural"/>
    public static string Plural(string key, long count, params ReadOnlySpan<object?> args) => Text.Plural(key, count, args);
}
