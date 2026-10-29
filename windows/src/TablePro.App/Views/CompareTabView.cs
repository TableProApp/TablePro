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
/// The Compare and Sync tab: a source table on this connection against a target table on any saved connection, or the
/// two schemas side by side. Differences show in the data grid in its edit colors, and every sync or migration goes
/// through the review sheet before it runs.
/// </summary>
public sealed partial class CompareTabView : UserControl
{
    private readonly SelectorBar _modes = new();
    private readonly ComboBox _sourceTable = new() { MinWidth = 200, PlaceholderText = Strings.Get("Compare/SourceTable") };
    private readonly ComboBox _targetConnection = new() { MinWidth = 180, PlaceholderText = Strings.Get("Compare/TargetConnection") };
    private readonly ComboBox _targetTable = new() { MinWidth = 200, PlaceholderText = Strings.Get("Compare/TargetTable") };
    private readonly Button _compare = new() { Content = Strings.Get("Compare/CompareButton"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
    private readonly Button _stop = new() { Content = Strings.Get("Common/Stop"), Visibility = Visibility.Collapsed };
    private readonly ProgressRing _busy = new() { Width = 18, Height = 18, IsActive = false };
    private readonly TextBlock _summary = new() { TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
    private readonly InfoBar _notes = new() { IsClosable = false, Severity = InfoBarSeverity.Informational };
    private readonly StackPanel _dataOptions = new() { Spacing = 8 };
    private readonly StackPanel _structureOptions = new() { Spacing = 8, Visibility = Visibility.Collapsed };
    private readonly ToggleButton _showInserts = new() { Content = Strings.Get("Compare/ShowOnlyInSource"), IsChecked = true };
    private readonly ToggleButton _showUpdates = new() { Content = Strings.Get("Compare/ShowChanged"), IsChecked = true };
    private readonly ToggleButton _showDeletes = new() { Content = Strings.Get("Compare/ShowOnlyInTarget"), IsChecked = true };
    private readonly DataGridView _grid = new();
    private readonly Grid _dataPanel = new() { RowSpacing = 8 };
    private readonly Grid _structurePanel = new() { ColumnSpacing = 12, Visibility = Visibility.Collapsed };
    private readonly ListView _tables = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly StackPanel _tableDetail = new() { Spacing = 8 };
    private readonly StackPanel _dataActions = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly StackPanel _structureActions = new() { Orientation = Orientation.Horizontal, Spacing = 8, Visibility = Visibility.Collapsed };
    private CompareGridSource? _source;
    private bool _updating;

    public CompareTabView(CompareTabViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(viewModel);
        ViewModel = viewModel;

        _modes.Items.Add(new SelectorBarItem { Text = Strings.Get("Compare/ModeData"), IsSelected = true });
        _modes.Items.Add(new SelectorBarItem { Text = Strings.Get("Compare/ModeStructure") });
        _modes.SelectionChanged += (_, _) => SetMode(_modes.SelectedItem == _modes.Items[1] ? CompareMode.Structure : CompareMode.Data);

        foreach (var table in viewModel.SourceTables)
        {
            _sourceTable.Items.Add(table.Name.ToString());
        }

        foreach (var profile in viewModel.Profiles)
        {
            _targetConnection.Items.Add(profile.Name);
        }

        _sourceTable.SelectedIndex = viewModel.SelectedSourceTable is { } selected ? IndexOf(viewModel.SourceTables, selected) : -1;
        _targetConnection.SelectedIndex = viewModel.TargetProfile is { } target ? viewModel.Profiles.ToList().FindIndex(p => p.Id == target.Id) : -1;
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
        _targetTable.SelectionChanged += (_, _) =>
        {
            if (!_updating && _targetTable.SelectedIndex >= 0)
            {
                ViewModel.SelectedTargetTable = ViewModel.TargetTables[_targetTable.SelectedIndex];
            }
        };

        _compare.Click += async (_, _) =>
        {
            if (ViewModel.Mode == CompareMode.Data)
            {
                await ViewModel.CompareDataAsync();
            }
            else
            {
                await ViewModel.CompareStructureAsync();
            }
        };
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
            if (ViewModel.Target is null)
            {
                await ViewModel.ConnectTargetAsync();
            }
        };
        Refresh();
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

    private static TextBox Field(string header, string placeholder, string value, Action<string> set)
    {
        var box = new TextBox { Header = header, PlaceholderText = placeholder, Text = value, MinWidth = 220 };
        box.TextChanged += (_, _) => set(box.Text);
        return box;
    }

    private static CheckBox Check(string text, bool value, Action<bool> set)
    {
        var box = new CheckBox { Content = text, IsChecked = value };
        box.Click += (_, _) => set(box.IsChecked == true);
        return box;
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

    private void BuildOptions()
    {
        var vm = ViewModel;
        var keys = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        keys.Children.Add(Field(Strings.Get("Compare/KeyColumns"), Strings.Get("Compare/KeyColumnsPlaceholder"), vm.KeyColumns, v => vm.KeyColumns = v));
        keys.Children.Add(Field(Strings.Get("Compare/LeaveOutColumns"), "updated_at, version", vm.ExcludedColumns, v => vm.ExcludedColumns = v));
        _dataOptions.Children.Add(keys);

        var filters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        filters.Children.Add(Field(Strings.Get("Compare/SourceWhere"), "status = 'active'", vm.SourceWhere, v => vm.SourceWhere = v));
        filters.Children.Add(Field(Strings.Get("Compare/TargetWhere"), "status = 'active'", vm.TargetWhere, v => vm.TargetWhere = v));
        var tolerance = new NumberBox { Header = Strings.Get("Compare/FloatTolerance"), Value = vm.FloatTolerance, Minimum = 0, SmallChange = 0.001, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        tolerance.ValueChanged += (_, e) => vm.FloatTolerance = double.IsNaN(e.NewValue) ? 0 : e.NewValue;
        var limit = new NumberBox { Header = Strings.Get("Compare/RowLimit"), PlaceholderText = Strings.Get("Compare/RowLimitPlaceholder"), Value = vm.RowLimit, Minimum = 1 };
        limit.ValueChanged += (_, e) => vm.RowLimit = e.NewValue;
        filters.Children.Add(tolerance);
        filters.Children.Add(limit);
        _dataOptions.Children.Add(filters);

        var writes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        writes.Children.Add(Check(Strings.Get("Compare/InsertMissingRows"), vm.InsertMissing, v => vm.InsertMissing = v));
        writes.Children.Add(Check(Strings.Get("Compare/UpdateChangedRows"), vm.UpdateChanged, v => vm.UpdateChanged = v));
        writes.Children.Add(Check(Strings.Get("Compare/DeleteExtraRows"), vm.DeleteExtra, v => vm.DeleteExtra = v));
        writes.Children.Add(Check(Strings.Get("Compare/KeysIgnoreCase"), vm.KeysIgnoreCase, v => vm.KeysIgnoreCase = v));
        writes.Children.Add(Check(Strings.Get("Compare/CommitInBatches"), vm.ApplyInBatches, v => vm.ApplyInBatches = v));
        _dataOptions.Children.Add(writes);

        var drops = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        drops.Children.Add(Check(Strings.Get("Compare/DropExtraTables"), vm.DropExtraTables, v => vm.DropExtraTables = v));
        drops.Children.Add(Check(Strings.Get("Compare/DropExtraColumns"), vm.DropExtraColumns, v => vm.DropExtraColumns = v));
        _structureOptions.Children.Add(drops);
    }

    private void BuildActions()
    {
        var skip = new Button { Content = Strings.Get("Compare/SkipOrIncludeRows") };
        skip.Click += (_, _) => ToggleSelected();
        var copy = new Button { Content = Strings.Get("Compare/CopySyncScript") };
        copy.Click += (_, _) => Copy(ViewModel.SyncScript());
        var sync = new Button { Content = Strings.Get("Compare/ReviewAndSync"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        sync.Click += async (_, _) => await ViewModel.SyncAsync();
        _dataActions.Children.Add(skip);
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
        var endpoints = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        endpoints.Children.Add(new TextBlock { Text = Strings.Get("Compare/SourceLabel"), VerticalAlignment = VerticalAlignment.Center });
        endpoints.Children.Add(_sourceTable);
        endpoints.Children.Add(new FontIcon { Glyph = "", FontSize = 14, Margin = new Thickness(4, 0, 4, 0) });
        endpoints.Children.Add(new TextBlock { Text = Strings.Get("Compare/TargetLabel"), VerticalAlignment = VerticalAlignment.Center });
        endpoints.Children.Add(_targetConnection);
        endpoints.Children.Add(_targetTable);
        endpoints.Children.Add(_compare);
        endpoints.Children.Add(_stop);
        endpoints.Children.Add(_busy);
        AutomationProperties.SetName(_sourceTable, Strings.Get("Compare/SourceTable"));
        AutomationProperties.SetName(_targetConnection, Strings.Get("Compare/TargetConnection"));
        AutomationProperties.SetName(_targetTable, Strings.Get("Compare/TargetTable"));

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
        _dataPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _dataPanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _dataPanel.Children.Add(filters);
        Grid.SetRow(_grid, 1);
        _dataPanel.Children.Add(_grid);

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
        for (var i = 0; i < 7; i++)
        {
            root.RowDefinitions.Add(new RowDefinition { Height = i == 5 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
        }

        UIElement[] rows = [_modes, endpoints, options, _summary, _notes, new Grid { Children = { _dataPanel, _structurePanel } }, footer];
        for (var i = 0; i < rows.Length; i++)
        {
            Grid.SetRow((FrameworkElement)rows[i], i);
            root.Children.Add(rows[i]);
        }

        return root;
    }

    private void SetMode(CompareMode mode)
    {
        ViewModel.Mode = mode;
        var data = mode == CompareMode.Data;
        _dataOptions.Visibility = _dataPanel.Visibility = _dataActions.Visibility = data ? Visibility.Visible : Visibility.Collapsed;
        _structureOptions.Visibility = _structurePanel.Visibility = _structureActions.Visibility = data ? Visibility.Collapsed : Visibility.Visible;
        _sourceTable.Visibility = _targetTable.Visibility = data ? Visibility.Visible : Visibility.Collapsed;
        _compare.Content = data ? Strings.Get("Compare/CompareButton") : Strings.Get("Compare/CompareStructureButton");
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
            default:
                Refresh();
                break;
        }
    }

    private void Refresh()
    {
        _updating = true;
        try
        {
            var vm = ViewModel;
            if (_targetTable.Items.Count != vm.TargetTables.Count || (vm.TargetTables.Count > 0 && !Equals(_targetTable.Items[0], vm.TargetTables[0].Name.ToString())))
            {
                _targetTable.Items.Clear();
                foreach (var table in vm.TargetTables)
                {
                    _targetTable.Items.Add(table.Name.ToString());
                }
            }

            _targetTable.SelectedIndex = vm.SelectedTargetTable is { } target ? IndexOf(vm.TargetTables, target) : -1;
            _busy.IsActive = vm.IsBusy;
            _stop.Visibility = vm.IsRunning ? Visibility.Visible : Visibility.Collapsed;
            _compare.IsEnabled = !vm.IsBusy;
            _summary.Text = vm.Summary ?? string.Empty;
            _summary.Visibility = string.IsNullOrEmpty(vm.Summary) ? Visibility.Collapsed : Visibility.Visible;
            _status.Text = vm.StatusText ?? string.Empty;
            _notes.Message = string.Join("\n", vm.Notes);
            _notes.IsOpen = vm.Notes.Count > 0;
        }
        finally
        {
            _updating = false;
        }
    }

    private void RebuildGrid()
    {
        if (ViewModel.Result is not { } result)
        {
            _grid.Source = null;
            _source = null;
            Refresh();
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
        _source = new CompareGridSource(result, kinds, ViewModel.Excluded);
        _grid.Source = _source;
        Refresh();
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

        Refresh();
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
