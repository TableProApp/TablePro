using System.Collections.ObjectModel;
using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TablePro.App.Controls.Editor;
using TablePro.App.Services;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Plans;
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

    /// <summary>The plan the last run produced, drawn instead of its raw rows; null after a run that was not a plan.</summary>
    [ObservableProperty]
    public partial QueryPlanCapture? Plan { get; set; }

    /// <summary>The tab's plan before <see cref="Plan"/>, which Compare measures it against.</summary>
    [ObservableProperty]
    public partial QueryPlanCapture? PlanBaseline { get; set; }

    // The latest plan survives ordinary runs in between, so explaining, running, then explaining again still compares.
    private QueryPlanCapture? _latestPlan;

    public bool CanExplain => Dialect.PlanStatements(PlanProbe, false) is not null || Dialect.Explain(PlanProbe).Count > 0;

    /// <summary>Whether the engine can measure a plan by running the statement, which Safe Mode then treats as running it.</summary>
    public bool CanExplainAnalyze => Dialect.PlanStatements(PlanProbe, true) is not null;

    private const string PlanProbe = "SELECT 1";

    public override string Glyph => "";

    public override string? UnsavedWork => FilePath is not null && !string.Equals(Text, _savedText, StringComparison.Ordinal)
        ? $"{Title} has unsaved changes."
        : null;

    /// <summary>Runs from the editor. Offsets are in the editor's raw text, where line ends are '\r'.</summary>
    public async Task RunAsync(string rawText, int selectionStart, int selectionLength, RunScope scope)
    {
        if (await PrepareAsync(rawText, selectionStart, selectionLength, scope) is not { } statements)
        {
            return;
        }

        if (scope == RunScope.Explain)
        {
            await ExplainStatementAsync(statements[0], analyze: false);
            return;
        }

        if (!await PassesSafeModeAsync(statements))
        {
            return;
        }

        await ExecuteAsync(statements);
    }

    /// <summary>
    /// Explains the selection or the statement at the caret as a plan the view can draw. With <paramref name="analyze"/>
    /// the server runs the statement to measure it, so Safe Mode classifies the statement as it would a plain run.
    /// </summary>
    public async Task ExplainAsync(string rawText, int selectionStart, int selectionLength, bool analyze)
    {
        if (await PrepareAsync(rawText, selectionStart, selectionLength, RunScope.Explain) is { } statements)
        {
            await ExplainStatementAsync(statements[0], analyze);
        }
    }

    /// <summary>The statements to run, with placeholders filled in; null when there is nothing to run or the prompt was cancelled.</summary>
    private async Task<List<string>?> PrepareAsync(string rawText, int selectionStart, int selectionLength, RunScope scope)
    {
        if (IsRunning)
        {
            return null;
        }

        var statements = PickStatements(rawText, selectionStart, selectionLength, scope);
        if (statements.Count == 0)
        {
            return null;
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
                return null;
            }

            foreach (var (name, value) in values)
            {
                _parameterValues[name] = value;
            }

            statements = statements.Select(s => SqlParameters.Substitute(s, Dialect, values)).ToList();
        }

        return statements;
    }

    private async Task ExplainStatementAsync(string subject, bool analyze)
    {
        if (Dialect.PlanStatements(subject, analyze) is not { } request)
        {
            // An engine with no drawable plan still has its text EXPLAIN, shown as rows as before.
            var text = analyze ? [] : Dialect.Explain(subject);
            if (text.Count > 0 && await PassesSafeModeAsync(text))
            {
                await ExecuteAsync(text);
            }

            return;
        }

        if (!await PassesSafeModeAsync(request.Statements))
        {
            return;
        }

        var results = await RunCoreAsync(request.Statements, stopOnError: !request.RunsEveryStatement);
        var sets = results.Where(r => r.Succeeded).SelectMany(r => r.ResultSets).ToList();
        var raw = PlanText.FromResults(request.Format, sets);
        if (!string.IsNullOrWhiteSpace(raw))
        {
            CapturePlan(QueryPlanCapture.Create(subject, raw, request.Format, analyze, DateTimeOffset.Now));
            return;
        }

        // A server that refuses the machine-readable form (an older version, or a compatible engine sharing the dialect
        // without FORMAT JSON) still answers the text EXPLAIN. It explains the same statement Safe Mode just passed.
        if (!analyze && results.Any(r => !r.Succeeded) && Dialect.Explain(subject) is { Count: > 0 } fallback)
        {
            await ExecuteAsync(fallback);
        }
    }

    private void CapturePlan(QueryPlanCapture capture)
    {
        PlanBaseline = _latestPlan;
        _latestPlan = capture;
        Plan = capture;
    }

    public async Task ExecuteAsync(IReadOnlyList<string> statements)
    {
        var results = await RunCoreAsync(statements);

        // A hand-typed plan statement in the dialect's own spelling is drawn like the Explain action's.
        if (statements.Count == 1 && results is [{ Succeeded: true, ResultSets.Count: > 0 } only]
            && PlanStatements.Recognize(Dialect, statements[0]) is { } typed)
        {
            var capture = QueryPlanCapture.Create(statements[0], PlanText.FromResults(typed.Format, only.ResultSets), typed.Format, typed.Analyze, DateTimeOffset.Now);
            if (capture.Plan is not null)
            {
                CapturePlan(capture);
            }
        }
    }

    /// <summary>Runs statements on the tab's channel, streaming each result into <see cref="Results"/>, and returns them all.</summary>
    private async Task<List<StatementResult>> RunCoreAsync(IReadOnlyList<string> statements, bool? stopOnError = null)
    {
        var collected = new List<StatementResult>(statements.Count);
        Results.Clear();
        Plan = null;
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
                StopOnError: stopOnError ?? Dialect.BatchSeparator is null);

            await foreach (var result in _channel.ExecuteAsync(statements, options, _run.Token))
            {
                collected.Add(result);
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
        return collected;
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
