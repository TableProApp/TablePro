using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// A query tab: the SQL editor, its run commands and the results. The tab's editor connection is opened on the first
// run and keeps its transaction from one run to the next.
public sealed partial class QueryTabView : UserControl, ITabContent
{
    private readonly Workbench _workbench;
    private readonly DatabaseSession _session;
    private QueryEditor? _editor;
    private QueryRun? _run;

    internal QueryTabView(Workbench workbench, DatabaseSession session, string title, string? sql)
    {
        _workbench = workbench;
        _session = session;
        Title = title;
        InitializeComponent();
        SqlText.Text = sql ?? string.Empty;
        SqlText.Lexer = new CoreSqlLexer(Grammars.For(session.EngineId));
        SqlText.EditorFontSize = (float)workbench.Settings.EditorFontSize;
        AutomationProperties.SetName(SqlText, Strings.Format("EditorName", title));
        Results.StatusChanged += (_, status) => StatusText.Text = status;
    }

    public event EventHandler? StateChanged;

    public string Title { get; }

    public bool IsRunning { get; private set; }

    public SqlEditor? Editor => SqlText;

    public ResultsPane ResultsArea => Results;

    public async void Run() => await RunAsync().ConfigureAwait(true);

    public void Stop() => _run?.Cancel();

    public void FocusContent() => SqlText.Focus(FocusState.Programmatic);

    public SessionTab Snapshot() => new() { Kind = TabKind.Query, Title = Title, Sql = SqlText.Text };

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

        SqlText.Dispose();
    }

    // The selection when there is one, else the whole text.
    private async Task RunAsync()
    {
        if (IsRunning)
        {
            return;
        }

        var sql = SqlText.Model.GetSelectedText();
        if (string.IsNullOrWhiteSpace(sql))
        {
            sql = SqlText.Text;
        }

        if (string.IsNullOrWhiteSpace(sql))
        {
            return;
        }

        SetRunning(true);
        try
        {
            _editor ??= await _session.OpenEditorAsync().ConfigureAwait(true);
            _run?.Dispose();
            var settings = _workbench.Settings;
            _run = _editor.Run(
                sql,
                new QueryOptions(
                    settings.RowLimit,
                    settings.QueryTimeoutSeconds > 0 ? TimeSpan.FromSeconds(settings.QueryTimeoutSeconds) : null));
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
        RunButton.IsEnabled = !running;
        StopButton.IsEnabled = running;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnRun(object sender, RoutedEventArgs e) => Run();

    private void OnStop(object sender, RoutedEventArgs e) => Stop();
}
