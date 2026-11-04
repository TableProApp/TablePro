using TablePro.Interop;

namespace TablePro.App.Model;

public enum FolderKind
{
    Tables,
    Views,
    MaterializedViews,
    ForeignTables,
    Sequences,
    Functions,
    Procedures,
    Triggers,
    Dictionaries,
    Keys,
    Other,
}

public sealed record ObjectFolder(FolderKind Kind, IReadOnlyList<ObjectEntry> Objects);

// TreeView is not virtualized, so a folder shows its first PageSize objects and a filter uses a virtualized list.
public static class ObjectFolders
{
    public const int PageSize = 500;

    public static IReadOnlyList<ObjectFolder> Group(IEnumerable<ObjectEntry> objects)
    {
        ArgumentNullException.ThrowIfNull(objects);
        return
        [
            .. objects
                .GroupBy(entry => Folder(entry.Kind))
                .OrderBy(group => group.Key)
                .Select(group => new ObjectFolder(
                    group.Key,
                    [.. group.OrderBy(entry => entry.Name, StringComparer.CurrentCultureIgnoreCase)])),
        ];
    }

    public static FolderKind Folder(ObjectKind kind) => kind switch
    {
        ObjectKind.Table or ObjectKind.PartitionedTable => FolderKind.Tables,
        ObjectKind.View => FolderKind.Views,
        ObjectKind.MaterializedView => FolderKind.MaterializedViews,
        ObjectKind.ForeignTable => FolderKind.ForeignTables,
        ObjectKind.Sequence => FolderKind.Sequences,
        ObjectKind.Function => FolderKind.Functions,
        ObjectKind.Procedure => FolderKind.Procedures,
        ObjectKind.Trigger => FolderKind.Triggers,
        ObjectKind.Dictionary => FolderKind.Dictionaries,
        ObjectKind.Key => FolderKind.Keys,
        _ => FolderKind.Other,
    };

    public static bool HasRows(ObjectKind kind) => kind is ObjectKind.Table or ObjectKind.PartitionedTable
        or ObjectKind.View or ObjectKind.MaterializedView or ObjectKind.ForeignTable;

    public static IReadOnlyList<ObjectEntry> Filter(IEnumerable<ObjectEntry> objects, string text)
    {
        ArgumentNullException.ThrowIfNull(objects);
        var needle = text?.Trim() ?? string.Empty;
        if (needle.Length == 0)
        {
            return [];
        }

        return
        [
            .. objects
                .Where(entry => entry.Name.Contains(needle, StringComparison.CurrentCultureIgnoreCase))
                .OrderBy(entry => entry.Name.StartsWith(needle, StringComparison.CurrentCultureIgnoreCase) ? 0 : 1)
                .ThenBy(entry => entry.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(entry => entry.Schema, StringComparer.CurrentCultureIgnoreCase),
        ];
    }
}
