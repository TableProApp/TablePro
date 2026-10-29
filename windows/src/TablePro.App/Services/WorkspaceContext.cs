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

    bool VimMode { get; }

    bool EmacsKeys { get; }

    /// <summary>The encoding id the last successful SQL import read its file with, which the next one opens on.</summary>
    string LastSqlImportEncoding { get; }

    Task RememberSqlImportEncodingAsync(string encodingId);

    /// <summary>Whether the import sheet's "Wrap in transaction" box opens ticked: the user's last choice.</summary>
    bool ImportWrapsInTransaction { get; }

    Task RememberImportWrapsInTransactionAsync(bool wraps);
}

/// <summary>Everything a tab needs from its window, handed down instead of reached for through statics.</summary>
public sealed class WorkspaceContext(ConnectionSession session, DialogService dialogs, IHistoryRecorder history, IWorkspacePreferences preferences)
{
    public ConnectionSession Session { get; } = session;

    public DialogService Dialogs { get; } = dialogs;

    public IHistoryRecorder History { get; } = history;

    public IWorkspacePreferences Preferences { get; } = preferences;

    /// <summary>Favorites with a keyword, offered in completion so typing the keyword inserts the saved query.</summary>
    public Func<IReadOnlyList<CompletionItem>> Snippets { get; init; } = static () => [];

    /// <summary>The catalog completion reads: the session's schema plus the favorites' keywords.</summary>
    public CompletionCatalog CompletionCatalog
    {
        get
        {
            var catalog = Session.Catalog;
            var snippets = Snippets();
            return snippets.Count == 0 ? catalog : new CompletionCatalog(catalog.Schemas, catalog.Tables, catalog.Columns) { Snippets = [(Strings.Get("Workspace/Favorites"), snippets)] };
        }
    }

    /// <summary>
    /// Asks the AI provider for text to continue the editor at the caret, given the text before and after it; null
    /// when Suggest While Typing is off or no provider is set up.
    /// </summary>
    public Func<string, string, CancellationToken, Task<string?>>? InlineSuggest { get; init; }

    /// <summary>Raised by a tab that changed the schema, so the sidebar reloads.</summary>
    public event EventHandler? SchemaChanged;

    public event EventHandler<string>? Notified;

    public void NotifySchemaChanged() => SchemaChanged?.Invoke(this, EventArgs.Empty);

    public void Notify(string message) => Notified?.Invoke(this, message);
}
