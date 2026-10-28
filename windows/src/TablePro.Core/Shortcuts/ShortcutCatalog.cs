using System.Collections.Frozen;

namespace TablePro.Core.Shortcuts;

/// <summary>The ids of the customizable commands, as the settings file stores them.</summary>
public static class ShortcutIds
{
    // Editor & Query: the SQL editor dispatches these.
    public const string ExecuteQuery = "executeQuery";
    public const string ExecuteAllStatements = "executeAllStatements";
    public const string ExplainQuery = "explainQuery";
    public const string FormatQuery = "formatQuery";
    public const string SaveFile = "saveChanges";
    public const string ToggleComment = "toggleComment";
    public const string Find = "find";
    public const string FindAndReplace = "findAndReplace";
    public const string FindNext = "findNext";
    public const string FindPrevious = "findPrevious";

    // Workspace window commands.
    public const string SearchDatabase = "searchDatabase";
    public const string RunSqlFile = "runSqlFile";
    public const string ExportDatabase = "exportDatabase";
    public const string NewTab = "newTab";
    public const string CloseTab = "closeTab";
    public const string CloseOtherTabs = "closeOtherTabs";
    public const string CloseAllTabs = "closeAllTabs";
    public const string ShowNextTab = "showNextTab";
    public const string ShowPreviousTab = "showPreviousTab";
    public const string QuickSwitcher = "quickSwitcher";
    public const string FocusSidebarSearch = "focusSidebarSearch";
    public const string FocusObjectList = "focusObjectList";
    public const string ToggleTableBrowser = "toggleTableBrowser";
    public const string ToggleHistory = "toggleHistory";
    public const string ShowFavoritesList = "showFavoritesList";
    public const string ToggleAssistant = "toggleAssistant";
    public const string ServerDashboard = "serverDashboard";
    public const string ErDiagram = "erDiagram";
    public const string ManageConnections = "manageConnections";
    public const string Disconnect = "disconnect";
    public const string OpenSettings = "openSettings";
}

