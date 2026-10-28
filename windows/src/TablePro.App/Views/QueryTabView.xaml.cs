using System.Collections.Specialized;
using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Controls.DataGrid;
using TablePro.App.Controls.Editor;
using TablePro.App.Helpers;
using TablePro.App.ViewModels;

namespace TablePro.App.Views;

public sealed partial class QueryTabView : UserControl
{
    private bool _syncingText;

    // Whether the results area shows the plan rather than the selected result's rows or message.
    private bool _planSelected;

    public QueryTabView(QueryTabViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();

        Editor.Dialect = viewModel.Dialect;

        // A command language has no formatter, and an engine without a plan statement has no Explain.
        FormatButton.Visibility = viewModel.Dialect.SupportsFormatting ? Visibility.Visible : Visibility.Collapsed;
        ExplainItem.IsEnabled = viewModel.CanExplain;
        ExplainAnalyzeItem.Visibility = viewModel.CanExplainAnalyze ? Visibility.Visible : Visibility.Collapsed;
        Editor.Text = viewModel.Text;
        Editor.Catalog = viewModel.Context.CompletionCatalog;
        Editor.CompletionEnabled = viewModel.Context.Preferences.AutocompleteEnabled;
        Editor.WordWrap = viewModel.Context.Preferences.WordWrap;
        Editor.FontSize = viewModel.Context.Preferences.EditorFontSize;
        Editor.RunRequested += async (_, scope) => await RunAsync(scope);
        Editor.FormatRequested += (_, _) => Format();
        Editor.SaveRequested += async (_, _) => await SaveFileAsync(saveAs: false);
        Editor.TextChanged += OnEditorTextChanged;
        Editor.SuggestionsEnabled = viewModel.Context.InlineSuggest is not null;
        Editor.PausedAtLineEnd += OnPausedAtLineEnd;
        Editor.VimEnabled = viewModel.Context.Preferences.VimMode;
        Editor.VimStatusChanged += OnVimStatusChanged;
        Editor.VimQuitRequested += (_, _) => CloseRequested?.Invoke(this, EventArgs.Empty);
        Editor.VimTabRequested += (_, position) => TabRequested?.Invoke(this, position);
        Editor.VimAdjacentTabRequested += (_, offset) => AdjacentTabRequested?.Invoke(this, offset);

        viewModel.Context.Session.CatalogChanged += OnCatalogChanged;
        viewModel.Results.CollectionChanged += OnResultsChanged;
        viewModel.PropertyChanged += OnViewModelPropertyChanged;

        ResultGrid.CellContextRequested += OnGridContext;
        ResultGrid.CellActivated += OnCellActivated;
        Loaded += (_, _) => Editor.FocusEditor();
        Unloaded += (_, _) => viewModel.Context.Session.CatalogChanged -= OnCatalogChanged;
        UpdateResultView();
    }

    public event EventHandler<string>? SaveFavoriteRequested;

    /// <summary>Vim's :q, which closes this tab.</summary>
    public event EventHandler? CloseRequested;

    /// <summary>Vim's gt with a count: the 1-based position of the tab to show.</summary>
    public event EventHandler<int>? TabRequested;

    /// <summary>Vim's gt and gT: how many tabs to move, positive to the right.</summary>
    public event EventHandler<int>? AdjacentTabRequested;

    /// <summary>How many tabs the window has, so Vim tab counts clamp and wrap as in Vim.</summary>
    public Func<int>? TabCount
    {
        get => Editor.VimTabCount;
        set => Editor.VimTabCount = value;
    }

    /// <summary>The failed statement and the server's error, for the assistant's Fix action.</summary>
    public event EventHandler<(string Sql, string Error)>? FixWithAiRequested;

    public event EventHandler<(string Title, string Value)>? ValueInspectRequested;

    public QueryTabViewModel ViewModel { get; }

    public void InsertText(string text)
    {
        Editor.InsertText(text);
        Editor.FocusEditor();
    }

    public void ReplaceText(string text) => Editor.ReplaceAllText(text);

    public Task RunAsync(RunScope scope) =>
        ViewModel.RunAsync(Editor.RawText, Editor.SelectionStart, Editor.SelectionLength, scope);

    public string SelectedOrCurrentSql => Editor.SelectionLength > 0 ? Editor.SelectedText : Editor.Text;

    private CancellationTokenSource? _suggestion;

