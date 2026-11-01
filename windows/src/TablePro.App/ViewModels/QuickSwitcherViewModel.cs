using System.Collections.Immutable;
using CommunityToolkit.Mvvm.ComponentModel;
using TablePro.Core.Schema;
using TablePro.Core.Search;

namespace TablePro.App.ViewModels;

public enum QuickSwitcherKind
{
    Tab,
    Object,
    Database,
    Schema,
}

/// <summary>One row of the quick switcher: an open tab, a database object, or a database or schema to switch to.</summary>
public sealed record QuickSwitcherItem(string Id, QuickSwitcherKind Kind, string Name, string Location, string Glyph, double Weight)
{
    public object? Target { get; init; }

    /// <summary>The positions in <see cref="Name"/> the query matched, for highlighting.</summary>
    public ImmutableArray<int> Matched { get; init; } = [];

    public string KindText => Kind switch
    {
        QuickSwitcherKind.Tab => Strings.Get("Panes/QuickSwitcherKindTab"),
        QuickSwitcherKind.Database => Strings.Get("Panes/QuickSwitcherKindDatabase"),
        QuickSwitcherKind.Schema => Strings.Get("Panes/QuickSwitcherKindSchema"),
        _ => Target is DatabaseObject obj ? SidebarEntry.KindName(obj.Kind) : string.Empty,
    };
}

/// <summary>
/// Open Quickly, as on macOS: fuzzy-matches every object, database, schema and open tab of the connection and ranks
/// the matches by match quality, kind and how often and lately each was picked.
/// </summary>
public sealed partial class QuickSwitcherViewModel : ObservableObject
{
    private const int MaxResults = 100;
    private const int MaxRecent = 30;

    private readonly WorkspaceViewModel _workspace;
    private readonly QuickSwitcherItem[] _items;

    public QuickSwitcherViewModel(WorkspaceViewModel workspace)
    {
        _workspace = workspace;
        _items = BuildItems(workspace);
        Filter();
    }

    public IReadOnlyList<QuickSwitcherItem> Results { get; private set; } = [];

    [ObservableProperty]
    public partial string Query { get; set; } = string.Empty;

    [ObservableProperty]
    public partial int SelectedIndex { get; set; }

    public QuickSwitcherItem? Selected => SelectedIndex >= 0 && SelectedIndex < Results.Count ? Results[SelectedIndex] : null;

    public void Move(int delta)
    {
        if (Results.Count > 0)
        {
            SelectedIndex = Math.Clamp(SelectedIndex + delta, 0, Results.Count - 1);
        }
    }

    /// <summary>Opens the item; <paramref name="structure"/> opens a table on its Structure section instead of its rows.</summary>
    public void Commit(QuickSwitcherItem item, bool structure)
    {
        var now = DateTimeOffset.UtcNow;
        switch (item.Target)
        {
            case TabViewModel tab:
                if (tab is TableTabViewModel table)
                {
                    _workspace.Opened.Record(ObjectId(table.Table), now);
                }

                _workspace.SelectedTab = tab;
                return;

            case DatabaseObject obj:
                _workspace.Opened.Record(item.Id, now);
                _workspace.OpenTable(obj, structure && obj.HasRows ? TableTabSection.Structure : obj.HasRows ? TableTabSection.Data : TableTabSection.Definition);
                return;
        }

        _workspace.Opened.Record(item.Id, now);
        if (item.Kind == QuickSwitcherKind.Database)
        {
            _workspace.SelectedDatabase = item.Name;
        }
        else if (item.Kind == QuickSwitcherKind.Schema)
        {
            _workspace.SelectedSchema = item.Name;
        }
    }

    partial void OnQueryChanged(string value) => Filter();

    private void Filter()
    {
        var query = Query.Trim();
        var now = DateTimeOffset.UtcNow;
        Results = query.Length == 0 ? Unfiltered() : Ranked(query, now);
        SelectedIndex = Results.Count > 0 ? 0 : -1;
        OnPropertyChanged(nameof(Results));
    }

    // With nothing typed: the open tabs, then what was picked lately, then the first objects of the catalog.
    private QuickSwitcherItem[] Unfiltered()
    {
        var byId = new Dictionary<string, QuickSwitcherItem>(StringComparer.Ordinal);
        foreach (var item in _items)
        {
            byId.TryAdd(item.Id, item);
        }

        var tabs = _items.Where(i => i.Kind == QuickSwitcherKind.Tab);
        var recent = _workspace.Opened.RecentIds().Select(id => byId.GetValueOrDefault(id)).OfType<QuickSwitcherItem>().Take(MaxRecent);
        var rest = _items.Where(i => i.Kind == QuickSwitcherKind.Object);
        return tabs.Concat(recent).Concat(rest).Distinct().Take(MaxResults).ToArray();
    }

    private QuickSwitcherItem[] Ranked(string query, DateTimeOffset now)
    {
        // "sales.ord" lines the query up with schema.name; a plain query matches the name alone.
        var qualified = query.Contains('.', StringComparison.Ordinal);
        var ranked = new List<(QuickSwitcherItem Item, double Rank)>();
        foreach (var item in _items)
        {
            var prefix = qualified && item.Location.Length > 0 ? item.Location + "." : string.Empty;
            var candidate = prefix + item.Name;
            if (!FuzzyMatcher.TryMatch(query, candidate, out var match))
            {
                continue;
            }

            var matched = match.Indices.Where(i => i >= prefix.Length).Select(i => i - prefix.Length).ToImmutableArray();
            var rank = match.Score * item.Weight * (1 + _workspace.Opened.Score(item.Id, now));
            ranked.Add((item with { Matched = matched }, rank));
        }

        return ranked.OrderByDescending(r => r.Rank).ThenBy(r => r.Item.Name.Length).Take(MaxResults).Select(r => r.Item).ToArray();
    }

    private static string ObjectId(DatabaseObject obj) => $"obj:{obj.Name.Schema}.{obj.Name.Name}";

    private static QuickSwitcherItem[] BuildItems(WorkspaceViewModel workspace)
    {
        var items = new List<QuickSwitcherItem>();
        foreach (var tab in workspace.Tabs)
        {
            items.Add(new QuickSwitcherItem($"tab:{items.Count}", QuickSwitcherKind.Tab, tab.Title, tab.Subtitle ?? string.Empty, tab.Glyph, 1.15) { Target = tab });
        }

        foreach (var obj in workspace.Session.Objects)
        {
            var weight = obj.Kind switch
            {
                ObjectKind.Table or ObjectKind.Collection => 1.0,
                ObjectKind.View or ObjectKind.MaterializedView => 0.95,
                _ => 0.85,
            };
            items.Add(new QuickSwitcherItem(ObjectId(obj), QuickSwitcherKind.Object, obj.Name.Name, obj.Name.Schema ?? string.Empty, SidebarEntry.GlyphFor(obj.Kind), weight) { Target = obj });
        }

        if (workspace.CanSwitchDatabase)
        {
            foreach (var database in workspace.Databases)
            {
                items.Add(new QuickSwitcherItem($"db:{database}", QuickSwitcherKind.Database, database, string.Empty, "", 0.9));
            }
        }

        if (workspace.HasSchemas)
        {
            foreach (var schema in workspace.Schemas)
            {
                items.Add(new QuickSwitcherItem($"schema:{schema}", QuickSwitcherKind.Schema, schema, string.Empty, "", 0.9));
            }
        }

        return [.. items];
    }
}
