using TablePro.Interop;

namespace TablePro.App.Model.QuickSwitcher;

// A port of the macOS QuickSwitcherItemKind, plus Connection and Command, which the Windows palette draws from the
// library and the menu as well as the front connection's catalog.
public enum PaletteItemKind
{
    Table,
    View,
    SystemTable,
    Database,
    Schema,
    Procedure,
    Function,
    Trigger,
    Type,
    SavedQuery,
    History,
    Connection,
    Command,
}

// How a committed item opens, as QuickSwitcherCommitIntent.
public enum PaletteCommitIntent
{
    Open,
    OpenInNewTab,
    OpenStructure,
}

// The scopes the palette's selector offers; All draws from every kind.
public enum PaletteScope
{
    All,
    Tables,
    Databases,
    Queries,
    Connections,
    Commands,
}

public static class PaletteScopes
{
    public static IReadOnlyList<PaletteScope> All { get; } =
        [PaletteScope.All, PaletteScope.Tables, PaletteScope.Databases, PaletteScope.Queries, PaletteScope.Connections, PaletteScope.Commands];

    // Null for All, which shows every kind.
    public static IReadOnlySet<PaletteItemKind>? IncludedKinds(this PaletteScope scope) => scope switch
    {
        PaletteScope.All => null,
        PaletteScope.Tables => Tables,
        PaletteScope.Databases => Containers,
        PaletteScope.Queries => Queries,
        PaletteScope.Connections => Connections,
        PaletteScope.Commands => Commands,
        _ => null,
    };

    private static readonly HashSet<PaletteItemKind> Tables =
        [PaletteItemKind.Table, PaletteItemKind.View, PaletteItemKind.SystemTable];

    private static readonly HashSet<PaletteItemKind> Containers =
        [PaletteItemKind.Database, PaletteItemKind.Schema];

    private static readonly HashSet<PaletteItemKind> Queries =
        [PaletteItemKind.SavedQuery, PaletteItemKind.History];

    private static readonly HashSet<PaletteItemKind> Connections = [PaletteItemKind.Connection];

    private static readonly HashSet<PaletteItemKind> Commands = [PaletteItemKind.Command];
}

// Where a result in another connection lives, so a committed row reaches that connection and database.
public sealed record PaletteTarget(Guid ConnectionId, string ConnectionName, string? DatabaseName, string? SchemaName);

// A single row in the palette. Built once per load and ranked per keystroke; MatchedIndices are filled only on the rows
// kept for display.
public sealed record PaletteItem
{
    public required string FrecencyKey { get; init; }

    public required string Name { get; init; }

    public required PaletteItemKind Kind { get; init; }

    public string Subtitle { get; init; } = string.Empty;

    // Ranked at full weight, unlike the subtitle. A saved query's subtitle names its connection; the author's keyword
    // should score as its name does.
    public string? Keyword { get; init; }

    // SQL for a query, the connection id for a connection row, else null.
    public string? Payload { get; init; }

    public IReadOnlyList<int> MatchedIndices { get; init; } = [];

    // Boosts a row whose tab is already open, as QuickSwitcherRanking.openTabBoost.
    public bool IsOpenInTab { get; init; }

    public string? SchemaName { get; init; }

    public string? DatabaseName { get; init; }

    // The catalog entry a table, view or routine row opens; null for a database, schema, query, connection or command.
    public ObjectEntry? ObjectEntry { get; init; }

    // The menu or rail action a command row runs.
    public string? Action { get; init; }

    public PaletteTarget? Target { get; init; }

    // A table in a schema other than the browsed one, whose row names that schema so two such rows differ.
    public bool IsOutsideBrowsedSchema { get; init; }

    public string Id => Target is { } target ? $"{target.ConnectionId}/{FrecencyKey}" : FrecencyKey;

    // Outermost first, for a qualified a.b.c query to line up against.
    public IReadOnlyList<string> SearchLocation => Target is { } target
        ? QualifiedSearchQuery.Location(target.DatabaseName, target.SchemaName)
        : QualifiedSearchQuery.Location(DatabaseName, SchemaName);

    public bool Belongs(Guid connectionId) => Target is not { } target || target.ConnectionId == connectionId;
}
