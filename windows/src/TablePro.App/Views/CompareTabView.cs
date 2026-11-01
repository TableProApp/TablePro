using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TablePro.App.Controls.DataGrid;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Compare;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.App.Views;

/// <summary>
/// The Compare and Sync tab: a source on any saved connection against a target on any other, compared one table pair
/// at a time, across a chosen set of tables or the whole schema, or structure against structure. Differences show in
/// the data grid in its edit colors, and every sync or migration goes through the review sheet before it runs.
/// </summary>
public sealed partial class CompareTabView : UserControl
{
    private static readonly DataCompareScope[] Scopes = [DataCompareScope.OneTable, DataCompareScope.ChosenTables, DataCompareScope.WholeSchema];

    private readonly SelectorBar _modes = new();
    private readonly ComboBox _sourceConnection = new() { MinWidth = 180, PlaceholderText = Strings.Get("Compare/SourceConnection") };
    private readonly ComboBox _sourceSchema = new() { MinWidth = 140, PlaceholderText = Strings.Get("Compare/Schema") };
    private readonly ComboBox _sourceTable = new() { MinWidth = 200, PlaceholderText = Strings.Get("Compare/SourceTable") };
    private readonly ComboBox _targetConnection = new() { MinWidth = 180, PlaceholderText = Strings.Get("Compare/TargetConnection") };
    private readonly ComboBox _targetSchema = new() { MinWidth = 140, PlaceholderText = Strings.Get("Compare/Schema") };
    private readonly ComboBox _targetTable = new() { MinWidth = 200, PlaceholderText = Strings.Get("Compare/TargetTable") };
    private readonly ComboBox _scope = new() { MinWidth = 160 };
    private readonly Button _compare = new() { Content = Strings.Get("Compare/CompareButton"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
    private readonly Button _stop = new() { Content = Strings.Get("Common/Stop"), Visibility = Visibility.Collapsed };
    private readonly ProgressRing _busy = new() { Width = 18, Height = 18, IsActive = false };
    private readonly TextBlock _summary = new() { TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
    private readonly InfoBar _notes = new() { IsClosable = false, Severity = InfoBarSeverity.Informational };
    private readonly StackPanel _dataOptions = new() { Spacing = 8 };
    private readonly StackPanel _tableOptions = new() { Orientation = Orientation.Horizontal, Spacing = 12 };
    private readonly StackPanel _structureOptions = new() { Spacing = 8, Visibility = Visibility.Collapsed };
    private readonly ToggleButton _showInserts = new() { Content = Strings.Get("Compare/ShowOnlyInSource"), IsChecked = true };
    private readonly ToggleButton _showUpdates = new() { Content = Strings.Get("Compare/ShowChanged"), IsChecked = true };
    private readonly ToggleButton _showDeletes = new() { Content = Strings.Get("Compare/ShowOnlyInTarget"), IsChecked = true };
    private readonly DataGridView _grid = new();
    private readonly Grid _rowsPanel = new() { RowSpacing = 8 };
    private readonly Grid _structurePanel = new() { ColumnSpacing = 12, Visibility = Visibility.Collapsed };
    private readonly ListView _tables = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly StackPanel _tableDetail = new() { Spacing = 8 };
    private readonly StackPanel _dataActions = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly StackPanel _structureActions = new() { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
    private readonly Button _skip = new() { Content = Strings.Get("Compare/SkipOrIncludeRows") };
    private readonly List<Action> _optionRefreshers = [];
    private CompareGridSource? _source;
    private bool _updating;

    public CompareTabView(CompareTabViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(viewModel);
        ViewModel = viewModel;

        _modes.Items.Add(new SelectorBarItem { Text = Strings.Get("Compare/ModeData"), IsSelected = viewModel.Mode == CompareMode.Data });
        _modes.Items.Add(new SelectorBarItem { Text = Strings.Get("Compare/ModeStructure"), IsSelected = viewModel.Mode == CompareMode.Structure });
        _modes.SelectionChanged += (_, _) =>
        {
            if (!_updating)
            {
                ViewModel.Mode = _modes.SelectedItem == _modes.Items[1] ? CompareMode.Structure : CompareMode.Data;
            }
        };

        _scope.Items.Add(Strings.Get("Compare/ScopeOneTable"));
        _scope.Items.Add(Strings.Get("Compare/ScopeChosenTables"));
        _scope.Items.Add(Strings.Get("Compare/ScopeWholeSchema"));
        _scope.SelectionChanged += (_, _) =>
        {
            if (!_updating && _scope.SelectedIndex >= 0)
            {
                ViewModel.Scope = Scopes[_scope.SelectedIndex];
            }
        };

        foreach (var profile in viewModel.Profiles)
        {
            _sourceConnection.Items.Add(profile.Name);
            _targetConnection.Items.Add(profile.Name);
        }

        WireEndpoints();
        _compare.Click += async (_, _) => await ViewModel.CompareAsync();
        _stop.Click += (_, _) => ViewModel.Cancel();
        foreach (var toggle in new[] { _showInserts, _showUpdates, _showDeletes })
        {
            toggle.Click += (_, _) => RebuildGrid();
        }

        _grid.CellActivated += (_, _) => ToggleSelected();
        _tables.SelectionChanged += (_, _) => ShowTableDetail();

        BuildOptions();
        BuildActions();
        Content = BuildLayout();

        viewModel.PropertyChanged += OnViewModelChanged;
        Loaded += async (_, _) =>
        {
            // Rows unhook from their plans while the tab is hidden, so a hidden tab's run costs no redraws.
            if (_planRows.Count == 0 && ViewModel.TablePlans.Count > 0)
            {
                RebuildPlanList();
            }

            if (ViewModel.Target is null)
            {
                await ViewModel.ConnectTargetAsync();
            }
        };
        Unloaded += (_, _) => DetachPlanRows();
        Refresh();
        UpdateVisibility();
    }

    public CompareTabViewModel ViewModel { get; }

    private static int IndexOf(IReadOnlyList<Core.Schema.DatabaseObject> tables, Core.Schema.DatabaseObject table)
    {
        for (var i = 0; i < tables.Count; i++)
        {
            if (tables[i].Name == table.Name)
            {
                return i;
            }
        }

        return -1;
    }

    private static void Copy(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    /// <summary>Refills a combo box only when its items changed, so a refresh during a run does not reset a dropdown.</summary>
    private static void Fill(ComboBox box, IReadOnlyList<string> items)
    {
        var same = box.Items.Count == items.Count;
        for (var i = 0; same && i < items.Count; i++)
        {
            same = Equals(box.Items[i], items[i]);
        }

        if (!same)
        {
            box.Items.Clear();
            foreach (var item in items)
            {
                box.Items.Add(item);
            }
        }
    }

    private void WireEndpoints()
    {
        _sourceConnection.SelectionChanged += async (_, _) =>
        {
            if (!_updating && _sourceConnection.SelectedIndex >= 0)
            {
                await ViewModel.ConnectSourceAsync(ViewModel.Profiles[_sourceConnection.SelectedIndex]);
            }
        };
        _sourceSchema.SelectionChanged += async (_, _) =>
        {
            if (!_updating && _sourceSchema.SelectedIndex >= 0)
            {
                await ViewModel.SetSchemaAsync(target: false, ViewModel.SourceSchemas[_sourceSchema.SelectedIndex]);
            }
        };
        _sourceTable.SelectionChanged += (_, _) =>
        {
            if (!_updating && _sourceTable.SelectedIndex >= 0)
            {
                ViewModel.SelectedSourceTable = ViewModel.SourceTables[_sourceTable.SelectedIndex];
                ViewModel.MatchTargetTable();
            }
        };
        _targetConnection.SelectionChanged += async (_, _) =>
        {
            if (!_updating && _targetConnection.SelectedIndex >= 0)
            {
                ViewModel.TargetProfile = ViewModel.Profiles[_targetConnection.SelectedIndex];
                await ViewModel.ConnectTargetAsync();
            }
        };
        _targetSchema.SelectionChanged += async (_, _) =>
        {
            if (!_updating && _targetSchema.SelectedIndex >= 0)
            {
                await ViewModel.SetSchemaAsync(target: true, ViewModel.TargetSchemas[_targetSchema.SelectedIndex]);
            }
        };
        _targetTable.SelectionChanged += (_, _) =>
        {
            if (!_updating && _targetTable.SelectedIndex >= 0)
            {
                ViewModel.SelectedTargetTable = ViewModel.TargetTables[_targetTable.SelectedIndex];
            }
        };
        AutomationProperties.SetName(_sourceConnection, Strings.Get("Compare/SourceConnection"));
        AutomationProperties.SetName(_sourceSchema, Strings.Get("Compare/SourceSchema"));
        AutomationProperties.SetName(_sourceTable, Strings.Get("Compare/SourceTable"));
        AutomationProperties.SetName(_targetConnection, Strings.Get("Compare/TargetConnection"));
        AutomationProperties.SetName(_targetSchema, Strings.Get("Compare/TargetSchema"));
        AutomationProperties.SetName(_targetTable, Strings.Get("Compare/TargetTable"));
        AutomationProperties.SetName(_scope, Strings.Get("Compare/Scope"));
    }

    private TextBox Field(string header, string placeholder, Func<string> get, Action<string> set)
    {
        var box = new TextBox { Header = header, PlaceholderText = placeholder, Text = get(), MinWidth = 220 };
        box.TextChanged += (_, _) =>
        {
            if (!_updating)
            {
                set(box.Text);
            }
        };
        _optionRefreshers.Add(() =>
        {
            if (!string.Equals(box.Text, get(), StringComparison.Ordinal))
            {
                box.Text = get();
            }
        });
        return box;
    }

    private CheckBox Check(string text, Func<bool> get, Action<bool> set)
    {
        var box = new CheckBox { Content = text, IsChecked = get() };
        box.Click += (_, _) => set(box.IsChecked == true);
        _optionRefreshers.Add(() => box.IsChecked = get());
        return box;
    }

    private NumberBox Number(NumberBox box, Func<double> get, Action<double> set)
    {
        box.Value = get();
        box.ValueChanged += (_, e) =>
        {
            if (!_updating)
            {
                set(e.NewValue);
            }
        };
        _optionRefreshers.Add(() =>
        {
            var value = get();
            if (!(double.IsNaN(value) && double.IsNaN(box.Value)) && box.Value != value)
            {
                box.Value = value;
            }
        });
        return box;
    }

    private void BuildOptions()
    {
        var vm = ViewModel;
        _tableOptions.Children.Add(Field(Strings.Get("Compare/KeyColumns"), Strings.Get("Compare/KeyColumnsPlaceholder"), () => vm.KeyColumns, v => vm.KeyColumns = v));
        _tableOptions.Children.Add(Field(Strings.Get("Compare/LeaveOutColumns"), "updated_at, version", () => vm.ExcludedColumns, v => vm.ExcludedColumns = v));
        _tableOptions.Children.Add(Field(Strings.Get("Compare/SourceWhere"), "status = 'active'", () => vm.SourceWhere, v => vm.SourceWhere = v));
        _tableOptions.Children.Add(Field(Strings.Get("Compare/TargetWhere"), "status = 'active'", () => vm.TargetWhere, v => vm.TargetWhere = v));
        _dataOptions.Children.Add(_tableOptions);

        var limits = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        limits.Children.Add(Number(
            new NumberBox { Header = Strings.Get("Compare/FloatTolerance"), Minimum = 0, SmallChange = 0.001, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact },
            () => vm.FloatTolerance,
            v => vm.FloatTolerance = double.IsNaN(v) ? 0 : v));
        limits.Children.Add(Number(
            new NumberBox { Header = Strings.Get("Compare/RowLimit"), PlaceholderText = Strings.Get("Compare/RowLimitPlaceholder"), Minimum = 1 },
            () => vm.RowLimit,
            v => vm.RowLimit = v));
        _dataOptions.Children.Add(limits);

        var writes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        writes.Children.Add(Check(Strings.Get("Compare/InsertMissingRows"), () => vm.InsertMissing, v => vm.InsertMissing = v));
        writes.Children.Add(Check(Strings.Get("Compare/UpdateChangedRows"), () => vm.UpdateChanged, v => vm.UpdateChanged = v));
        writes.Children.Add(Check(Strings.Get("Compare/DeleteExtraRows"), () => vm.DeleteExtra, v => vm.DeleteExtra = v));
        writes.Children.Add(Check(Strings.Get("Compare/KeysIgnoreCase"), () => vm.KeysIgnoreCase, v => vm.KeysIgnoreCase = v));
        writes.Children.Add(Check(Strings.Get("Compare/CommitInBatches"), () => vm.ApplyInBatches, v => vm.ApplyInBatches = v));
        _dataOptions.Children.Add(writes);

        var drops = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        drops.Children.Add(Check(Strings.Get("Compare/DropExtraTables"), () => vm.DropExtraTables, v => vm.DropExtraTables = v));
        drops.Children.Add(Check(Strings.Get("Compare/DropExtraColumns"), () => vm.DropExtraColumns, v => vm.DropExtraColumns = v));
        _structureOptions.Children.Add(drops);
    }

    private void BuildActions()
    {
        _skip.Click += (_, _) => ToggleSelected();
        var copy = new Button { Content = Strings.Get("Compare/CopySyncScript") };
        copy.Click += (_, _) => Copy(ViewModel.SyncScript());
        var sync = new Button { Content = Strings.Get("Compare/ReviewAndSync"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        sync.Click += async (_, _) => await ViewModel.SyncAsync();
        _dataActions.Children.Add(_skip);
        _dataActions.Children.Add(copy);
        _dataActions.Children.Add(sync);

        var copyDdl = new Button { Content = Strings.Get("Compare/CopyMigrationScript") };
        copyDdl.Click += (_, _) => Copy(ViewModel.MigrationText());
        var migrate = new Button { Content = Strings.Get("Compare/ReviewAndMigrate"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        migrate.Click += async (_, _) => await ViewModel.MigrateAsync();
        _structureActions.Children.Add(copyDdl);
        _structureActions.Children.Add(migrate);
    }

    private Grid BuildLayout()
    {
        var header = new Grid { ColumnSpacing = 12 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(_modes);
        var saved = BuildSavedComparisons();
        Grid.SetColumn(saved, 1);
        header.Children.Add(saved);

        var endpoints = new Grid { ColumnSpacing = 8, RowSpacing = 8 };
        endpoints.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        endpoints.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        endpoints.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        endpoints.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        endpoints.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        AddEndpointRow(endpoints, 0, Strings.Get("Compare/SourceLabel"), _sourceConnection, _sourceSchema, _sourceTable, new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { _scope } });
        AddEndpointRow(endpoints, 1, Strings.Get("Compare/TargetLabel"), _targetConnection, _targetSchema, _targetTable, new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { _compare, _stop, _busy } });

        var options = new Expander
        {
            Header = Strings.Get("Compare/Options"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Content = new StackPanel { Spacing = 8, Children = { _dataOptions, _structureOptions } },
        };

        var filters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        filters.Children.Add(_showInserts);
        filters.Children.Add(_showUpdates);
        filters.Children.Add(_showDeletes);
        _rowsPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _rowsPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _rowsPanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _rowsPanel.Children.Add(BuildPlanHeader());
        Grid.SetRow(filters, 1);
        _rowsPanel.Children.Add(filters);
        Grid.SetRow(_grid, 2);
        _rowsPanel.Children.Add(_grid);

        _structurePanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(320) });
        _structurePanel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _structurePanel.Children.Add(_tables);
        var detail = new ScrollViewer { Content = _tableDetail };
        Grid.SetColumn(detail, 1);
        _structurePanel.Children.Add(detail);

        var footer = new Grid { ColumnSpacing = 12 };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.Children.Add(_status);
        var actions = new Grid { Children = { _dataActions, _structureActions } };
        Grid.SetColumn(actions, 1);
        footer.Children.Add(actions);

        var root = new Grid { Padding = new Thickness(12), RowSpacing = 10 };
        UIElement[] rows = [header, endpoints, options, _summary, _notes, new Grid { Children = { _rowsPanel, BuildPlanList(), _structurePanel } }, footer];
        for (var i = 0; i < rows.Length; i++)
        {
            root.RowDefinitions.Add(new RowDefinition { Height = i == 5 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
            Grid.SetRow((FrameworkElement)rows[i], i);
            root.Children.Add(rows[i]);
        }

        return root;
    }

    private static void AddEndpointRow(Grid grid, int row, string label, ComboBox connection, ComboBox schema, ComboBox table, FrameworkElement trailing)
    {
        var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, MinWidth = 56 };
        var pickers = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { connection, schema, table } };
        Grid.SetRow(text, row);
        Grid.SetRow(pickers, row);
        Grid.SetColumn(pickers, 1);
        Grid.SetRow(trailing, row);
        Grid.SetColumn(trailing, 2);
        grid.Children.Add(text);
        grid.Children.Add(pickers);
        grid.Children.Add(trailing);
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(CompareTabViewModel.Result):
                RebuildGrid();
                break;
            case nameof(CompareTabViewModel.SchemaDiffs):
                RebuildTables();
                break;
            case nameof(CompareTabViewModel.TablePlans):
                RebuildPlanList();
                break;
            case nameof(CompareTabViewModel.SelectedPlan):
                RebuildGrid();
                UpdateVisibility();
                break;
            case nameof(CompareTabViewModel.Mode):
            case nameof(CompareTabViewModel.Scope):
                UpdateVisibility();
                Refresh();
                break;
            case nameof(CompareTabViewModel.StatusText):
            case nameof(CompareTabViewModel.IsBusy):
            case nameof(CompareTabViewModel.Summary):
            case nameof(CompareTabViewModel.Notes):
                RefreshStatus();
                break;
            default:
                Refresh();
                break;
        }
    }

    /// <summary>Puts every picker and option back in step with the view model, as after a saved comparison loads.</summary>
    private void Refresh()
    {
        _updating = true;
        try
        {
            var vm = ViewModel;
            _modes.SelectedItem = _modes.Items[vm.Mode == CompareMode.Structure ? 1 : 0];
            _scope.SelectedIndex = Array.IndexOf(Scopes, vm.Scope);
            _sourceConnection.SelectedIndex = vm.Profiles.ToList().FindIndex(p => p.Id == vm.SourceProfile.Id);
            _targetConnection.SelectedIndex = vm.TargetProfile is { } target ? vm.Profiles.ToList().FindIndex(p => p.Id == target.Id) : -1;

            Fill(_sourceSchema, vm.SourceSchemas);
            _sourceSchema.SelectedIndex = vm.SourceSchema is { } sourceSchema ? IndexOfName(vm.SourceSchemas, sourceSchema) : -1;
            Fill(_targetSchema, vm.TargetSchemas);
            _targetSchema.SelectedIndex = vm.TargetSchema is { } targetSchema ? IndexOfName(vm.TargetSchemas, targetSchema) : -1;
            _sourceSchema.Visibility = vm.SourceSchemas.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            _targetSchema.Visibility = vm.TargetSchemas.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

            Fill(_sourceTable, [.. vm.SourceTables.Select(t => t.Name.ToString())]);
            _sourceTable.SelectedIndex = vm.SelectedSourceTable is { } sourceTable ? IndexOf(vm.SourceTables, sourceTable) : -1;
            Fill(_targetTable, [.. vm.TargetTables.Select(t => t.Name.ToString())]);
            _targetTable.SelectedIndex = vm.SelectedTargetTable is { } targetTable ? IndexOf(vm.TargetTables, targetTable) : -1;

            foreach (var refresh in _optionRefreshers)
            {
                refresh();
            }
        }
        finally
        {
            _updating = false;
        }

        RefreshStatus();
    }

    private static int IndexOfName(IReadOnlyList<string> names, string name)
    {
        for (var i = 0; i < names.Count; i++)
        {
            if (string.Equals(names[i], name, StringComparison.Ordinal))
            {
                return i;
            }
        }

        return -1;
    }

    private void RefreshStatus()
    {
        var vm = ViewModel;
        _busy.IsActive = vm.IsBusy;
        _stop.Visibility = vm.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        _compare.IsEnabled = !vm.IsBusy;
        _summary.Text = vm.Summary ?? string.Empty;
        _summary.Visibility = string.IsNullOrEmpty(vm.Summary) ? Visibility.Collapsed : Visibility.Visible;
        _status.Text = vm.StatusText ?? string.Empty;
        _notes.Message = string.Join("\n", vm.Notes);
        _notes.IsOpen = vm.Notes.Count > 0;
    }

    private void UpdateVisibility()
    {
        var vm = ViewModel;
        var data = vm.Mode == CompareMode.Data;
        var oneTable = data && vm.Scope == DataCompareScope.OneTable;
        var showRows = oneTable || (vm.IsMultiTable && vm.SelectedPlan is not null);
        _dataOptions.Visibility = _dataActions.Visibility = data ? Visibility.Visible : Visibility.Collapsed;
        _structureOptions.Visibility = _structurePanel.Visibility = _structureActions.Visibility = data ? Visibility.Collapsed : Visibility.Visible;
        _tableOptions.Visibility = oneTable ? Visibility.Visible : Visibility.Collapsed;
        _sourceTable.Visibility = _targetTable.Visibility = oneTable ? Visibility.Visible : Visibility.Collapsed;
        _scope.Visibility = data ? Visibility.Visible : Visibility.Collapsed;
        _rowsPanel.Visibility = showRows ? Visibility.Visible : Visibility.Collapsed;
        _planHeader.Visibility = vm.IsMultiTable ? Visibility.Visible : Visibility.Collapsed;
        _planList.Visibility = vm.IsMultiTable && vm.SelectedPlan is null ? Visibility.Visible : Visibility.Collapsed;
        _skip.Visibility = showRows ? Visibility.Visible : Visibility.Collapsed;
        _selectButtons.Visibility = vm.Scope == DataCompareScope.ChosenTables ? Visibility.Visible : Visibility.Collapsed;
        _compare.Content = !data ? Strings.Get("Compare/CompareStructureButton") : vm.IsMultiTable ? Strings.Get("Compare/CompareTablesButton") : Strings.Get("Compare/CompareButton");
        _planTitle.Text = vm.SelectedPlan?.DisplayName ?? string.Empty;
        foreach (var row in _planRows)
        {
            row.UpdateScope(vm.Scope);
            row.Update();
        }
    }

    /// <summary>The comparison the grid shows: the one-table result, or the drilled-into table's.</summary>
    private (DataDiffResult? Result, IReadOnlySet<string> Excluded) Shown() =>
        ViewModel.IsMultiTable
            ? ViewModel.SelectedPlan is { Outcome.Result: { } result } plan ? (result, plan.Excluded) : (null, ViewModel.Excluded)
            : (ViewModel.Result, ViewModel.Excluded);

    private void RebuildGrid()
    {
        var (result, excluded) = Shown();
        if (result is null)
        {
            _grid.Source = null;
            _source = null;
            RefreshStatus();
            return;
        }

        var kinds = new HashSet<RowDiffKind>();
        if (_showInserts.IsChecked == true)
        {
            kinds.Add(RowDiffKind.OnlyInSource);
        }

        if (_showUpdates.IsChecked == true)
        {
            kinds.Add(RowDiffKind.Changed);
        }

        if (_showDeletes.IsChecked == true)
        {
            kinds.Add(RowDiffKind.OnlyInTarget);
        }

        _showInserts.Content = Strings.Format("Compare/ShowOnlyInSourceCount", result.OnlyInSourceCount);
        _showUpdates.Content = Strings.Format("Compare/ShowChangedCount", result.ChangedCount);
        _showDeletes.Content = Strings.Format("Compare/ShowOnlyInTargetCount", result.OnlyInTargetCount);
        _source = new CompareGridSource(result, kinds, excluded);
        _grid.Source = _source;
        RefreshStatus();
    }

    private void ToggleSelected()
    {
        if (_source is null)
        {
            return;
        }

        var rows = _grid.SelectedRows.Where(r => r >= 0 && r < _source.RowCount).Select(_source.Diff).ToArray();
        if (rows.Length > 0)
        {
            ViewModel.ToggleExcluded(rows);
            _source.NotifyChanged();
        }
    }

    private void RebuildTables()
    {
        _tables.Items.Clear();
        foreach (var diff in ViewModel.SchemaDiffs.Where(d => d.Kind != SchemaDiffKind.Identical).Concat(ViewModel.SchemaDiffs.Where(d => d.Kind == SchemaDiffKind.Identical)))
        {
            var label = diff.Kind switch
            {
                SchemaDiffKind.OnlyInSource => Strings.Get("Compare/TableOnlyInSourceCreated"),
                SchemaDiffKind.OnlyInTarget => ViewModel.DropExtraTables ? Strings.Get("Compare/TableOnlyInTargetDropped") : Strings.Get("Compare/TableOnlyInTarget"),
                SchemaDiffKind.Changed => Strings.Plural("Compare/TableChanges", diff.Changes.Count),
                _ => Strings.Get("Compare/TableIdentical"),
            };
            var item = new StackPanel { Tag = diff, Padding = new Thickness(0, 4, 0, 4) };
            item.Children.Add(new TextBlock { Text = diff.Name, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
            item.Children.Add(new TextBlock { Text = label, Opacity = 0.7 });
            _tables.Items.Add(item);
        }

        _tableDetail.Children.Clear();
        if (_tables.Items.Count > 0)
        {
            _tables.SelectedIndex = 0;
        }

        RefreshStatus();
    }

    private void ShowTableDetail()
    {
        _tableDetail.Children.Clear();
        if ((_tables.SelectedItem as FrameworkElement)?.Tag is not TableSchemaDiff diff)
        {
            return;
        }

        _tableDetail.Children.Add(new TextBlock { Text = diff.Name, Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });
        foreach (var change in diff.Changes)
        {
            _tableDetail.Children.Add(new TextBlock { Text = SchemaMigrationBuilder.Describe(change), TextWrapping = TextWrapping.Wrap });
        }

        foreach (var note in diff.Notes)
        {
            _tableDetail.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Message = note });
        }

        if (ViewModel.BuildMigration() is { } script)
        {
            var sql = script.Statements.Where(s => string.Equals(s.Table.Name, diff.Name, StringComparison.OrdinalIgnoreCase)).Select(s => s.Sql).ToArray();
            if (sql.Length > 0)
            {
                _tableDetail.Children.Add(DialogService.CodeBlock(string.Join(";\n", sql) + ";", 400));
            }
        }
    }
}
