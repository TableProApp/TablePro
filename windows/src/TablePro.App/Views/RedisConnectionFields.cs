using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.Core.Connections;

namespace TablePro.App.Views;

/// <summary>
/// The Redis part of the connection form, as the macOS sheet lays it out: the connection mode, the Sentinel nodes,
/// primary group and login, the cluster's seed nodes, and the key separator. They write the option keys the macOS app
/// stores, so a profile moved between the apps keeps its mode. The Sentinel password goes to Credential Manager, never
/// to the options.
/// </summary>
internal sealed class RedisConnectionFields
{
    public const string ModeKey = "redisMode";
    public const string SentinelHostsKey = "redisSentinelHosts";
    public const string PrimaryGroupKey = "redisSentinelMasterName";
    public const string SentinelUserKey = "redisSentinelUsername";
    public const string SentinelPasswordKey = "redisSentinelPassword";
    public const string ClusterHostsKey = "redisClusterHosts";
    public const string SeparatorKey = "redisSeparator";

    private const string DefaultPrimaryGroup = "mymaster";
    private const string DefaultSeparator = ":";

    private static readonly string[] Modes = ["standalone", "sentinel", "cluster"];

    // Every name the driver reads for a field, the macOS one first: a profile typed with a short name such as mode=
    // shows in the field and is saved back under the macOS name.
    private static readonly string[][] OwnedKeys =
    [
        [ModeKey, "mode"],
        [SentinelHostsKey, "sentinelHosts"],
        [PrimaryGroupKey, "sentinelMasterName", "serviceName"],
        [SentinelUserKey, "sentinelUsername", "sentinelUser"],
        [SentinelPasswordKey, "sentinelPassword"],
        [ClusterHostsKey, "clusterHosts"],
        [SeparatorKey],
    ];

