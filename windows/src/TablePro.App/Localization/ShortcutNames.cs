using System.Globalization;
using TablePro.Core.Shortcuts;

namespace TablePro.App.Localization;

/// <summary>
/// The translated names of the keyboard shortcut commands, their categories and the built-in actions they can collide
/// with. Core keeps its English names for the settings file and its own tests, so the app looks them up here by id.
/// </summary>
internal static class ShortcutNames
{
    private const string SelectTabPrefix = "Select Tab ";

    /// <summary>The command's title in the UI language, or Core's English title for a command added without a key.</summary>
    public static string Title(ShortcutCommand command) => command.Id switch
    {
        ShortcutIds.ExecuteQuery => Strings.Get("Shortcuts/CommandExecuteQuery"),
        ShortcutIds.ExecuteAllStatements => Strings.Get("Shortcuts/CommandExecuteAllStatements"),
        ShortcutIds.ExplainQuery => Strings.Get("Shortcuts/CommandExplainQuery"),
        ShortcutIds.FormatQuery => Strings.Get("Shortcuts/CommandFormatQuery"),
        ShortcutIds.SaveFile => Strings.Get("Shortcuts/CommandSaveFile"),
        ShortcutIds.ToggleComment => Strings.Get("Shortcuts/CommandToggleComment"),
        ShortcutIds.Find => Strings.Get("Shortcuts/CommandFind"),
        ShortcutIds.FindAndReplace => Strings.Get("Shortcuts/CommandFindAndReplace"),
        ShortcutIds.FindNext => Strings.Get("Shortcuts/CommandFindNext"),
        ShortcutIds.FindPrevious => Strings.Get("Shortcuts/CommandFindPrevious"),
        ShortcutIds.GoToDefinition => Strings.Get("Shortcuts/CommandGoToDefinition"),
        ShortcutIds.RenameSymbol => Strings.Get("Shortcuts/CommandRenameSymbol"),
        ShortcutIds.NextQueryIssue => Strings.Get("Shortcuts/CommandNextQueryIssue"),
        ShortcutIds.PreviousQueryIssue => Strings.Get("Shortcuts/CommandPreviousQueryIssue"),
        ShortcutIds.ShowQuickInfo => Strings.Get("Shortcuts/CommandShowQuickInfo"),
        ShortcutIds.SearchDatabase => Strings.Get("Shortcuts/CommandSearchDatabase"),
        ShortcutIds.RunSqlFile => Strings.Get("Shortcuts/CommandRunSqlFile"),
        ShortcutIds.ExportDatabase => Strings.Get("Shortcuts/CommandExportDatabase"),
        ShortcutIds.NewTab => Strings.Get("Shortcuts/CommandNewTab"),
        ShortcutIds.CloseTab => Strings.Get("Shortcuts/CommandCloseTab"),
        ShortcutIds.CloseOtherTabs => Strings.Get("Shortcuts/CommandCloseOtherTabs"),
        ShortcutIds.CloseAllTabs => Strings.Get("Shortcuts/CommandCloseAllTabs"),
        ShortcutIds.ShowNextTab => Strings.Get("Shortcuts/CommandShowNextTab"),
        ShortcutIds.ShowPreviousTab => Strings.Get("Shortcuts/CommandShowPreviousTab"),
        ShortcutIds.QuickSwitcher => Strings.Get("Shortcuts/CommandQuickSwitcher"),
        ShortcutIds.FocusSidebarSearch => Strings.Get("Shortcuts/CommandFocusSidebarSearch"),
        ShortcutIds.FocusObjectList => Strings.Get("Shortcuts/CommandFocusObjectList"),
        ShortcutIds.ToggleTableBrowser => Strings.Get("Shortcuts/CommandToggleTableBrowser"),
        ShortcutIds.ToggleHistory => Strings.Get("Shortcuts/CommandToggleHistory"),
        ShortcutIds.ToggleSqlFiles => Strings.Get("Shortcuts/CommandToggleSqlFiles"),
        ShortcutIds.ShowFavoritesList => Strings.Get("Shortcuts/CommandShowFavoritesList"),
        ShortcutIds.ToggleAssistant => Strings.Get("Shortcuts/CommandToggleAssistant"),
        ShortcutIds.ServerDashboard => Strings.Get("Shortcuts/CommandServerDashboard"),
        ShortcutIds.ErDiagram => Strings.Get("Shortcuts/CommandErDiagram"),
        ShortcutIds.ManageConnections => Strings.Get("Shortcuts/CommandManageConnections"),
        ShortcutIds.Disconnect => Strings.Get("Shortcuts/CommandDisconnect"),
        ShortcutIds.OpenSettings => Strings.Get("Shortcuts/CommandOpenSettings"),
        _ => command.Title,
    };

    public static string Category(ShortcutCategory category) => category switch
    {
        ShortcutCategory.Editor => Strings.Get("Shortcuts/CategoryEditor"),
        ShortcutCategory.DataGrid => Strings.Get("Shortcuts/CategoryDataGrid"),
        ShortcutCategory.Navigation => Strings.Get("Shortcuts/CategoryNavigation"),
        ShortcutCategory.Connections => Strings.Get("Shortcuts/CategoryConnections"),
        _ => Strings.Get("Shortcuts/CategoryApp"),
    };

