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

    // The last result checked for a map source and the answer, reused while that result stays selected.
    private Core.Results.ResultSet? _mapCheckedResult;
    private bool _mapAvailable;

    public QueryTabView(QueryTabViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();

        // A license activated or removed with the chart open draws or clears it without another toggle.
        ChartGate.AccessChanged += (_, _) => UpdateResultView();
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
        Editor.DefinitionRequested += (_, target) => DefinitionRequested?.Invoke(this, target);
        Editor.EmacsEnabled = viewModel.Context.Preferences.EmacsKeys;
        Editor.VimStatusChanged += OnVimStatusChanged;
        Editor.VimQuitRequested += (_, _) => CloseRequested?.Invoke(this, EventArgs.Empty);
        Editor.VimTabRequested += (_, position) => TabRequested?.Invoke(this, position);
        Editor.VimAdjacentTabRequested += (_, offset) => AdjacentTabRequested?.Invoke(this, offset);

        viewModel.Results.CollectionChanged += OnResultsChanged;
        viewModel.PropertyChanged += OnViewModelPropertyChanged;

        ResultGrid.CellContextRequested += OnGridContext;
        ResultGrid.CellActivated += OnCellActivated;

        // A shape clicked on the map selects its row in the grid, so switching back shows the row it came from.
        Map.RowSelected += (_, row) => ResultGrid.SelectCell(row, 0);
        // The tab view unloads whenever another tab is shown and loads again when it comes back. Subscribing once in
        // the constructor and leaving on the first Unloaded left the editor on the catalog it had then, so columns
        // loaded later, the ones completion after an alias needs, never reached it.
        Loaded += (_, _) =>
        {
            viewModel.Context.Session.CatalogChanged -= OnCatalogChanged;
            viewModel.Context.Session.CatalogChanged += OnCatalogChanged;
            Editor.Catalog = viewModel.Context.CompletionCatalog;
            Editor.FocusEditor();
            WarmColumns();
        };
        Unloaded += (_, _) => viewModel.Context.Session.CatalogChanged -= OnCatalogChanged;
        UpdateResultView();
    }

    public event EventHandler<string>? SaveFavoriteRequested;

    /// <summary>Go to definition on a table or column; the window opens that table's structure.</summary>
    public event EventHandler<Core.Sql.Analysis.SqlCatalogDefinition>? DefinitionRequested;

    /// <summary>The window's shortcut map lookup, so remapped editor commands follow Settings.</summary>
    public Func<Windows.System.VirtualKey, Windows.System.VirtualKeyModifiers, string?>? CommandForKey
    {
        get => Editor.CommandForKey;
        set => Editor.CommandForKey = value;
    }

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
        _warmColumns ??= new Helpers.DispatcherQueueTimerHolder(this, TimeSpan.FromMilliseconds(300), WarmColumns);
        _warmColumns.Restart();
    }

    // Completion after an alias needs the aliased table's columns, which the session only had for tables opened in a
    // tab; loading them for the tables the text names makes "o." offer the columns of orders.
    private Helpers.DispatcherQueueTimerHolder? _warmColumns;
    private CancellationTokenSource? _warming;

    private async void WarmColumns()
    {
        var tables = Core.Sql.SqlCompletion.ReferencedTables(Editor.Text, ViewModel.Dialect);
        if (tables.Count == 0)
        {
            return;
        }

        _warming?.Cancel();
        _warming = new CancellationTokenSource();
        try
        {
            await ViewModel.Context.Session.WarmColumnsAsync(tables, _warming.Token);

            // Back on the UI thread: hand the editor the columns now, rather than wait for the catalog event's turn.
            Editor.Catalog = ViewModel.Context.CompletionCatalog;
        }
        catch (OperationCanceledException)
        {
            // Newer text started its own load.
        }
    }

    private void OnCatalogChanged(object? sender, EventArgs e) =>
        DispatcherQueue.TryEnqueueLogged(() => Editor.Catalog = ViewModel.Context.CompletionCatalog);

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
            ResultTabs.Items.Add(new SelectorBarItem { Text = plan.Analyze ? Strings.Get("Query/AnalyzedPlanTab") : Strings.Get("Query/PlanTab"), Tag = plan, Icon = new FontIcon { Glyph = "" } });
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
            EmptyState.Visibility = ExportButton.Visibility = ChartToggle.Visibility = MapToggle.Visibility = Visibility.Collapsed;
            ResultGrid.Visibility = ChartGate.Visibility = Map.Visibility = MessagePanel.Visibility = Visibility.Collapsed;
            Map.Result = null;
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
        var canMap = result?.Result is { } rows && HasMapSource(rows);
        MapToggle.Visibility = canMap ? Visibility.Visible : Visibility.Collapsed;
        if (result is { HasRows: true })
        {
            var showChart = ChartToggle.IsChecked == true;
            var showMap = !showChart && canMap && MapToggle.IsChecked == true;
            if (showMap && Map.Visibility != Visibility.Visible)
            {
                Map.SelectedRows = ResultGrid.SelectedRows;
            }

            ResultGrid.Source = result.Source;
            Chart.Result = Core.Licensing.ProFeatureGates.DrawsChart(showChart, ChartGate.Access) ? result.Result : null;
            Map.Result = showMap ? result.Result : null;
            ResultGrid.Visibility = showChart || showMap ? Visibility.Collapsed : Visibility.Visible;
            ChartGate.Visibility = showChart ? Visibility.Visible : Visibility.Collapsed;
            Map.Visibility = showMap ? Visibility.Visible : Visibility.Collapsed;
            MessagePanel.Visibility = Visibility.Collapsed;
            return;
        }

        ResultGrid.Visibility = Visibility.Collapsed;
        ChartGate.Visibility = Visibility.Collapsed;
        Map.Visibility = Visibility.Collapsed;
        Map.Result = null;
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

    // Chart and map replace the grid in the same place, so turning one on turns the other off.
    private void OnChartToggled(object sender, RoutedEventArgs e)
    {
        if (ChartToggle.IsChecked == true)
        {
            MapToggle.IsChecked = false;
        }

        UpdateResultView();
    }

    private void OnMapToggled(object sender, RoutedEventArgs e)
    {
        if (MapToggle.IsChecked == true)
        {
            ChartToggle.IsChecked = false;
        }

        UpdateResultView();
    }

    /// <summary>Whether the result has something to map, sampled once per result since the view refreshes often.</summary>
    private bool HasMapSource(Core.Results.ResultSet rows)
    {
        if (!ReferenceEquals(rows, _mapCheckedResult))
        {
            _mapCheckedResult = rows;
            _mapAvailable = Core.Geometry.MapSourceDetector.HasSource(rows);
        }

        return _mapAvailable;
    }

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
            var file = await ViewModel.Context.Dialogs.PickSaveFileAsync(ViewModel.Title, Strings.Get("Query/SqlFileType"), ".sql");
            if (file is null)
            {
                return;
            }

            path = file.Path;
        }

        await File.WriteAllTextAsync(path, Editor.Text.Replace("\n", Environment.NewLine, StringComparison.Ordinal));
        ViewModel.MarkSaved(path);
        await SqlFiles.SqlLibraryHost.RecordSaveAsync(path);
        ViewModel.Context.Notify(Strings.Format("Query/SavedFile", Path.GetFileName(path)));
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
        menu.Items.Add(GridCommands.Item(Strings.Get("Query/InspectValue"),"", () => Inspect(e.Row, e.Column), "Enter"));
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