/// <summary>
/// Every command a user can rebind, with its default chord. A command absent here is not customizable; the keys the
/// editor, the grid and Windows keep for themselves are in <see cref="ReservedShortcuts"/>.
/// </summary>
public static class ShortcutCatalog
{
    private static readonly ShortcutCommand[] Commands =
    [
        // Run All is F5 rather than the macOS Shift+Command+Return: F5 is what SSMS, Azure Data Studio and the
        // other Windows SQL tools execute with, and what the editor's own menus already show.
        Editor(ShortcutIds.ExecuteQuery, "Run Current Statement", KeyChord.Ctrl(ShortcutKey.Enter)),
        Editor(ShortcutIds.ExecuteAllStatements, "Run All Statements", new KeyChord(ShortcutKey.F5)),
        Editor(ShortcutIds.ExplainQuery, "Explain Query", KeyChord.CtrlShift(ShortcutKey.E)),
        Editor(ShortcutIds.FormatQuery, "Format Query", KeyChord.CtrlShift(ShortcutKey.F)),
        Editor(ShortcutIds.SaveFile, "Save File", KeyChord.Ctrl(ShortcutKey.S)),
        Editor(ShortcutIds.ToggleComment, "Toggle Comment", KeyChord.Ctrl(ShortcutKey.Slash)),
        Editor(ShortcutIds.Find, "Find", KeyChord.Ctrl(ShortcutKey.F)),
        Editor(ShortcutIds.FindAndReplace, "Find and Replace", KeyChord.Ctrl(ShortcutKey.H)),
        Editor(ShortcutIds.FindNext, "Find Next", new KeyChord(ShortcutKey.F3)),
        Editor(ShortcutIds.FindPrevious, "Find Previous", KeyChord.Shift(ShortcutKey.F3)),
        Window(ShortcutIds.RunSqlFile, "Run SQL File", ShortcutCategory.Editor, KeyChord.None),
        Window(ShortcutIds.ExportDatabase, "Export Database", ShortcutCategory.Editor, KeyChord.None),

        Window(ShortcutIds.NewTab, "New Tab", ShortcutCategory.Navigation, KeyChord.Ctrl(ShortcutKey.T)),
        Window(ShortcutIds.CloseTab, "Close Tab", ShortcutCategory.Navigation, KeyChord.Ctrl(ShortcutKey.W)),
        Window(ShortcutIds.CloseOtherTabs, "Close Other Tabs", ShortcutCategory.Navigation, KeyChord.None),
        Window(ShortcutIds.CloseAllTabs, "Close All Tabs", ShortcutCategory.Navigation, KeyChord.None),
        Window(ShortcutIds.ShowNextTab, "Show Next Tab", ShortcutCategory.Navigation, KeyChord.Ctrl(ShortcutKey.Tab)),
        Window(ShortcutIds.ShowPreviousTab, "Show Previous Tab", ShortcutCategory.Navigation, KeyChord.CtrlShift(ShortcutKey.Tab)),
        Window(ShortcutIds.QuickSwitcher, "Open Quickly", ShortcutCategory.Navigation, KeyChord.CtrlShift(ShortcutKey.O)),
        Window(ShortcutIds.SearchDatabase, "Search Database", ShortcutCategory.Navigation, KeyChord.CtrlAlt(ShortcutKey.F)),
        Window(ShortcutIds.FocusSidebarSearch, "Focus Sidebar Filter", ShortcutCategory.Navigation, KeyChord.Ctrl(ShortcutKey.P)),
        Window(ShortcutIds.FocusObjectList, "Focus Object List", ShortcutCategory.Navigation, KeyChord.None),
        Window(ShortcutIds.ToggleTableBrowser, "Toggle Sidebar", ShortcutCategory.Navigation, new KeyChord(ShortcutKey.F9)),
        Window(ShortcutIds.ToggleHistory, "Toggle History", ShortcutCategory.Navigation, KeyChord.CtrlShift(ShortcutKey.H)),
        Window(ShortcutIds.ShowFavoritesList, "Show Favorites", ShortcutCategory.Navigation, KeyChord.None),
        Window(ShortcutIds.ToggleAssistant, "Toggle Assistant", ShortcutCategory.Navigation, KeyChord.CtrlAlt(ShortcutKey.A)),
        Window(ShortcutIds.ServerDashboard, "Server Dashboard", ShortcutCategory.Navigation, KeyChord.None),
        Window(ShortcutIds.ErDiagram, "ER Diagram", ShortcutCategory.Navigation, KeyChord.None),

        Window(ShortcutIds.ManageConnections, "Manage Connections", ShortcutCategory.Connections, KeyChord.None),
        Window(ShortcutIds.Disconnect, "Disconnect", ShortcutCategory.Connections, KeyChord.None),

        Window(ShortcutIds.OpenSettings, "Settings", ShortcutCategory.App, KeyChord.Ctrl(ShortcutKey.Comma)),
    ];

    private static readonly FrozenDictionary<string, ShortcutCommand> ById = Commands.ToFrozenDictionary(c => c.Id, StringComparer.Ordinal);

    /// <summary>Every command, grouped by category in the order the settings page lists them.</summary>
    public static IReadOnlyList<ShortcutCommand> All => Commands;

    public static ShortcutCommand? Find(string id) => ById.GetValueOrDefault(id);

    public static ShortcutCommand Get(string id) =>
        ById.TryGetValue(id, out var command) ? command : throw new KeyNotFoundException($"No shortcut command '{id}'.");

    public static IEnumerable<ShortcutCommand> InCategory(ShortcutCategory category) => Commands.Where(c => c.Category == category);

    private static ShortcutCommand Editor(string id, string title, KeyChord chord) =>
        new(id, title, ShortcutCategory.Editor, ShortcutContext.Editor, chord);

    private static ShortcutCommand Window(string id, string title, ShortcutCategory category, KeyChord chord) =>
        new(id, title, category, ShortcutContext.Global, chord);
}
