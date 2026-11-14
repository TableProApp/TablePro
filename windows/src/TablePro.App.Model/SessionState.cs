using System.Text.Json.Serialization;
using TablePro.Interop;

namespace TablePro.App.Model;

public enum TabKind
{
    Query,
    Table,

    // A function, procedure, trigger or sequence, shown as its definition.
    Definition,
}

public sealed record SessionTab
{
    public TabKind Kind { get; set; }

    public string Title { get; set; } = string.Empty;

    public string? Sql { get; set; }

    public string? Schema { get; set; }

    public string? Table { get; set; }

    // A table tab's own rows per page, when one was picked, and the first row of the page it shows.
    public int? PageSize { get; set; }

    public long? Offset { get; set; }

    // The ObjectKind name a table or definition tab was opened for.
    public string? ObjectKind { get; set; }

    // The table a trigger fires on.
    public string? ParentTable { get; set; }

    public SavedFilter? Filter { get; set; }

    // The database a query tab opened from a definition runs in, where the definition names none.
    public string? Database { get; set; }

    // A table tab's pending changes by key, which the session's writes keep until a close has asked about them.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public SavedEdits? Edits { get; set; }

    // The tab's own connection held a transaction, which the server rolled back as the app ended.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public bool HeldTransaction { get; set; }

    // What the app ended holding without a close, which a launch brings back even with Reopen at startup off.
    [JsonIgnore]
    public bool HasRecoveredWork => Edits is { Changes: > 0 } || HeldTransaction;

    // A name this build does not define, as from a later build, reads as the fallback.
    public ObjectKind ObjectKindOr(ObjectKind fallback) =>
        SavedName.TryParse(ObjectKind, out ObjectKind kind) ? kind : fallback;
}

// A table tab's filter as the session file keeps it, its operators and combinator by name.
public sealed record SavedFilter
{
    public string Combinator { get; set; } = nameof(FilterCombinator.And);

    public IReadOnlyList<SavedFilterRule> Rules { get; set; } = [];

    public string? RawSql { get; set; }

    public static SavedFilter From(TableFilter filter)
    {
        ArgumentNullException.ThrowIfNull(filter);
        return new SavedFilter
        {
            Combinator = Enum.GetName(filter.Combinator) ?? nameof(FilterCombinator.And),
            Rules = [.. filter.Rules.Select(rule => new SavedFilterRule
            {
                Column = rule.Column,
                Operator = Enum.GetName(rule.Operator) ?? string.Empty,
                Values = ValuesOf(rule.Value),
            })],
            RawSql = filter.RawSql,
        };
    }

    // A rule this build cannot read back, as an operator a later build added, is left out rather than refused.
    public TableFilter? ToFilter()
    {
        List<FilterRule> rules = [];
        foreach (var saved in Rules ?? [])
        {
            if (saved is { Column.Length: > 0 }
                && SavedName.TryParse(saved.Operator, out FilterOperator op)
                && TryValue(op, saved.Values ?? [], out var value))
            {
                rules.Add(new FilterRule(saved.Column, op, value));
            }
        }

        var raw = string.IsNullOrWhiteSpace(RawSql) ? null : RawSql;
        if (rules.Count == 0 && raw is null)
        {
            return null;
        }

        var combinator = SavedName.TryParse(Combinator, out FilterCombinator named) ? named : FilterCombinator.And;
        return new TableFilter(combinator, rules, raw);
    }

    private static string[] ValuesOf(FilterValue? value) => value switch
    {
        FilterValue.One single => [single.Value],
        FilterValue.Pair pair => [pair.Low, pair.High],
        FilterValue.List list => [.. list.Values],
        _ => [],
    };

    // The operator says how many values it takes, as the filter bar reads it.
    private static bool TryValue(FilterOperator op, IReadOnlyList<string> values, out FilterValue? value)
    {
        value = null;
        switch (TableFilterDraft.ShapeOf(op))
        {
            case FilterValueShape.None:
                return true;
            case FilterValueShape.One when values.Count == 1:
                value = new FilterValue.One(values[0]);
                return true;
            case FilterValueShape.Two when values.Count == 2:
                value = new FilterValue.Pair(values[0], values[1]);
                return true;
            case FilterValueShape.List when values.Count > 0:
                value = new FilterValue.List([.. values]);
                return true;
            default:
                return false;
        }
    }
}

public sealed record SavedFilterRule
{
    public string Column { get; set; } = string.Empty;

    public string Operator { get; set; } = string.Empty;

    // None for the null tests, one value, the two bounds of Between, or the items of In and Not in.
    public IReadOnlyList<string> Values { get; set; } = [];
}

