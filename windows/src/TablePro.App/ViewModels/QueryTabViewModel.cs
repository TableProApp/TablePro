using System.Collections.ObjectModel;
using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TablePro.App.Controls.Editor;
using TablePro.App.Services;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.App.ViewModels;

/// <summary>
/// An editor tab. It owns a dedicated query channel, so a transaction or a SET stays with the tab, and streams each
/// statement's result in as it finishes.
/// </summary>
public sealed partial class QueryTabViewModel : TabViewModel
{
    private readonly WorkspaceContext _context;
    private IQueryChannel? _channel;
    private CancellationTokenSource? _run;
    private string _savedText = string.Empty;

    // The last value typed for each placeholder, so a rerun offers it again.
    private readonly Dictionary<string, string?> _parameterValues = new(StringComparer.Ordinal);

    public QueryTabViewModel(WorkspaceContext context, int number, string? initialText = null, string? filePath = null)
    {
        _context = context;
        Number = number;
        FilePath = filePath;
        Text = initialText ?? string.Empty;
        _savedText = filePath is null ? string.Empty : Text;
        Title = filePath is null ? $"Query {number}" : Path.GetFileName(filePath);
    }

    public int Number { get; }

    public ObservableCollection<ResultItemViewModel> Results { get; } = [];

    public SqlDialect Dialect => _context.Session.Dialect;

    public WorkspaceContext Context => _context;

    [ObservableProperty]
    public partial string Text { get; set; }

    [ObservableProperty]
    public partial string? FilePath { get; set; }