    private readonly TextBox _database;
    private readonly ComboBox _mode = new() { Header = Strings.Get("Connection/RedisModeHeader"), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox _sentinelHosts = new() { Header = Strings.Get("Connection/RedisSentinelHostsHeader"), PlaceholderText = "127.0.0.1:26379, 127.0.0.2:26379" };
    private readonly TextBox _primaryGroup = new() { Header = Strings.Get("Connection/RedisPrimaryGroupHeader"), PlaceholderText = DefaultPrimaryGroup };
    private readonly TextBox _sentinelUser = new() { Header = Strings.Get("Connection/RedisSentinelUserHeader"), PlaceholderText = Strings.Get("Connection/OptionalPlaceholder") };
    private readonly PasswordBox _sentinelPassword = new() { Header = Strings.Get("Connection/RedisSentinelPasswordHeader") };
    private readonly TextBox _clusterHosts = new() { Header = Strings.Get("Connection/RedisClusterHostsHeader"), PlaceholderText = "127.0.0.1:7000, 127.0.0.1:7001" };
    private readonly StackPanel _sentinel = new() { Spacing = 12 };
    private readonly TextBlock _nodesNote;
    private bool _isRedis;

    /// <param name="database">The form's database field, which a cluster hides: it serves database 0 only.</param>
    /// <param name="note">Makes a note in the form's caption style.</param>
    public RedisConnectionFields(TextBox database, Func<string, TextBlock> note)
    {
        _database = database;
        _nodesNote = note(Strings.Get("Connection/RedisNodesNote"));
        foreach (var name in new[] { "Connection/RedisModeStandalone", "Connection/RedisModeSentinel", "Connection/RedisModeCluster" })
        {
            _mode.Items.Add(Strings.Get(name));
        }

        _mode.SelectedIndex = 0;
        _mode.SelectionChanged += (_, _) => UpdateVisibility();
        _sentinel.Children.Add(_sentinelHosts);
        _sentinel.Children.Add(_primaryGroup);
        _sentinel.Children.Add(_sentinelUser);
        _sentinel.Children.Add(_sentinelPassword);
        Panel.Children.Add(_mode);
        Panel.Children.Add(_sentinel);
        Panel.Children.Add(_clusterHosts);
        Panel.Children.Add(_nodesNote);
    }

    /// <summary>The mode and node fields, shown under the host on the General page.</summary>
    public StackPanel Panel { get; } = new() { Spacing = 12 };

    /// <summary>The key separator, shown on the Advanced page as macOS does.</summary>
    public TextBox Separator { get; } = new() { Header = Strings.Get("Connection/RedisSeparatorHeader"), PlaceholderText = DefaultSeparator, Width = 110, HorizontalAlignment = HorizontalAlignment.Left, FontFamily = new FontFamily("Cascadia Mono, Consolas") };

    private string Mode => Modes[Math.Clamp(_mode.SelectedIndex, 0, Modes.Length - 1)];

    /// <summary>Whether a key belongs to these fields, so the free-form options box leaves it out.</summary>
    public static bool Owns(string key) => OwnedKeys.Any(names => names.Contains(key.Trim(), StringComparer.OrdinalIgnoreCase));

    /// <summary>The options the free-form box shows: all of them for another engine, the ones these fields do not hold for Redis.</summary>
    public static IEnumerable<KeyValuePair<string, string>> Unowned(ConnectionProfile profile) =>
        profile.Engine == DatabaseEngine.Redis ? profile.AdditionalOptions.Where(o => !Owns(o.Key)) : profile.AdditionalOptions;

    /// <param name="profile">The profile being edited.</param>
    /// <param name="savedSentinelPassword">What Credential Manager holds; a password left in the options by an older build is shown otherwise.</param>
    public void Fill(ConnectionProfile profile, string? savedSentinelPassword)
    {
        var options = profile.Engine == DatabaseEngine.Redis ? profile.AdditionalOptions : new Dictionary<string, string>();
        var mode = Read(options, 0)?.ToLowerInvariant();
        _mode.SelectedIndex = Math.Max(0, Array.IndexOf(Modes, mode is "single" ? "standalone" : mode));
        _sentinelHosts.Text = Read(options, 1) ?? string.Empty;
        _primaryGroup.Text = Read(options, 2) ?? string.Empty;
        _sentinelUser.Text = Read(options, 3) ?? string.Empty;
        _sentinelPassword.Password = savedSentinelPassword ?? Read(options, 4) ?? string.Empty;
        _clusterHosts.Text = Read(options, 5) ?? string.Empty;
        Separator.Text = ReadRaw(options, SeparatorKey) ?? DefaultSeparator;
        UpdateVisibility();
    }

    /// <summary>
    /// Writes the fields into a Redis profile's options under the macOS names, replacing any name the driver also
    /// reads. Defaults are left out so a plain standalone profile stays as small as before.
    /// </summary>
    public void Apply(Dictionary<string, string> options, DatabaseEngine engine)
    {
        if (engine != DatabaseEngine.Redis)
        {
            return;
        }

        foreach (var key in options.Keys.Where(Owns).ToArray())
        {
            options.Remove(key);
        }

        var mode = Mode;
        if (mode != "standalone")
        {
            options[ModeKey] = mode;
        }

        if (mode == "sentinel")
        {
            Put(options, SentinelHostsKey, _sentinelHosts.Text);
            Put(options, PrimaryGroupKey, _primaryGroup.Text);
            Put(options, SentinelUserKey, _sentinelUser.Text);
        }
        else if (mode == "cluster")
        {
            Put(options, ClusterHostsKey, _clusterHosts.Text);
        }

        // An empty separator is a choice, a flat list of keys, so only the default is left out.
        if (Separator.Text != DefaultSeparator)
        {
            options[SeparatorKey] = Separator.Text;
        }
    }

    /// <summary>The Sentinel password to keep in Credential Manager; null clears it when the profile does not use Sentinel.</summary>
    public string? SentinelPasswordFor(ConnectionProfile profile) =>
        profile.Engine == DatabaseEngine.Redis && Mode == "sentinel" && _sentinelPassword.Password.Length > 0 ? _sentinelPassword.Password : null;

    public void SetEngine(DatabaseEngine engine)
    {
        _isRedis = engine == DatabaseEngine.Redis;
        Panel.Visibility = Visible(_isRedis);
        Separator.Visibility = Visible(_isRedis);
        UpdateVisibility();
    }

    private void UpdateVisibility()
    {
        var mode = Mode;
        _sentinel.Visibility = Visible(mode == "sentinel");
        _clusterHosts.Visibility = Visible(mode == "cluster");
        _nodesNote.Visibility = Visible(mode != "standalone");
        _database.Visibility = Visible(!(_isRedis && mode == "cluster"));
    }

    private static string? Read(IReadOnlyDictionary<string, string> options, int field)
    {
        foreach (var name in OwnedKeys[field])
        {
            if (ReadRaw(options, name) is { } value && !string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return null;
    }

    private static string? ReadRaw(IReadOnlyDictionary<string, string> options, string key) =>
        options.FirstOrDefault(o => string.Equals(o.Key.Trim(), key, StringComparison.OrdinalIgnoreCase)) is { Key: not null } match ? match.Value : null;

    private static void Put(Dictionary<string, string> options, string key, string text)
    {
        if (!string.IsNullOrWhiteSpace(text))
        {
            options[key] = text.Trim();
        }
    }

    private static Visibility Visible(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;
}