internal static class SavedName
{
    // Only a name this build defines, never a number, so a file from another build cannot pick some other value.
    public static bool TryParse<T>(string? name, out T value)
        where T : struct, Enum =>
        Enum.TryParse(name, out value) && string.Equals(Enum.GetName(value), name, StringComparison.Ordinal);
}

// A saved connection is reopened by id, a file opened without saving by its path.
public sealed record SessionConnection
{
    public Guid? ConnectionId { get; set; }

    public string? FilePath { get; set; }

    public string Name { get; set; } = string.Empty;

    public string EngineId { get; set; } = string.Empty;

    public IReadOnlyList<SessionTab> Tabs { get; set; } = [];

    public int SelectedTab { get; set; }

    public bool IsRestorable => ConnectionId is not null || !string.IsNullOrEmpty(FilePath);
}

// GetWindowPlacement's restored bounds, in physical pixels; Windows moves a window off a display that is gone.
public sealed record WindowPlacement
{
    public int X { get; set; }

    public int Y { get; set; }

    public int Width { get; set; }

    public int Height { get; set; }

    public bool Maximized { get; set; }

    public bool IsUsable => Width > 0 && Height > 0;
}

// A window a tab was moved into: one connection, its own tabs and its own place on the screen.
public sealed record TabWindowState
{
    public SessionConnection Connection { get; set; } = new();

    public WindowPlacement? Placement { get; set; }
}

public sealed record SessionState
{
    public IReadOnlyList<SessionConnection> Connections { get; set; } = [];

    // The connection in front when the window closed, which is the only one that connects at launch.
    public int Front { get; set; } = -1;

    // Kept whether or not the connections are reopened.
    public WindowPlacement? Window { get; set; }

    // In effective pixels; every workspace shares it.
    public double? ObjectPaneWidth { get; set; }

    public IReadOnlyList<TabWindowState> TabWindows { get; set; } = [];

    public static SessionState Empty { get; } = new();

    private static WindowPlacement? Usable(WindowPlacement? placement) => placement is { IsUsable: true } ? placement : null;

    public SessionState Restorable()
    {
        var kept = Connections.Where(connection => connection.IsRestorable).ToList();
        var front = Front >= 0 && Front < Connections.Count ? kept.IndexOf(Connections[Front]) : -1;
        return new SessionState
        {
            Connections = kept,
            Front = front < 0 && kept.Count > 0 ? 0 : front,
            Window = Usable(Window),
            ObjectPaneWidth = ObjectPaneWidth is { } width ? ObjectPane.Clamp(width) : null,
            // A window comes back only with a connection to reopen and a tab to show.
            TabWindows = [.. TabWindows
                .Where(window => window.Connection is { IsRestorable: true, Tabs.Count: > 0 })
                .Select(window => window with { Placement = Usable(window.Placement) })],
        };
    }

    // Only the tabs holding recovered work, in their connections and windows, for a launch with Reopen at startup off.
    public SessionState Recovered()
    {
        List<SessionConnection> kept = [];
        var front = -1;
        for (var index = 0; index < Connections.Count; index++)
        {
            if (RecoveredTabs(Connections[index]) is { } connection)
            {
                if (index == Front)
                {
                    front = kept.Count;
                }

                kept.Add(connection);
            }
        }

        return new SessionState
        {
            Connections = kept,
            Front = front < 0 && kept.Count > 0 ? 0 : front,
            Window = Window,
            ObjectPaneWidth = ObjectPaneWidth,
            TabWindows = [.. TabWindows
                .Select(window => window is not null && RecoveredTabs(window.Connection) is { } connection
                    ? window with { Connection = connection }
                    : null)
                .OfType<TabWindowState>()],
        };
    }

    private static SessionConnection? RecoveredTabs(SessionConnection? connection)
    {
        if (connection is null)
        {
            return null;
        }

        var tabs = connection.Tabs ?? [];
        List<SessionTab> kept = [];
        var selected = 0;
        for (var index = 0; index < tabs.Count; index++)
        {
            if (tabs[index] is { HasRecoveredWork: true } tab)
            {
                if (index == connection.SelectedTab)
                {
                    selected = kept.Count;
                }

                kept.Add(tab);
            }
        }

        return kept.Count == 0 ? null : connection with { Tabs = kept, SelectedTab = selected };
    }
}

public static class ObjectPane
{
    public const double DefaultWidth = 280;
    public const double MinWidth = 180;
    public const double MaxWidth = 640;

    public static double Clamp(double width) =>
        double.IsFinite(width) ? Math.Clamp(width, MinWidth, MaxWidth) : DefaultWidth;
}

public sealed class SessionStore(string path)
{
    public string Path { get; } = path;

    public SessionState Load() => (JsonFile.Read(Path, ModelJson.Default.SessionState) ?? SessionState.Empty).Restorable();

    public void Save(SessionState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        JsonFile.Write(Path, state, ModelJson.Default.SessionState);
    }
}
