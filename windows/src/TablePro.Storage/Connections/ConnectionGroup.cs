using System.Text.Json.Serialization;
using TablePro.Core.Connections;

namespace TablePro.Storage.Connections;

/// <summary>
/// A folder in the connection list. A profile joins it by setting <see cref="ConnectionProfile.Group"/> to
/// <see cref="Key"/>, so renaming a group never has to rewrite its connections.
/// </summary>
public sealed record ConnectionGroup
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required string Name { get; init; }
    public ConnectionColor Color { get; init; } = ConnectionColor.None;
    public Guid? ParentId { get; init; }
    public int SortOrder { get; init; }

    /// <summary>The value a profile stores in <see cref="ConnectionProfile.Group"/>.</summary>
    [JsonIgnore]
    public string Key => Id.ToString("D");
}

/// <summary>How the connection list is ordered. Manual is the order the user dragged them into.</summary>
public enum ConnectionSortOrder
{
    Manual,
    Name,
    LastConnected,
}

internal sealed record ConnectionsDocument
{
    public int Version { get; init; } = 1;
    public IReadOnlyList<ConnectionProfile> Connections { get; init; } = [];
    public IReadOnlyList<ConnectionGroup> Groups { get; init; } = [];
}
