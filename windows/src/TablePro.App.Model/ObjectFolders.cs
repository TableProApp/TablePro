using System.Globalization;
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

    // The culture is passed in, since a schema's objects are sorted off the UI thread.
    public static IReadOnlyList<ObjectFolder> Group(IEnumerable<ObjectEntry> objects, CultureInfo culture)
    {
        ArgumentNullException.ThrowIfNull(objects);
        ArgumentNullException.ThrowIfNull(culture);
        var names = StringComparer.Create(culture, ignoreCase: true);
        return
        [
            .. objects
                .GroupBy(entry => Folder(entry.Kind))
                .OrderBy(group => group.Key)
                .Select(group => new ObjectFolder(group.Key, [.. group.OrderBy(entry => entry.Name, names)])),
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

    // As the core's ObjectKind::has_definition: it opens as SQL to read rather than rows to page.
    public static bool HasDefinition(ObjectKind kind) => kind is ObjectKind.Function or ObjectKind.Procedure
        or ObjectKind.Sequence or ObjectKind.Trigger;
}

// Every object of a connection in the filter's order, sorted once so that a keystroke only scans it.
public sealed class ObjectCatalog
{
    private const int CancelCheckInterval = 1024;

    private readonly ObjectEntry[] _sorted;
    private readonly CompareInfo _compare;

    public ObjectCatalog(IEnumerable<ObjectEntry> objects, CultureInfo culture)
    {
        ArgumentNullException.ThrowIfNull(objects);
        ArgumentNullException.ThrowIfNull(culture);
        var names = StringComparer.Create(culture, ignoreCase: true);
        _compare = culture.CompareInfo;
        _sorted = [.. objects.OrderBy(entry => entry.Name, names).ThenBy(entry => entry.Schema, names)];
    }

    public int Count => _sorted.Length;

    // Names that start with the text come first; both parts keep the catalog's order, so the list reads by name.
    public IReadOnlyList<ObjectEntry> Filter(string text, CancellationToken cancellationToken = default)
    {
        var needle = text?.Trim() ?? string.Empty;
        if (needle.Length == 0)
        {
            return [];
        }

        var starting = new List<ObjectEntry>();
        var containing = new List<ObjectEntry>();
        for (var index = 0; index < _sorted.Length; index++)
        {
            if (index % CancelCheckInterval == 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }

            var entry = _sorted[index];
            if (_compare.IndexOf(entry.Name, needle, CompareOptions.IgnoreCase) < 0)
            {
                continue;
            }

            (_compare.IsPrefix(entry.Name, needle, CompareOptions.IgnoreCase) ? starting : containing).Add(entry);
        }

        starting.AddRange(containing);
        return starting;
    }
}
