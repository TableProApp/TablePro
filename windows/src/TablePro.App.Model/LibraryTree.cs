using TablePro.Interop;

namespace TablePro.App.Model;

public enum LibraryNodeKind
{
    Favorites,
    Recent,
    AllConnections,
    Group,
    Connection,
}

// One row of the Connections page. A favourite shows twice, under Favorites and in its group, so a row's
// identity is its section plus its id.
public sealed class LibraryNode
{
    public LibraryNode(LibraryNodeKind kind, string section, Guid? id, string title)
    {
        Kind = kind;
        Section = section;
        Id = id;
        Title = title;
    }

    public LibraryNodeKind Kind { get; }

    public string Section { get; }

    public Guid? Id { get; }

    public string Title { get; }

    public SavedConnection? Connection { get; init; }

    public ConnectionGroup? Group { get; init; }

    // A connection's tags, in the library's order.
    public IReadOnlyList<ConnectionTag> Tags { get; init; } = [];

    public List<LibraryNode> Children { get; } = [];

    public string Key => $"{Section}/{Kind}/{Id}";
}

public static class LibraryTree
{
    public const string FavoritesSection = "favorites";
    public const string RecentSection = "recent";
    public const string ConnectionsSection = "connections";

    // Sections in the macOS order: Favorites and Recent when they hold something, then every connection in its
    // group. A search drops Favorites and Recent and keeps the groups that hold a match.
    public static IReadOnlyList<LibraryNode> Build(
        LibrarySnapshot snapshot,
        string? query,
        Func<string, string> engineName)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(engineName);
        var words = ConnectionSearch.Words(query);
        var groups = snapshot.Groups.ToDictionary(group => group.Id);
        var byId = snapshot.Connections
            .Where(connection => connection.Id is not null)
            .ToDictionary(connection => connection.Id!.Value);
        IReadOnlyList<ConnectionTag> TagsOf(SavedConnection connection) =>
            [.. snapshot.Tags.Where(tag => connection.Tags.Contains(tag.Id))];
        bool Matches(SavedConnection connection) =>
            ConnectionSearch.Matches(
                connection,
                GroupPath(connection.GroupId, groups),
                engineName(connection.EngineId),
                words,
                TagsOf(connection).Select(tag => tag.Name));
        LibraryNode ConnectionNode(string section, SavedConnection connection) =>
            new(LibraryNodeKind.Connection, section, connection.Id, connection.Name)
            {
                Connection = connection,
                Tags = TagsOf(connection),
            };

        var roots = new List<LibraryNode>();
        if (words.Count == 0)
        {
            AddSection(roots, LibraryNodeKind.Favorites, FavoritesSection, snapshot.Favorites, byId, ConnectionNode);
            AddSection(roots, LibraryNodeKind.Recent, RecentSection, snapshot.Recent, byId, ConnectionNode);
        }

        var all = new LibraryNode(LibraryNodeKind.AllConnections, ConnectionsSection, null, string.Empty);
        var children = snapshot.Groups.ToLookup(group => group.ParentId);
        var members = snapshot.Connections.ToLookup(connection => connection.GroupId);

        void Fill(LibraryNode parent, Guid? groupId)
        {
            foreach (var group in children[groupId].OrderBy(group => group.Order))
            {
                var node = new LibraryNode(LibraryNodeKind.Group, ConnectionsSection, group.Id, group.Name) { Group = group };
                Fill(node, group.Id);
                if (words.Count == 0 || node.Children.Count > 0)
                {
                    parent.Children.Add(node);
                }
            }

            foreach (var connection in members[groupId].Where(Matches))
            {
                parent.Children.Add(ConnectionNode(ConnectionsSection, connection));
            }
        }

        Fill(all, null);
        if (all.Children.Count > 0 || words.Count == 0)
        {
            roots.Add(all);
        }

        return roots;
    }

    public static string? GroupPath(Guid? groupId, IReadOnlyDictionary<Guid, ConnectionGroup> groups)
    {
        ArgumentNullException.ThrowIfNull(groups);
        var names = new List<string>();
        var seen = new HashSet<Guid>();
        while (groupId is { } id && groups.TryGetValue(id, out var group) && seen.Add(id))
        {
            names.Insert(0, group.Name);
            groupId = group.ParentId;
        }

        return names.Count == 0 ? null : string.Join(" / ", names);
    }

    private static void AddSection(
        List<LibraryNode> roots,
        LibraryNodeKind kind,
        string section,
        IReadOnlyList<Guid> ids,
        Dictionary<Guid, SavedConnection> byId,
        Func<string, SavedConnection, LibraryNode> connectionNode)
    {
        var node = new LibraryNode(kind, section, null, string.Empty);
        foreach (var id in ids)
        {
            if (byId.TryGetValue(id, out var connection))
            {
                node.Children.Add(connectionNode(section, connection));
            }
        }

        if (node.Children.Count > 0)
        {
            roots.Add(node);
        }
    }
}

public static class ConnectionSearch
{
    public static IReadOnlyList<string> Words(string? query) =>
        string.IsNullOrWhiteSpace(query)
            ? []
            : query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    // Every word has to appear in one of the fields, in any case, as the Linux and macOS searches match.
    public static bool Matches(
        SavedConnection connection,
        string? groupPath,
        string engineName,
        IReadOnlyList<string> words,
        IEnumerable<string>? tags = null)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(words);
        string?[] fields =
        [
            connection.Name, connection.Host, connection.Database, connection.UserName, engineName, groupPath,
            .. tags ?? [],
        ];
        return words.All(word => fields.Any(field =>
            field is not null && field.Contains(word, StringComparison.CurrentCultureIgnoreCase)));
    }

    // How a row describes where the connection points, after its name.
    public static string Describe(SavedConnection connection, bool isFileEngine)
    {
        ArgumentNullException.ThrowIfNull(connection);
        if (isFileEngine)
        {
            return connection.Database;
        }

        var host = connection.Port > 0 ? $"{connection.Host}:{connection.Port}" : connection.Host;
        var user = string.IsNullOrEmpty(connection.UserName) ? host : $"{connection.UserName}@{host}";
        return string.IsNullOrEmpty(connection.Database) ? user : $"{user}/{connection.Database}";
    }
}
