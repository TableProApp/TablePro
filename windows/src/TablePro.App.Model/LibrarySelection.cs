using TablePro.Interop;

namespace TablePro.App.Model;

// Selection mode checks connections, not rows: a connection listed in two sections is checked on both or neither.
public sealed class LibrarySelection
{
    private readonly HashSet<Guid> _ids = [];

    public int Count => _ids.Count;

    public bool IsChecked(LibraryNode row)
    {
        ArgumentNullException.ThrowIfNull(row);
        return row is { Kind: LibraryNodeKind.Connection, Id: { } id } && _ids.Contains(id);
    }

    public void Apply(IEnumerable<LibraryNode> checkedRows, IEnumerable<LibraryNode> uncheckedRows)
    {
        ArgumentNullException.ThrowIfNull(checkedRows);
        ArgumentNullException.ThrowIfNull(uncheckedRows);
        foreach (var id in ConnectionIds(uncheckedRows))
        {
            _ids.Remove(id);
        }

        foreach (var id in ConnectionIds(checkedRows))
        {
            _ids.Add(id);
        }
    }

    // In the library's order, so a command acts on each connection once.
    public IReadOnlyList<SavedConnection> Connections(LibrarySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        return [.. snapshot.Connections.Where(connection => connection.Id is { } id && _ids.Contains(id))];
    }

    // A connection a rebuild no longer shows, gone or filtered out by a search, stops being checked.
    public void Retain(IEnumerable<LibraryNode> roots)
    {
        ArgumentNullException.ThrowIfNull(roots);
        var shown = ConnectionIds(Flatten(roots)).ToHashSet();
        _ids.IntersectWith(shown);
    }

    public void Clear() => _ids.Clear();

    private static IEnumerable<Guid> ConnectionIds(IEnumerable<LibraryNode> rows) =>
        rows.Where(row => row.Kind == LibraryNodeKind.Connection && row.Id is not null).Select(row => row.Id!.Value);

    private static IEnumerable<LibraryNode> Flatten(IEnumerable<LibraryNode> nodes) =>
        nodes.SelectMany(node => Flatten(node.Children).Prepend(node));
}
