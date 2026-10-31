using TablePro.Storage.Localization;

namespace TablePro.Storage.Favorites;

/// <summary>
/// A saved SQL snippet. With a <see cref="Keyword"/>, typing that word in the editor offers to expand it into
/// <see cref="Query"/>. A null <see cref="ConnectionId"/> shows it for every connection.
/// </summary>
public sealed record SqlFavorite
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required string Name { get; init; }
    public required string Query { get; init; }
    public string? Keyword { get; init; }
    public Guid? FolderId { get; init; }
    public Guid? ConnectionId { get; init; }
    public int SortOrder { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; init; } = DateTimeOffset.UtcNow;

    /// <summary>A name for a favorite saved without one: its first line, cut to a length a list row can show.</summary>
    public static string NameFromQuery(string query)
    {
        ArgumentNullException.ThrowIfNull(query);
        foreach (var line in query.AsSpan().EnumerateLines())
        {
            var trimmed = line.Trim();
            if (trimmed.IsEmpty || trimmed.StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            var text = trimmed.ToString();
            return text.Length <= 60 ? text : string.Concat(text.AsSpan(0, 59), "…");
        }

        return StorageStrings.Get("Stores/UntitledQuery");
    }
}

/// <summary>A folder of favorites. Folders nest through <see cref="ParentId"/>.</summary>
public sealed record SqlFavoriteFolder
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required string Name { get; init; }
    public Guid? ParentId { get; init; }
    public Guid? ConnectionId { get; init; }
    public int SortOrder { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; init; } = DateTimeOffset.UtcNow;
}

internal sealed record FavoritesDocument
{
    public int Version { get; init; } = 1;
    public IReadOnlyList<SqlFavoriteFolder> Folders { get; init; } = [];
    public IReadOnlyList<SqlFavorite> Favorites { get; init; } = [];
}