    [ObservableProperty]
    public partial ResultItemViewModel? SelectedResult { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(StopCommand))]
    public partial bool IsRunning { get; set; }

    [ObservableProperty]
    public partial string? ErrorText { get; set; }

    public override string Glyph => "";

    public override string? UnsavedWork => FilePath is not null && !string.Equals(Text, _savedText, StringComparison.Ordinal)
        ? $"{Title} has unsaved changes."
        : null;

    /// <summary>Runs from the editor. Offsets are in the editor's raw text, where line ends are '\r'.</summary>
    public async Task RunAsync(string rawText, int selectionStart, int selectionLength, RunScope scope)
    {
        if (IsRunning)
        {
            return;
        }

        var statements = PickStatements(rawText, selectionStart, selectionLength, scope);
        if (statements.Count == 0)
        {
            return;
        }

        var parameters = SqlParameters.DistinctNames(statements, Dialect);
        if (parameters.Count > 0)
        {
            var values = await _context.Dialogs.PromptValuesAsync(
                "Parameters",
                parameters.Count == 1 ? "The statement has a placeholder. Enter its value." : $"The statements have {parameters.Count} placeholders. Enter their values.",
                parameters,
                _parameterValues);
            if (values is null)
            {
                return;
            }

            foreach (var (name, value) in values)
            {
                _parameterValues[name] = value;
            }

            statements = statements.Select(s => SqlParameters.Substitute(s, Dialect, values)).ToList();
        }

        if (scope == RunScope.Explain)
        {
            statements = Dialect.Explain(statements[0]).ToList();
        }

        if (!await PassesSafeModeAsync(statements))
        {
            return;
        }

        await ExecuteAsync(statements);
    }

    public async Task ExecuteAsync(IReadOnlyList<string> statements)
    {
        Results.Clear();
        ErrorText = null;
        IsRunning = true;
        IsBusy = true;
        StatusText = statements.Count == 1 ? "Running…" : $"Running {statements.Count} statements…";
        _run = new CancellationTokenSource();
        var stopwatch = Stopwatch.StartNew();
        var index = 0;
        var failed = false;
        try
        {
            _channel ??= await _context.Session.Database.OpenChannelAsync(_run.Token);
            var options = new ExecuteOptions(
                RowLimit: _context.Preferences.EditorRowLimit,
                StopOnError: Dialect.BatchSeparator is null);

            await foreach (var result in _channel.ExecuteAsync(statements, options, _run.Token))
            {
                var kind = StatementClassifier.Classify(result.Sql, Dialect);
                _context.History.Record(_context.Session.Profile, _context.Session.Database.CurrentDatabase, result, kind, "editor");
                if (!result.Succeeded)
                {
                    failed = true;
                    ErrorText = result.Error;
                    Results.Add(new ResultItemViewModel(result, null, ++index));
                    continue;
                }

                if (result.ResultSets.Count == 0)
                {
                    // A statement with nothing to show stays out of the tabs unless it is all the run produced.
                    if (statements.Count == 1)
                    {
                        Results.Add(new ResultItemViewModel(result, null, ++index));
                    }

                    if (kind is StatementKind.Ddl)
                    {
                        _context.NotifySchemaChanged();
                    }

                    continue;
                }

                foreach (var set in result.ResultSets)
                {
                    Results.Add(new ResultItemViewModel(result, set, ++index));
                }
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException || _run.IsCancellationRequested)
        {
            failed = true;
            ErrorText = ex is OperationCanceledException ? "Query cancelled." : ex.Message;

            // A failed open leaves no channel; a broken one is dropped so the next run reconnects.
            await DropChannelAsync();
        }
        finally
        {
            IsRunning = false;
            IsBusy = false;
            _run.Dispose();
            _run = null;
        }

        SelectedResult = Results.FirstOrDefault(r => r.HasRows) ?? Results.LastOrDefault();
        var elapsed = ResultItemViewModel.FormatElapsed(stopwatch.Elapsed);
        StatusText = failed ? $"Stopped with an error · {elapsed}" : SelectedResult?.Summary ?? $"Done · {elapsed}";
    }

    [RelayCommand(CanExecute = nameof(IsRunning))]
    private void Stop() => _run?.Cancel();

    public void MarkSaved(string path)
    {
        FilePath = path;
        _savedText = Text;
        Title = Path.GetFileName(path);
        OnPropertyChanged(nameof(UnsavedWork));
    }

    public string Format() => SqlFormatter.Format(Text, Dialect);

    public override async ValueTask DisposeAsync()
    {
        _run?.Cancel();
        await DropChannelAsync();
        await base.DisposeAsync();
    }

    private async Task DropChannelAsync()
    {
        if (_channel is not null)
        {
            var channel = _channel;
            _channel = null;
            try
            {
                await channel.DisposeAsync();
            }
            catch (Exception ex) when (ex is InvalidOperationException or System.Data.Common.DbException)
            {
                // Closing a connection the server already dropped can fail; there is nothing left to release.
            }
        }
    }

    private List<string> PickStatements(string rawText, int selectionStart, int selectionLength, RunScope scope)
    {
        if (selectionLength > 0 && scope != RunScope.All)
        {
            var selected = rawText.Substring(selectionStart, Math.Min(selectionLength, rawText.Length - selectionStart));
            return SqlScript.Split(selected, Dialect).Select(s => Normalize(s.Text)).ToList();
        }

        var statements = SqlScript.Split(rawText, Dialect);
        if (scope == RunScope.All)
        {
            return statements.Select(s => Normalize(s.Text)).ToList();
        }

        return SqlScript.StatementAt(statements, selectionStart) is { } current ? [Normalize(current.Text)] : [];
    }

    private static string Normalize(string text) => text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');

    private async Task<bool> PassesSafeModeAsync(IReadOnlyList<string> statements)
    {
        var level = _context.Session.Profile.SafeMode;
        var writes = statements.Where(s => StatementClassifier.Classify(s, Dialect).IsWrite()).ToList();
        if (level.BlocksAllWrites() && writes.Count > 0)
        {
            await _context.Dialogs.ShowErrorAsync(
                "Read-only connection",
                "This connection's Safe Mode is Read-Only, so statements that change data or structure do not run.");
            return false;
        }

        if (level.RequiresConfirmation() && (writes.Count > 0 || level.ConfirmsReads()))
        {
            var shown = level.ConfirmsReads() ? statements : writes;
            return await _context.Dialogs.ConfirmAsync(
                "Run these statements?",
                $"Safe Mode asks before running statements on {_context.Session.Profile.Name}.",
                "Run",
                destructive: writes.Count > 0,
                detail: string.Join(";\n\n", shown));
        }

        return true;
    }
}
