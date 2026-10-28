using TablePro.Core.Connections;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.App.Services;

/// <summary>Where finished statements go: the editor's runs, saves and MCP calls all land in one history.</summary>
public interface IHistoryRecorder
{
    void Record(ConnectionProfile profile, string? database, StatementResult result, StatementKind kind, string source);
}

/// <summary>The preferences a workspace reads while it runs; the settings store supplies the live values.</summary>
public interface IWorkspacePreferences
{
    int EditorRowLimit { get; }

    int BrowsePageSize { get; }

    string NullText { get; }

    bool AutocompleteEnabled { get; }

    double EditorFontSize { get; }

    bool WordWrap { get; }
}

/// <summary>Everything a tab needs from its window, handed down instead of reached for through statics.</summary>
public sealed class WorkspaceContext(ConnectionSession session, DialogService dialogs, IHistoryRecorder history, IWorkspacePreferences preferences)
{
    public ConnectionSession Session { get; } = session;

    public DialogService Dialogs { get; } = dialogs;

    public IHistoryRecorder History { get; } = history;

    public IWorkspacePreferences Preferences { get; } = preferences;

    /// <summary>Raised by a tab that changed the schema, so the sidebar reloads.</summary>
    public event EventHandler? SchemaChanged;

    public event EventHandler<string>? Notified;

    public void NotifySchemaChanged() => SchemaChanged?.Invoke(this, EventArgs.Empty);

    public void Notify(string message) => Notified?.Invoke(this, message);
}
