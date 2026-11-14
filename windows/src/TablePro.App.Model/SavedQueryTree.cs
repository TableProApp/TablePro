using TablePro.Interop;

namespace TablePro.App.Model;

// A folder and a query can share an id, so a row holds one or the other.
public sealed class SavedQueryNode
{
    public SavedQueryNode(SavedQueryFolder folder)
    {
        ArgumentNullException.ThrowIfNull(folder);
        Folder = folder;
        Name = folder.Name;
    }

    public SavedQueryNode(SavedQuery query)
    {
        ArgumentNullException.ThrowIfNull(query);
        Query = query;
        Name = query.Name;
    }

    public SavedQueryFolder? Folder { get; }

    public SavedQuery? Query { get; }

    public string Name { get; }

    public List<SavedQueryNode> Children { get; } = [];
}

// Path names every folder above it too, so two folders of one name in different places tell apart.
public sealed record SavedQueryFolderChoice(long Id, string Name, string Path, int Depth);

public static class SavedQueryTree
{
    public const string PathSeparator = " / ";

    // Each level lists its folders, then its queries, each in the order the user gave them.
    public static IReadOnlyList<SavedQueryNode> Build(SavedQueryList list)
    {
        ArgumentNullException.ThrowIfNull(list);
        var known = list.Folders.Select(folder => folder.Id).ToHashSet();
        // A place the list does not hold shows at the top level rather than nowhere.
        long? Place(long? folderId) => folderId is { } id && known.Contains(id) ? id : null;
        var folders = list.Folders.ToLookup(folder => Place(folder.ParentId));
        var queries = list.Queries.ToLookup(query => Place(query.FolderId));

        List<SavedQueryNode> Level(long? parent)
        {
            var level = new List<SavedQueryNode>();
            foreach (var folder in folders[parent].OrderBy(folder => folder.Order))
            {
                var node = new SavedQueryNode(folder);
                node.Children.AddRange(Level(folder.Id));
                level.Add(node);
            }

            level.AddRange(queries[parent].OrderBy(query => query.Order).Select(query => new SavedQueryNode(query)));
            return level;
        }

        return Level(null);
    }

    // In tree order, for the folder picker and the Move to menu.
    public static IReadOnlyList<SavedQueryFolderChoice> Folders(SavedQueryList list)
    {
        ArgumentNullException.ThrowIfNull(list);
        var choices = new List<SavedQueryFolderChoice>();

        void Walk(IEnumerable<SavedQueryNode> nodes, string? above, int depth)
        {
            foreach (var node in nodes)
            {
                if (node.Folder is not { } folder)
                {
                    continue;
                }

                var path = above is null ? folder.Name : above + PathSeparator + folder.Name;
                choices.Add(new SavedQueryFolderChoice(folder.Id, folder.Name, path, depth));
                Walk(node.Children, path, depth + 1);
            }
        }

        Walk(Build(list), null, 0);
        return choices;
    }

    // The folder and every folder above it, so the pane can open the way down to a query put there.
    public static IReadOnlyList<long> FolderAndAncestors(long folderId, SavedQueryList list)
    {
        ArgumentNullException.ThrowIfNull(list);
        var parents = list.Folders.ToDictionary(folder => folder.Id, folder => folder.ParentId);
        var chain = new List<long>();
        long? at = folderId;
        while (at is { } id && parents.TryGetValue(id, out var parent) && !chain.Contains(id))
        {
            chain.Add(id);
            at = parent;
        }

        return chain;
    }
}
