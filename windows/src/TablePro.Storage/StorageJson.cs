using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using TablePro.Core.Connections;
using TablePro.Storage.Connections;
using TablePro.Storage.Favorites;
using TablePro.Storage.Settings;
using TablePro.Storage.Workspace;

namespace TablePro.Storage;

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    UseStringEnumConverter = true,
    WriteIndented = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    AllowTrailingCommas = true,
    ReadCommentHandling = JsonCommentHandling.Skip)]
[JsonSerializable(typeof(ConnectionsDocument))]
[JsonSerializable(typeof(FavoritesDocument))]
[JsonSerializable(typeof(AppSettings))]
[JsonSerializable(typeof(WorkspaceState))]
[JsonSerializable(typeof(PortableConnectionFile))]
internal sealed partial class StorageJsonContext : JsonSerializerContext;

/// <summary>The type metadata every store reads and writes with, generated at compile time so trimming and AOT keep it.</summary>
internal static class StorageJson
{
    // Core's records expose derived values (Descriptor, Subtitle) as get-only properties. They are recomputed on load,
    // so writing them would only bloat the file and freeze stale values into it.
    private static readonly Dictionary<Type, string[]> DerivedProperties = new()
    {
        [typeof(ConnectionProfile)] = ["isReadOnly", "descriptor", "effectivePort", "subtitle"],
    };

    private static readonly JsonSerializerOptions Options = new(StorageJsonContext.Default.Options)
    {
        TypeInfoResolver = StorageJsonContext.Default.WithAddedModifier(RemoveDerivedProperties),
    };

    public static JsonTypeInfo<ConnectionsDocument> Connections { get; } = Get<ConnectionsDocument>();

    public static JsonTypeInfo<FavoritesDocument> Favorites { get; } = Get<FavoritesDocument>();

    public static JsonTypeInfo<AppSettings> Settings { get; } = Get<AppSettings>();

    public static JsonTypeInfo<WorkspaceState> Workspace { get; } = Get<WorkspaceState>();

    public static JsonTypeInfo<PortableConnectionFile> Portable { get; } = Get<PortableConnectionFile>();

    public static JsonTypeInfo<ConnectionProfile> Profile { get; } = Get<ConnectionProfile>();

    public static JsonTypeInfo<SshTunnelSettings> Ssh { get; } = Get<SshTunnelSettings>();

    public static JsonTypeInfo<ConnectionGroup> Group { get; } = Get<ConnectionGroup>();

    public static JsonTypeInfo<SqlFavorite> Favorite { get; } = Get<SqlFavorite>();

    public static JsonTypeInfo<SqlFavoriteFolder> Folder { get; } = Get<SqlFavoriteFolder>();

    public static JsonTypeInfo<WorkspaceTab> Tab { get; } = Get<WorkspaceTab>();

    private static JsonTypeInfo<T> Get<T>() => (JsonTypeInfo<T>)Options.GetTypeInfo(typeof(T));

    private static void RemoveDerivedProperties(JsonTypeInfo typeInfo)
    {
        if (typeInfo.Kind != JsonTypeInfoKind.Object || !DerivedProperties.TryGetValue(typeInfo.Type, out var names))
        {
            return;
        }

        for (var i = typeInfo.Properties.Count - 1; i >= 0; i--)
        {
            if (Array.IndexOf(names, typeInfo.Properties[i].Name) >= 0)
            {
                typeInfo.Properties.RemoveAt(i);
            }
        }
    }
}
