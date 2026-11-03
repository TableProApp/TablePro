using TablePro.Interop;

namespace TablePro.App.Model;

// What a drop on the Connections page does, written through the core.
public abstract record LibraryDrop
{
    private LibraryDrop()
    {
    }

    // Into Group, or the top level when it is null, before the connection Before, or at the end.
    public sealed record MoveConnections(IReadOnlyList<Guid> Ids, Guid? Group, Guid? Before) : LibraryDrop;

    // Connections dragged with them go into the same group.
    public sealed record MoveGroups(IReadOnlyList<Guid> Ids, Guid? Parent, IReadOnlyList<Guid> Connections) : LibraryDrop;

    // Ones already favourites move, which is how a drag reorders them.
    public sealed record AddFavorites(IReadOnlyList<Guid> Ids, Guid? Before) : LibraryDrop;

    // Null when the target takes none of what is dragged: Recent, a group inside itself, a group on a connection.
    public static LibraryDrop? Resolve(
        IReadOnlyList<LibraryNode> dragged,
        LibraryNode target,
        IReadOnlyList<ConnectionGroup> groups)
    {
        ArgumentNullException.ThrowIfNull(dragged);
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(groups);
        var connections = dragged.Where(node => node.Kind == LibraryNodeKind.Connection && node.Id is not null)
            .Select(node => node.Id!.Value)
            .Distinct()
            .ToList();
        var movedGroups = dragged.Where(node => node.Kind == LibraryNodeKind.Group && node.Id is not null)
            .Select(node => node.Id!.Value)
            .Distinct()
            .ToList();
        if (connections.Count == 0 && movedGroups.Count == 0)
        {
            return null;
        }

        switch (target.Kind)
        {
            case LibraryNodeKind.Favorites when movedGroups.Count == 0:
                return new AddFavorites(connections, null);
            case LibraryNodeKind.Connection when target.Section == LibraryTree.FavoritesSection && movedGroups.Count == 0:
                return connections.Contains(target.Id!.Value) ? null : new AddFavorites(connections, target.Id);
            case LibraryNodeKind.Connection when target.Section == LibraryTree.ConnectionsSection && movedGroups.Count == 0:
                return connections.Contains(target.Id!.Value)
                    ? null
                    : new MoveConnections(connections, target.Connection?.GroupId, target.Id);
            case LibraryNodeKind.AllConnections:
                return Into(null, connections, movedGroups, groups);
            case LibraryNodeKind.Group when target.Id is { } group:
                return Into(group, connections, movedGroups, groups);
            default:
                return null;
        }
    }

    private static LibraryDrop? Into(
        Guid? group,
        List<Guid> connections,
        List<Guid> movedGroups,
        IReadOnlyList<ConnectionGroup> groups)
    {
        if (movedGroups.Count == 0)
        {
            return new MoveConnections(connections, group, null);
        }

        // The core refuses a group inside itself; the drop is refused before it gets there.
        if (group is { } parent && movedGroups.Any(moved => IsWithin(parent, moved, groups)))
        {
            return null;
        }

        return new MoveGroups(movedGroups, group, connections);
    }

    private static bool IsWithin(Guid group, Guid ancestor, IReadOnlyList<ConnectionGroup> groups)
    {
        var parents = groups.ToDictionary(item => item.Id, item => item.ParentId);
        var seen = new HashSet<Guid>();
        Guid? current = group;
        while (current is { } id && seen.Add(id))
        {
            if (id == ancestor)
            {
                return true;
            }

            current = parents.GetValueOrDefault(id);
        }

        return false;
    }
}
