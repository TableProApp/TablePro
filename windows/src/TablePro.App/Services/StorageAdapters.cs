using System.Diagnostics;
using TablePro.Core.Connections;
using TablePro.Core.Results;
using TablePro.Core.Sql;
using TablePro.Storage.History;
using TablePro.Storage.Settings;

namespace TablePro.App.Services;

/// <summary>Writes finished statements to the history database without making the editor wait for the disk.</summary>
public sealed class HistoryRecorder(QueryHistoryStore store) : IHistoryRecorder
{
    public void Record(ConnectionProfile profile, string? database, StatementResult result, StatementKind kind, string source)
    {
        var rows = result.ResultSets.Count > 0 ? result.ResultSets.Sum(s => (long)s.RowCount) : result.RecordsAffected;
        var entry = QueryHistoryEntry.Create(
            result.Sql,
            profile.Id,
            profile.Engine,
            result.Elapsed,
            rows,
            result.Error,
            database,
            source: source switch
            {
                "grid" => QueryHistorySource.RowEdit,
                "structure" or "sidebar" => QueryHistorySource.StructureDdl,
                "mcp" => QueryHistorySource.Mcp,
                "import" => QueryHistorySource.Import,
                _ => kind == StatementKind.Read && result.Sql.StartsWith("EXPLAIN", StringComparison.OrdinalIgnoreCase) ? QueryHistorySource.Explain : QueryHistorySource.Editor,
            });
        _ = Task.Run(async () =>
        {
            try
            {
                await store.RecordAsync(entry);
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException or Microsoft.Data.Sqlite.SqliteException)
            {
                // History is a convenience; a locked or full disk must never fail the statement the user ran.
                Debug.WriteLine($"History write failed: {ex.Message}");
            }
        });
    }
}

/// <summary>The live preference values from the settings store, read at the moment a tab needs them.</summary>
public sealed class SettingsPreferences(SettingsStore settings) : IWorkspacePreferences
{
    public int EditorRowLimit => settings.Current.Data.EditorRowLimit;

    public int BrowsePageSize => settings.Current.Data.TablePageSize;

    public string NullText => settings.Current.Data.NullDisplayText;

    public bool AutocompleteEnabled => settings.Current.Editor.Autocomplete;

    public double EditorFontSize => settings.Current.Editor.FontSize;

    public bool WordWrap => settings.Current.Editor.WordWrap;

    public bool VimMode => settings.Current.Editor.VimMode;

    public bool EmacsKeys => settings.Current.Editor.EmacsKeys;

    public string LastSqlImportEncoding => settings.Current.LastSqlImportEncoding;

    public Task RememberSqlImportEncodingAsync(string encodingId) =>
        settings.UpdateAsync(s => s with { LastSqlImportEncoding = encodingId });
}