    /// <summary>
    /// The translated name of a built-in a chord is reserved for. Core names them only in English, so the match is on
    /// that name; one without a key shows as Core wrote it.
    /// </summary>
    public static string Reserved(string name) => name switch
    {
        "Close Window" => Strings.Get("Shortcuts/ReservedCloseWindow"),
        "Switch Apps" => Strings.Get("Shortcuts/ReservedSwitchApps"),
        "Cycle Windows" => Strings.Get("Shortcuts/ReservedCycleWindows"),
        "Start Menu" => Strings.Get("Shortcuts/ReservedStartMenu"),
        "Task Manager" => Strings.Get("Shortcuts/ReservedTaskManager"),
        "Security Options" => Strings.Get("Shortcuts/ReservedSecurityOptions"),
        "Window Menu" => Strings.Get("Shortcuts/ReservedWindowMenu"),
        "Context Menu" => Strings.Get("Shortcuts/ReservedContextMenu"),
        "Menu Bar" => Strings.Get("Shortcuts/ReservedMenuBar"),
        "Print Screen" => Strings.Get("Shortcuts/ReservedPrintScreen"),
        "Show Completions" => Strings.Get("Shortcuts/ReservedShowCompletions"),
        "Duplicate Line" => Strings.Get("Shortcuts/ReservedDuplicateLine"),
        "Undo" => Strings.Get("Common/Undo"),
        "Redo" => Strings.Get("Common/Redo"),
        "Go to Definition" => Strings.Get("Shortcuts/CommandGoToDefinition"),
        "Rename Symbol" => Strings.Get("Shortcuts/CommandRenameSymbol"),
        "Next Problem" => Strings.Get("Shortcuts/ReservedNextProblem"),
        "Previous Problem" => Strings.Get("Shortcuts/ReservedPreviousProblem"),
        "Quick Info" => Strings.Get("Shortcuts/ReservedQuickInfo"),
        "Copy" => Strings.Get("Common/Copy"),
        "Cut" => Strings.Get("Common/Cut"),
        "Paste" => Strings.Get("Common/Paste"),
        "Select All" => Strings.Get("Common/SelectAll"),
        "Move Word Left" => Strings.Get("Shortcuts/ReservedMoveWordLeft"),
        "Move Word Right" => Strings.Get("Shortcuts/ReservedMoveWordRight"),
        "Select Word Left" => Strings.Get("Shortcuts/ReservedSelectWordLeft"),
        "Select Word Right" => Strings.Get("Shortcuts/ReservedSelectWordRight"),
        "Move to Previous Paragraph" => Strings.Get("Shortcuts/ReservedMoveToPreviousParagraph"),
        "Move to Next Paragraph" => Strings.Get("Shortcuts/ReservedMoveToNextParagraph"),
        "Move to Beginning of Document" => Strings.Get("Shortcuts/ReservedMoveToBeginningOfDocument"),
        "Move to End of Document" => Strings.Get("Shortcuts/ReservedMoveToEndOfDocument"),
        "Select to Beginning of Document" => Strings.Get("Shortcuts/ReservedSelectToBeginningOfDocument"),
        "Select to End of Document" => Strings.Get("Shortcuts/ReservedSelectToEndOfDocument"),
        "Delete Word Backward" => Strings.Get("Shortcuts/ReservedDeleteWordBackward"),
        "Delete Word Forward" => Strings.Get("Shortcuts/ReservedDeleteWordForward"),
        "Refresh" => Strings.Get("Common/Refresh"),
        "Add Row" => Strings.Get("Shortcuts/ReservedAddRow"),
        "Save Changes" => Strings.Get("Shortcuts/ReservedSaveChanges"),
        "Copy with Headers" => Strings.Get("Shortcuts/ReservedCopyWithHeaders"),
        _ when TabNumber(name) is { } tab => Strings.Format("Shortcuts/ReservedSelectTab", tab),
        _ => name,
    };

    /// <summary>The sentence the Keyboard page shows for a conflict, composed from its parts as Core's Describe does.</summary>
    public static string Describe(ShortcutConflict conflict, KeyChord chord) => conflict.Kind switch
    {
        ShortcutConflictKind.NeedsModifier => Strings.Get("Shortcuts/ConflictNeedsModifier"),
        ShortcutConflictKind.SystemReserved => Strings.Format("Shortcuts/ConflictSystemReserved", chord),
        ShortcutConflictKind.Reserved => Strings.Format("Shortcuts/ConflictReserved", chord, Reserved(conflict.Name ?? string.Empty)),
        ShortcutConflictKind.Command when conflict.Command is { } other =>
            Strings.Format("Shortcuts/ConflictCommand", chord, Title(other), Category(other.Category)),
        _ => string.Empty,
    };

    // Core numbers the Ctrl+1 to Ctrl+9 tab keys into one English name each.
    private static int? TabNumber(string name) =>
        name.StartsWith(SelectTabPrefix, StringComparison.Ordinal)
            && int.TryParse(name.AsSpan(SelectTabPrefix.Length), NumberStyles.None, CultureInfo.InvariantCulture, out var number)
            ? number
            : null;
}
