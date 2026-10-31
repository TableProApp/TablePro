using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using TablePro.Storage.Library.Folders;
using TablePro.Storage.Library.Team;

namespace TablePro.Storage.Library;

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    UseStringEnumConverter = true,
    WriteIndented = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    AllowTrailingCommas = true,
    ReadCommentHandling = JsonCommentHandling.Skip)]
[JsonSerializable(typeof(LinkedSqlFoldersDocument))]
[JsonSerializable(typeof(TeamLibraryState))]
internal sealed partial class LibraryJsonContext : JsonSerializerContext;

/// <summary>
/// The team library's wire and cache format. Keys come from <see cref="JsonPropertyNameAttribute"/> on each type, as
/// the macOS app's CodingKeys, so an embedded connection payload keeps its own camelCase keys untouched.
/// </summary>
[JsonSourceGenerationOptions(
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    AllowTrailingCommas = true,
    ReadCommentHandling = JsonCommentHandling.Skip)]
[JsonSerializable(typeof(TeamLibraryPullRequest))]
[JsonSerializable(typeof(TeamLibraryPublishRequest))]
[JsonSerializable(typeof(TeamLibraryPublishResponse))]
[JsonSerializable(typeof(TeamLibraryPullResponse))]
[JsonSerializable(typeof(TeamLibraryErrorResponse))]
internal sealed partial class TeamLibraryJsonContext : JsonSerializerContext;

internal static class LibraryJson
{
    public static JsonTypeInfo<LinkedSqlFoldersDocument> Folders => LibraryJsonContext.Default.LinkedSqlFoldersDocument;

    public static JsonTypeInfo<TeamLibraryState> TeamState => LibraryJsonContext.Default.TeamLibraryState;

    public static JsonTypeInfo<TeamLibraryPullRequest> PullRequest => TeamLibraryJsonContext.Default.TeamLibraryPullRequest;

    public static JsonTypeInfo<TeamLibraryPublishRequest> PublishRequest => TeamLibraryJsonContext.Default.TeamLibraryPublishRequest;

    public static JsonTypeInfo<TeamLibraryPublishResponse> PublishResponse => TeamLibraryJsonContext.Default.TeamLibraryPublishResponse;

    public static JsonTypeInfo<TeamLibraryPullResponse> PullResponse => TeamLibraryJsonContext.Default.TeamLibraryPullResponse;

    public static JsonTypeInfo<TeamLibraryErrorResponse> Error => TeamLibraryJsonContext.Default.TeamLibraryErrorResponse;
}
