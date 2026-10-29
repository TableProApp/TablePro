using TablePro.Core.Localization;

namespace TablePro.Drivers.DynamoDb.Localization;

/// <summary>
/// The text only the DynamoDB driver composes, in <c>src/TablePro.Drivers.DynamoDb/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class DynamoDbStrings
{
    private static readonly ResourceStrings Text = new(typeof(DynamoDbStrings).Assembly, "TablePro.Drivers.DynamoDb.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);

    public static string Plural(string key, long count, params ReadOnlySpan<object?> args) => Text.Plural(key, count, args);
}
