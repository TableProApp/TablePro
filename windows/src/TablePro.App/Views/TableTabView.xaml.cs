using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// A table tab: the table's first rows, read with the statement the core writes for the engine.
public sealed partial class TableTabView : UserControl, ITabContent
{
    private readonly Workbench _workbench;
    private readonly DatabaseSession _session;
    private readonly string? _schema;
    private readonly string _table;
    private QueryEditor? _editor;
    private QueryRun? _run;

    internal TableTabView(Workbench workbench, DatabaseSession session, string? schema, string table)
    {
        _workbench = workbench;
        _session = session;
        _schema = schema;
        _table = table;
        InitializeComponent();
        Results.StatusChanged += (_, status) => StatusText.Text = status;
    }

    public event EventHandler? StateChanged;

    public string Title => _table;

    public bool IsRunning { get; private set; }

    public SqlEditor? Editor => null;

    public ResultsPane ResultsArea => Results;

    public bool Shows(string? schema, string table) =>
        string.Equals(_table, table, StringComparison.Ordinal) && string.Equals(_schema, schema, StringComparison.Ordinal);

    public async void Run() => await LoadAsync().ConfigureAwait(true);

    public void Stop() => _run?.Cancel();

    public void FocusContent() => RefreshButton.Focus(FocusState.Programmatic);

    public SessionTab Snapshot() => new() { Kind = TabKind.Table, Title = Title, Schema = _schema, Table = _table };

    public async Task CloseAsync()
    {
        _run?.Dispose();
        _run = null;
        Results.Clear();
        if (_editor is not null)
        {
            await _editor.DisposeAsync().ConfigureAwait(true);
            _editor = null;
        }
    }

    private async Task LoadAsync()
    {
        if (IsRunning)
        {
            return;
        }

        SetRunning(true);
        try
        {
            _editor ??= await _session.OpenEditorAsync().ConfigureAwait(true);
            var limit = _workbench.Settings.RowLimit;
            var sql = _session.BrowseSql(new TableName(_schema, _table), limit);
            _run?.Dispose();
            _run = _editor.Run(sql, new QueryOptions(limit));
            await Results.ShowRunAsync(_run).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            Results.ShowError(Strings.Error(exception.Error));
        }
        finally
        {
            SetRunning(false);
        }
    }

    private void SetRunning(bool running)
    {
        IsRunning = running;
        RefreshButton.IsEnabled = !running;
        StopButton.IsEnabled = running;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnRefresh(object sender, RoutedEventArgs e) => Run();

    private void OnStop(object sender, RoutedEventArgs e) => Stop();
}
