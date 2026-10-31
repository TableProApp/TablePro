using TablePro.Core.Localization;

namespace TablePro.Drivers.Etcd.Localization;

/// <summary>
/// The text only the etcd driver composes (etcdctl parse errors, command results, gateway failures), in
/// src/TablePro.Drivers.Etcd/Resources/&lt;Area&gt;.resx. Phrases other drivers share come from <see cref="CoreStrings"/>.
/// </summary>
internal static class EtcdStrings
{
    private static readonly ResourceStrings Text = new(typeof(EtcdStrings).Assembly, "TablePro.Drivers.Etcd.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
