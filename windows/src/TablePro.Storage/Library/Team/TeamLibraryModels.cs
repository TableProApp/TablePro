using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace TablePro.Storage.Library.Team;

/// <summary>
/// The macOS app's team library wire format, key for key: requests and responses use snake_case through explicit
/// names, and a connection's <c>payload</c> is the macOS <c>ExportableConnection</c> object passed through untouched,
/// so a library published from either app reads the same in both.
/// </summary>
public sealed record TeamLibraryPullRequest(
    [property: JsonPropertyName("license_key")] string LicenseKey,
    [property: JsonPropertyName("machine_id")] string MachineId);

public sealed record TeamLibraryConnectionPayload(
    [property: JsonPropertyName("source_connection_id")] string? SourceConnectionId,
    [property: JsonPropertyName("payload")] JsonObject Payload);

public sealed record TeamLibraryQueryFolderPayload(
    [property: JsonPropertyName("client_id")] string ClientId,
    [property: JsonPropertyName("parent_client_id")] string? ParentClientId,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("sort_order")] int SortOrder);

public sealed record TeamLibraryQueryPayload(
    [property: JsonPropertyName("client_id")] string ClientId,
    [property: JsonPropertyName("folder_client_id")] string? FolderClientId,
    [property: JsonPropertyName("connection_client_id")] string? ConnectionClientId,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("query")] string Query,
    [property: JsonPropertyName("keyword")] string? Keyword,
    [property: JsonPropertyName("sort_order")] int SortOrder);

public sealed record TeamLibraryPublishRequest(
    [property: JsonPropertyName("license_key")] string LicenseKey,
    [property: JsonPropertyName("machine_id")] string MachineId,
    [property: JsonPropertyName("connections")] IReadOnlyList<TeamLibraryConnectionPayload> Connections,
    [property: JsonPropertyName("query_folders")] IReadOnlyList<TeamLibraryQueryFolderPayload> QueryFolders,
    [property: JsonPropertyName("queries")] IReadOnlyList<TeamLibraryQueryPayload> Queries);

public sealed record TeamLibraryPublishResponse(
    [property: JsonPropertyName("published_at")] string PublishedAt,
    [property: JsonPropertyName("connection_count")] int ConnectionCount,
    [property: JsonPropertyName("query_count")] int QueryCount);

public sealed record TeamLibraryConnection(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("source_connection_id")] string? SourceConnectionId,
    [property: JsonPropertyName("payload")] JsonObject Payload,
    [property: JsonPropertyName("published_by")] string? PublishedBy,
    [property: JsonPropertyName("published_at")] string? PublishedAt)
{
    public string Name => Payload["name"]?.GetValueKind() == System.Text.Json.JsonValueKind.String ? Payload["name"]!.GetValue<string>() : Id;
}

public sealed record TeamLibraryQueryFolder(
    [property: JsonPropertyName("client_id")] string ClientId,
    [property: JsonPropertyName("parent_client_id")] string? ParentClientId,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("sort_order")] int SortOrder,
    [property: JsonPropertyName("published_by")] string? PublishedBy);

public sealed record TeamLibraryQuery(
    [property: JsonPropertyName("client_id")] string ClientId,
    [property: JsonPropertyName("folder_client_id")] string? FolderClientId,
    [property: JsonPropertyName("connection_client_id")] string? ConnectionClientId,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("query")] string Query,
    [property: JsonPropertyName("keyword")] string? Keyword,
    [property: JsonPropertyName("sort_order")] int SortOrder,
    [property: JsonPropertyName("published_by")] string? PublishedBy);

/// <summary>What a pull returns, and what <c>team_library.json</c> caches.</summary>
public sealed record TeamLibraryPullResponse(
    [property: JsonPropertyName("connections")] IReadOnlyList<TeamLibraryConnection> Connections,
    [property: JsonPropertyName("query_folders")] IReadOnlyList<TeamLibraryQueryFolder> QueryFolders,
    [property: JsonPropertyName("queries")] IReadOnlyList<TeamLibraryQuery> Queries,
    [property: JsonPropertyName("fetched_at")] string FetchedAt)
{
    // The macOS app drops these two before caching: a pulled connection is authored by another account and lands
    // with no confirmation step, so nothing in it may start a process or run SQL by itself.
    private static readonly string[] UnsafePayloadKeys = ["startupCommands", "tunnelCommand"];

    public static TeamLibraryPullResponse Empty { get; } = new([], [], [], string.Empty);

    public bool IsEmpty => Connections.Count == 0 && QueryFolders.Count == 0 && Queries.Count == 0;

    /// <summary>A copy without anything a connection would run on its own.</summary>
    public TeamLibraryPullResponse Sanitized() => this with
    {
        Connections = [.. (Connections ?? []).Select(c => c with { Payload = WithoutUnsafeKeys(c.Payload) })],
        QueryFolders = QueryFolders ?? [],
        Queries = Queries ?? [],
    };

    private static JsonObject WithoutUnsafeKeys(JsonObject? payload)
    {
        var copy = payload?.DeepClone().AsObject() ?? [];
        foreach (var key in UnsafePayloadKeys)
        {
            copy.Remove(key);
        }

        return copy;
    }
}

/// <summary>The server's error body, as the macOS license client reads it.</summary>
public sealed record TeamLibraryErrorResponse([property: JsonPropertyName("message")] string Message);

/// <summary>When the library was last pulled, kept beside the cache.</summary>
public sealed record TeamLibraryState
{
    public DateTimeOffset? LastPullAt { get; init; }
}

/// <summary>The license that entitles this machine to the team library.</summary>
public sealed record TeamLibraryCredentials(string LicenseKey, string MachineId);
