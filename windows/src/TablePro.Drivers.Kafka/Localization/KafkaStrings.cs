using TablePro.Core.Localization;

namespace TablePro.Drivers.Kafka.Localization;

/// <summary>
/// The text only the Kafka driver composes (KafkaQL parse errors, topic and group results, grid refusals), in
/// src/TablePro.Drivers.Kafka/Resources/&lt;Area&gt;.resx. Phrases other drivers share come from <see cref="CoreStrings"/>.
/// </summary>
internal static class KafkaStrings
{
    private static readonly ResourceStrings Text = new(typeof(KafkaStrings).Assembly, "TablePro.Drivers.Kafka.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);

    public static string Plural(string key, long count, params ReadOnlySpan<object?> args) => Text.Plural(key, count, args);
}