    private async void OnPausedAtLineEnd(object? sender, (string Before, string After, int Caret) pause)
    {
        if (ViewModel.Context.InlineSuggest is not { } suggest)
        {
            return;
        }

        _suggestion?.Cancel();
        _suggestion = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        try
        {
            var text = await suggest(pause.Before, pause.After, _suggestion.Token);
            if (!string.IsNullOrEmpty(text))
            {
                Editor.ShowSuggestion(text, pause.Caret);
            }
        }
        catch (Exception ex) when (ex is OperationCanceledException or HttpRequestException or InvalidOperationException or Ai.AiProviderException or Ai.Assistant.AiAccessDeniedException)
        {
            // A suggestion is optional: a slow, refused or failed request just shows nothing.
        }
    }

    private void OnVimStatusChanged(object? sender, EventArgs e)
    {
        VimStatusText.Text = Editor.VimStatus;
        VimStatusText.Visibility = Editor.VimStatus.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnEditorTextChanged(object? sender, EventArgs e)
    {
        _syncingText = true;
        ViewModel.Text = Editor.Text;
        _syncingText = false;
    }

    private void OnCatalogChanged(object? sender, EventArgs e) =>
        DispatcherQueue.TryEnqueue(() => Editor.Catalog = ViewModel.Context.CompletionCatalog);

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(QueryTabViewModel.Text) when !_syncingText:
                Editor.Text = ViewModel.Text;
                break;
            case nameof(QueryTabViewModel.SelectedResult):
                UpdateResultView();
                break;
            case nameof(QueryTabViewModel.Plan):
                // A new plan opens on its own tab; its raw result rows stay one tab over.
                _planSelected = ViewModel.Plan is not null;
                if (ViewModel.Plan is { } plan)
                {
                    PlanView.Show(plan, ViewModel.PlanBaseline);
                }

                RebuildResultTabs();
                break;
        }
    }

    private void OnResultsChanged(object? sender, NotifyCollectionChangedEventArgs e) => RebuildResultTabs();

    private void RebuildResultTabs()
    {
        ResultTabs.Items.Clear();
        if (ViewModel.Plan is { } plan)
        {
            ResultTabs.Items.Add(new SelectorBarItem { Text = plan.Analyze ? "Analyzed Plan" : "Plan", Tag = plan, Icon = new FontIcon { Glyph = "" } });
        }

        foreach (var result in ViewModel.Results)
        {
            ResultTabs.Items.Add(new SelectorBarItem
            {
                Text = result.Title,
                Tag = result,
                Icon = new FontIcon { Glyph = result.IsError ? "" : result.HasRows ? "" : "" },
            });
        }

        UpdateResultView();
    }

    private void OnResultTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        switch (sender.SelectedItem?.Tag)
        {
            case Core.Plans.QueryPlanCapture when !_planSelected:
                _planSelected = true;
                UpdateResultView();
                break;
            case ResultItemViewModel result:
                var wasPlan = _planSelected;
                _planSelected = false;
                if (!ReferenceEquals(result, ViewModel.SelectedResult))
                {
                    ViewModel.SelectedResult = result;
                }
                else if (wasPlan)
                {
                    UpdateResultView();
                }

                break;
        }
    }

    private void UpdateResultView()
    {
        var showPlan = _planSelected && ViewModel.Plan is not null;
        PlanView.Visibility = showPlan ? Visibility.Visible : Visibility.Collapsed;
        if (showPlan)
        {
            EmptyState.Visibility = ExportButton.Visibility = ChartToggle.Visibility = Visibility.Collapsed;
            ResultGrid.Visibility = Chart.Visibility = MessagePanel.Visibility = Visibility.Collapsed;
            ResultSummary.Text = string.Empty;
            var planTab = ResultTabs.Items.FirstOrDefault(i => i.Tag is Core.Plans.QueryPlanCapture);
            if (planTab is not null && !ReferenceEquals(ResultTabs.SelectedItem, planTab))
            {
                ResultTabs.SelectedItem = planTab;
            }

            return;
        }

        var result = ViewModel.SelectedResult;
        EmptyState.Visibility = ViewModel.Results.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ExportButton.Visibility = result?.HasRows == true ? Visibility.Visible : Visibility.Collapsed;
        ResultSummary.Text = result?.Summary ?? string.Empty;

        var selectedTab = ResultTabs.Items.FirstOrDefault(i => ReferenceEquals(i.Tag, result));
        if (selectedTab is not null && !ReferenceEquals(ResultTabs.SelectedItem, selectedTab))
        {
            ResultTabs.SelectedItem = selectedTab;
        }

        ChartToggle.Visibility = result?.HasRows == true ? Visibility.Visible : Visibility.Collapsed;
        if (result is { HasRows: true })
        {
            ResultGrid.Source = result.Source;
            Chart.Result = ChartToggle.IsChecked == true ? result.Result : null;
            ResultGrid.Visibility = ChartToggle.IsChecked == true ? Visibility.Collapsed : Visibility.Visible;
            Chart.Visibility = ChartToggle.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
            MessagePanel.Visibility = Visibility.Collapsed;
            return;
        }

        ResultGrid.Visibility = Visibility.Collapsed;
        Chart.Visibility = Visibility.Collapsed;
        ResultGrid.Source = null;
        MessagePanel.Visibility = result is null ? Visibility.Collapsed : Visibility.Visible;
        if (result is not null)
        {
            ErrorBar.IsOpen = result.IsError;
            ErrorBar.Message = result.Statement.Error ?? string.Empty;
            var messages = result.Statement.Messages is { Count: > 0 } m ? "\n\n" + string.Join('\n', m) : string.Empty;
            MessageText.Text = (result.IsError ? result.Statement.Sql : result.Summary + "\n\n" + result.Statement.Sql) + messages;
        }
    }

    private async void OnRunClicked(SplitButton sender, SplitButtonClickEventArgs args) => await RunAsync(RunScope.Current);

    private async void OnRunCurrent(object sender, RoutedEventArgs e) => await RunAsync(RunScope.Current);

    private async void OnRunAll(object sender, RoutedEventArgs e) => await RunAsync(RunScope.All);

    private async void OnExplain(object sender, RoutedEventArgs e) => await RunAsync(RunScope.Explain);

    private async void OnExplainAnalyze(object sender, RoutedEventArgs e) =>
        await ViewModel.ExplainAsync(Editor.RawText, Editor.SelectionStart, Editor.SelectionLength, analyze: true);

    private void OnFormat(object sender, RoutedEventArgs e) => Format();

    private void OnChartToggled(object sender, RoutedEventArgs e) => UpdateResultView();

    private void Format()
    {
        if (!ViewModel.Dialect.SupportsFormatting)
        {
            return;
        }

        var source = Editor.SelectionLength > 0 ? Editor.SelectedText : Editor.Text;
        var formatted = TablePro.Core.Sql.SqlFormatter.Format(source, ViewModel.Dialect);
        if (Editor.SelectionLength > 0)
        {
            Editor.InsertText(formatted);
        }
        else
        {
            Editor.ReplaceAllText(formatted);
        }
    }

    private async void OnOpenFile(object sender, RoutedEventArgs e)
    {
        var file = await ViewModel.Context.Dialogs.PickOpenFileAsync(".sql", ".txt");
        if (file is null)
        {
            return;
        }

        var text = await File.ReadAllTextAsync(file.Path);
        Editor.ReplaceAllText(text);
        ViewModel.MarkSaved(file.Path);
    }

    private async void OnSaveFile(object sender, RoutedEventArgs e) => await SaveFileAsync(saveAs: false);

    private async Task SaveFileAsync(bool saveAs)
    {
        var path = ViewModel.FilePath;
        if (saveAs || path is null)
        {
            var file = await ViewModel.Context.Dialogs.PickSaveFileAsync(ViewModel.Title, "SQL file", ".sql");
            if (file is null)
            {
                return;
            }

            path = file.Path;
        }

        await File.WriteAllTextAsync(path, Editor.Text.Replace("\n", Environment.NewLine, StringComparison.Ordinal));
        ViewModel.MarkSaved(path);
        ViewModel.Context.Notify($"Saved {Path.GetFileName(path)}");
    }

    private void OnSaveFavorite(object sender, RoutedEventArgs e) => SaveFavoriteRequested?.Invoke(this, SelectedOrCurrentSql);

    private void OnFixWithAi(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SelectedResult is { IsError: true } failed)
        {
            FixWithAiRequested?.Invoke(this, (failed.Statement.Sql, failed.Statement.Error ?? string.Empty));
        }
    }

    private async void OnExportResult(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SelectedResult?.Result is { } result)
        {
            await GridCommands.ExportAsync(ViewModel.Context.Dialogs, result, ViewModel.Dialect, null, ViewModel.Title);
        }
    }

    private void OnGridContext(object? sender, GridCellEventArgs e)
    {
        var menu = new MenuFlyout();
        GridCommands.AddCopyItems(menu, ResultGrid, ViewModel.Dialect, null);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridCommands.Item("Inspect Value", "", () => Inspect(e.Row, e.Column), "Enter"));
        menu.ShowAt(e.Target, e.Position);
    }

    private void OnCellActivated(object? sender, GridCellEventArgs e) => Inspect(e.Row, e.Column);

    private void Inspect(int row, int column)
    {
        if (ResultGrid.Source is { } source)
        {
            var value = source.GetValue(row, column);
            ValueInspectRequested?.Invoke(this, (source.Columns[column].Name, value is null ? "NULL" : TablePro.Core.Results.CellFormatter.Format(value)));
        }
    }
}
