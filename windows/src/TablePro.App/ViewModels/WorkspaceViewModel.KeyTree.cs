using System.Globalization;
using Microsoft.UI.Xaml;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.App.ViewModels;

/// <summary>A row of the sidebar's key tree: a namespace that groups keys by a shared prefix, or a key under one.</summary>
public sealed partial class SidebarEntry
{
    /// <summary>The namespace this row stands for, or null for a key, an object or a section header.</summary>
    public KeyNamespaceNode? Namespace { get; private init; }

    /// <summary>How deep in the key tree the row sits; 0 for everything outside it.</summary>
    public int Depth { get; private init; }

    public bool IsExpanded { get; private init; }

    public Thickness Indent => new(Depth * 16, 0, 0, 0);

    public static SidebarEntry ForNamespace(KeyNamespaceNode node, int depth, bool expanded) =>
        new(node.Name, expanded ? "\xE838" : "\xE8B7", null, node.KeyCount.ToString("N0", CultureInfo.CurrentCulture)) { Namespace = node, Depth = depth, IsExpanded = expanded };

    /// <summary>A key under a namespace, named by what follows the namespace's prefix.</summary>
    public static SidebarEntry ForKey(KeyNamespaceNode node, int depth)
    {
        var key = node.Key!;
        var text = node.Name.Length > 0 ? node.Name : key.Name.Name;
        return new(text, GlyphFor(key.Kind), key, key.RowEstimate is > 0 ? FormatCount(key.RowEstimate.Value) : null) { Depth = depth };
    }
}

/// <summary>
/// The sidebar's key tree, as macOS groups a Redis database's keys at a separator (<c>user:1:name</c> under
/// <c>user</c> then <c>1</c>), and the actions the sidebar offers on objects of engines that are not SQL.
/// </summary>
public sealed partial class WorkspaceViewModel
{
    private readonly HashSet<string> _expandedNamespaces = new(StringComparer.Ordinal);

    /// <summary>The separator keys are grouped at, or null when the engine lists keys flat or has none.</summary>
    private string? KeySeparator => Session.Database is IKeyBrowseProvider { KeySeparator: { Length: > 0 } separator } ? separator : null;

    /// <summary>Adds the key rows of the sidebar as a tree; a search shows every namespace open, so each match is in sight.</summary>
    private void AddKeyTree(IEnumerable<DatabaseObject> keys, string separator, bool expandAll)
    {
        var tree = KeyNamespaceTree.Build(keys, separator);
        foreach (var row in Rows(tree, 0, expandAll))
        {
            Sidebar.Add(row);
        }
    }

    private IEnumerable<SidebarEntry> Rows(IReadOnlyList<KeyNamespaceNode> nodes, int depth, bool expandAll) =>
        KeyNamespaceTree.Flatten(nodes, n => expandAll || _expandedNamespaces.Contains(n.Prefix), depth)
            .Select(r => r.Node.IsNamespace
                ? SidebarEntry.ForNamespace(r.Node, r.Depth, expandAll || _expandedNamespaces.Contains(r.Node.Prefix))
                : SidebarEntry.ForKey(r.Node, r.Depth));

    /// <summary>
    /// Opens or closes a namespace in place, inserting or removing only its rows, so the list keeps its scroll
    /// position rather than being rebuilt.
    /// </summary>
    public void ToggleNamespace(SidebarEntry entry)
    {
        var index = Sidebar.IndexOf(entry);
        if (entry.Namespace is not { } node || index < 0)
        {
            return;
        }

        var expand = !entry.IsExpanded;
        if (expand)
        {
            _expandedNamespaces.Add(node.Prefix);
            var at = index + 1;
            foreach (var row in Rows(node.Children, entry.Depth + 1, expandAll: false))
            {
                Sidebar.Insert(at++, row);
            }
        }
        else
        {
            _expandedNamespaces.Remove(node.Prefix);
            while (index + 1 < Sidebar.Count && !Sidebar[index + 1].IsHeader && Sidebar[index + 1].Depth > entry.Depth)
            {
                Sidebar.RemoveAt(index + 1);
            }
        }

        Sidebar[index] = SidebarEntry.ForNamespace(node, entry.Depth, expand);
    }

    /// <summary>Opens the database's list of keys narrowed to a namespace, as picking a namespace does on macOS.</summary>
    public async Task BrowseNamespaceAsync(KeyNamespaceNode node)
    {
        if (Session.Database is not IKeyBrowseProvider keys || Session.Objects.FirstOrDefault(o => keys.GetKeyBrowse(o.Name) is not null) is not { } listing)
        {
            return;
        }

        await OpenTable(listing).BrowseKeyPatternAsync(KeyBrowseInfo.NamespacePattern(node.Prefix));
    }

    /// <summary>
    /// Whether the sidebar offers a change on an object. A SQL engine goes by its structure editor, as before; any
    /// other engine offers what its session can write, such as DEL and RENAME on a Redis key or deleting a Kafka topic.
    /// </summary>
    public bool Offers(DatabaseObject obj, SchemaChange change)
    {
        if (IsSql)
        {
            return CanEditStructure && (change is DropObject || obj.Kind == ObjectKind.Table);
        }

        return !Profile.IsReadOnly && Session.Database is ISchemaDdlProvider ddl && ddl.BuildDdl(obj.Name, change).Count > 0;
    }
}
