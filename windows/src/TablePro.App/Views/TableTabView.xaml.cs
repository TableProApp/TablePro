using System.ComponentModel;
using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Controls.DataGrid;
using TablePro.App.Helpers;
using TablePro.App.ViewModels;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Import;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using ColumnDefinition = TablePro.Core.Schema.ColumnDefinition;
using Windows.System;

namespace TablePro.App.Views;

public sealed partial class TableTabView : UserControl
{
    private static readonly int[] PageSizes = [100, 200, 500, 1000, 5000, 10000];
    private string _structureSection = "Columns";

    public TableTabView(TableTabViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();

        foreach (var size in PageSizes)
        {
            PageSizeBox.Items.Add(size.ToString("N0", CultureInfo.CurrentCulture));
        }

        PageSizeBox.SelectedIndex = Math.Max(0, Array.IndexOf(PageSizes, viewModel.PageSize));
        DefinitionEditor.Dialect = viewModel.Context.Session.Dialect;

        RowsGrid.SortRequested += async (_, e) => await ViewModel.SortByAsync(e.Column, e.AddToExisting);
        RowsGrid.CellContextRequested += OnRowsContext;
        RowsGrid.DeleteRequested += (_, _) => ViewModel.ToggleDeleteRows(RowsGrid.SelectedRows);
        RowsGrid.EditRejected += (_, message) => ViewModel.StatusText = message;
        RowsGrid.SelectionChanged += (_, _) => UpdateSelectionText();
        RowsGrid.CellActivated += (_, e) => Inspect(e.Row, e.Column);
        viewModel.Filters.CollectionChanged += (_, _) => FilterStrip.Visibility = viewModel.Filters.Count > 0 || !string.IsNullOrEmpty(viewModel.RawWhere) ? Visibility.Visible : Visibility.Collapsed;
        viewModel.PropertyChanged += OnViewModelPropertyChanged;
        Loaded += async (_, _) =>
        {
            if (ViewModel.Rows is null)
            {
                await ViewModel.InitializeAsync();
            }
        };
    }

    public event EventHandler<string>? OpenSqlRequested;

    public event EventHandler<(string Title, string Value)>? ValueInspectRequested;

    /// <summary>A foreign key cell asks the workspace to open the table it points at, filtered to the value.</summary>
    public event EventHandler<(ObjectName Table, string Column, object? Value)>? ForeignKeyRequested;

    public TableTabViewModel ViewModel { get; }

    public void ShowSection(TableTabSection section)
    {
        Sections.SelectedItem = Sections.Items.First(i => (string)i.Tag == section.ToString());
    }

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(TableTabViewModel.Rows):
                RowsGrid.Source = ViewModel.Rows;
                RowsGrid.SortColumns = ViewModel.SortIndicators;
                UpdateSelectionText();
                break;
            case nameof(TableTabViewModel.ReadOnlyReason):
                ReadOnlyBar.Message = ViewModel.ReadOnlyReason ?? string.Empty;
                ReadOnlyBar.Severity = ViewModel.IsEditable ? InfoBarSeverity.Warning : InfoBarSeverity.Informational;
                ReadOnlyBar.IsOpen = ViewModel.ReadOnlyReason is not null;
                break;
            case nameof(TableTabViewModel.Definition):
                DefinitionEditor.Text = ViewModel.Definition;
                break;
            case nameof(TableTabViewModel.ColumnsGrid) or nameof(TableTabViewModel.IndexesGrid) or nameof(TableTabViewModel.ForeignKeysGrid) or nameof(TableTabViewModel.TriggersGrid):
                ShowStructureGrid();
                break;
        }
    }

    private void OnSectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var tag = sender.SelectedItem?.Tag as string;
        DataPanel.Visibility = tag == "Data" ? Visibility.Visible : Visibility.Collapsed;
        StructurePanel.Visibility = tag == "Structure" ? Visibility.Visible : Visibility.Collapsed;
        DefinitionPanel.Visibility = tag == "Definition" ? Visibility.Visible : Visibility.Collapsed;
        if (Enum.TryParse<TableTabSection>(tag, out var section))
        {
            ViewModel.Section = section;
        }
    }

    private void OnStructureSectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        _structureSection = sender.SelectedItem?.Tag as string ?? "Columns";
        ShowStructureGrid();
    }

    private void ShowStructureGrid() => StructureGrid.Source = _structureSection switch
    {
        "Indexes" => ViewModel.IndexesGrid,
        "ForeignKeys" => ViewModel.ForeignKeysGrid,
        "Triggers" => ViewModel.TriggersGrid,
        _ => ViewModel.ColumnsGrid,
    };

    private void UpdateSelectionText()
    {
        var rows = RowsGrid.SelectedRows.Count;
        SelectionText.Text = rows > 1 ? string.Create(CultureInfo.CurrentCulture, $"{rows:N0} rows selected") : string.Empty;
    }

    private async void OnPageSizeChanged(object sender, SelectionChangedEventArgs e)
    {
        var size = PageSizes[Math.Max(0, PageSizeBox.SelectedIndex)];
        if (size != ViewModel.PageSize)
        {
            ViewModel.PageSize = size;
            ViewModel.Offset = 0;
            await ViewModel.LoadAsync();
        }
    }

    private void OnFilterKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            ViewModel.ApplyFiltersCommand.Execute(null);
            e.Handled = true;
        }
    }

    private void OnRemoveFilter(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is FilterRuleViewModel rule)
        {
            ViewModel.Filters.Remove(rule);
        }
    }

    private void OnDeleteRows(object sender, RoutedEventArgs e) => ViewModel.ToggleDeleteRows(RowsGrid.SelectedRows);

    private void OnRowsContext(object? sender, GridCellEventArgs e)
    {
        var menu = new MenuFlyout();
        GridCommands.AddCopyItems(menu, RowsGrid, ViewModel.Context.Session.Dialect, ViewModel.Table.Name);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(GridCommands.Item("Filter by This Value", "", async () => await ViewModel.FilterByValueAsync(e.Row, e.Column, exclude: false)));
        menu.Items.Add(GridCommands.Item("Exclude This Value", "", async () => await ViewModel.FilterByValueAsync(e.Row, e.Column, exclude: true)));
        if (ForeignKeyFor(e.Column) is { } foreignKey)
        {
            menu.Items.Add(GridCommands.Item($"Open {foreignKey.ReferencedTable.Name}", "", () =>
                ForeignKeyRequested?.Invoke(this, (foreignKey.ReferencedTable, foreignKey.ReferencedColumns[0], RowsGrid.Source?.GetValue(e.Row, e.Column)))));
        }

        menu.Items.Add(GridCommands.Item("Inspect Value", "", () => Inspect(e.Row, e.Column)));
        if (ViewModel.IsEditable)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(GridCommands.Item("Edit Cell", "", () => RowsGrid.BeginEdit(), "Enter"));
            menu.Items.Add(GridCommands.Item("Set to NULL", "", RowsGrid.SetActiveCellNull));
            menu.Items.Add(GridCommands.Item("Duplicate Row", "", () => ViewModel.DuplicateRow(e.Row)));
            menu.Items.Add(GridCommands.Item("Delete Rows", "", () => ViewModel.ToggleDeleteRows(RowsGrid.SelectedRows), "Delete"));
        }

        menu.ShowAt(e.Target, e.Position);
    }

    private ForeignKeyInfo? ForeignKeyFor(int column)
    {
        if (ViewModel.Structure is not { } structure || RowsGrid.Source is not { } source)
        {
            return null;
        }

        var name = source.Columns[column].Name;
        return structure.ForeignKeys.FirstOrDefault(f => f.Columns.Count == 1 && string.Equals(f.Columns[0], name, StringComparison.OrdinalIgnoreCase));
    }

    private void Inspect(int row, int column)
    {
        if (RowsGrid.Source is { } source)
        {
            var value = source.GetValue(row, column);
            ValueInspectRequested?.Invoke(this, (source.Columns[column].Name, value is null ? "NULL" : CellFormatter.Format(value)));
        }
    }

    private async void OnExport(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Buffer?.Baseline is { } result)
        {
            await GridCommands.ExportAsync(ViewModel.Context.Dialogs, result, ViewModel.Context.Session.Dialect, ViewModel.Table.Name, ViewModel.Title);
        }
    }

    private async void OnImport(object sender, RoutedEventArgs e)
    {
        var dialogs = ViewModel.Context.Dialogs;
        var file = await dialogs.PickOpenFileAsync(".csv", ".tsv", ".txt");
        if (file is null || ViewModel.Structure is not { } structure)
        {
            return;
        }

        var columns = structure.Columns.Select(c => c.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var clrTypes = ViewModel.Buffer?.Baseline.Columns.ToDictionary(c => c.Name, c => c.ClrType, StringComparer.OrdinalIgnoreCase) ?? [];
        ViewModel.IsBusy = true;
        ViewModel.StatusText = "Importing…";
        try
        {
            var imported = await Task.Run(async () =>
            {
                using var reader = new StreamReader(file.Path, detectEncodingFromByteOrderMarks: true);
                var firstLine = reader.ReadLine() ?? string.Empty;
                reader.BaseStream.Position = 0;
                reader.DiscardBufferedData();
                var csv = new CsvReader(reader, CsvReader.DetectDelimiter(firstLine));
                var header = csv.ReadRecord() ?? [];
                var mapped = header.Select(h => columns.Contains(h.Trim()) ? h.Trim() : null).ToArray();
                if (mapped.All(m => m is null))
                {
                    throw new InvalidOperationException("No column in the file's header matches a column of this table.");
                }

                var total = 0;
                var batch = new List<RowChange>(500);
                while (csv.ReadRecord() is { } record)
                {
                    var values = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                    for (var i = 0; i < mapped.Length && i < record.Length; i++)
                    {
                        if (mapped[i] is { } column)
                        {
                            var text = record[i].Length == 0 ? null : record[i];
                            values[column] = clrTypes.TryGetValue(column, out var type) && ValueParser.TryParse(text, type, out var parsed) ? parsed : text;
                        }
                    }

                    batch.Add(new RowInsert(values));
                    if (batch.Count == 500)
                    {
                        total += await ViewModel.Context.Session.Database.SaveChangesAsync(ViewModel.Table.Name, batch, CancellationToken.None);
                        batch.Clear();
                    }
                }

                if (batch.Count > 0)
                {
                    total += await ViewModel.Context.Session.Database.SaveChangesAsync(ViewModel.Table.Name, batch, CancellationToken.None);
                }

                return total;
            });
            ViewModel.Context.Notify(string.Create(CultureInfo.CurrentCulture, $"Imported {imported:N0} rows into {ViewModel.Title}."));
            await ViewModel.LoadAsync();
        }
        catch (Exception ex)
        {
            await dialogs.ShowErrorAsync("Import stopped", ex.Message);
        }
        finally
        {
            ViewModel.IsBusy = false;
            ViewModel.StatusText = null;
        }
    }

    private void OnCopyDefinition(object sender, RoutedEventArgs e) => GridCommands.SetClipboard(ViewModel.Definition);

    private void OnOpenDefinition(object sender, RoutedEventArgs e) => OpenSqlRequested?.Invoke(this, ViewModel.Definition);

    private async void OnStructureAdd(object sender, RoutedEventArgs e)
    {
        var change = _structureSection switch
        {
            "Indexes" => await IndexDialogAsync(),
            "ForeignKeys" => await ForeignKeyDialogAsync(),
            _ => await ColumnDialogAsync(null),
        };
        if (change is not null)
        {
            await ViewModel.ApplySchemaChangeAsync(change);
        }
    }

    private async void OnStructureEdit(object sender, RoutedEventArgs e)
    {
        if (_structureSection != "Columns" || ViewModel.Structure is not { } structure || StructureGrid.ActiveCell is not { } cell || cell.Row >= structure.Columns.Count)
        {
            return;
        }

        var before = ColumnDefinition.From(structure.Columns[cell.Row]);
        if (await ColumnDialogAsync(before) is AlterColumn alter)
        {
            if (!string.Equals(before.Name, alter.After.Name, StringComparison.Ordinal))
            {
                if (!await ViewModel.ApplySchemaChangeAsync(new RenameColumn(before.Name, alter.After.Name)))
                {
                    return;
                }

                before = before with { Name = alter.After.Name };
            }

            if (before != alter.After)
            {
                await ViewModel.ApplySchemaChangeAsync(new AlterColumn(before, alter.After));
            }
        }
    }

    private async void OnStructureDrop(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Structure is not { } structure || StructureGrid.ActiveCell is not { } cell)
        {
            return;
        }

        SchemaChange? change = _structureSection switch
        {
            "Columns" when cell.Row < structure.Columns.Count => new DropColumn(structure.Columns[cell.Row].Name),
            "Indexes" when cell.Row < structure.Indexes.Count => new DropIndex(structure.Indexes[cell.Row].Name),
            "ForeignKeys" when cell.Row < structure.ForeignKeys.Count => new DropForeignKey(structure.ForeignKeys[cell.Row].Name),
            _ => null,
        };
        if (change is not null)
        {
            await ViewModel.ApplySchemaChangeAsync(change);
        }
    }

    private async Task<SchemaChange?> ColumnDialogAsync(ColumnDefinition? existing)
    {
        var types = (ViewModel.Context.Session.Database as ISchemaDdlProvider)?.CommonDataTypes ?? [];
        var name = new TextBox { Header = "Name", Text = existing?.Name ?? string.Empty };
        var type = new ComboBox { Header = "Type", IsEditable = true, ItemsSource = types.ToList(), Text = existing?.DataType ?? (types.Count > 0 ? types[0] : "text"), HorizontalAlignment = HorizontalAlignment.Stretch };
        var nullable = new CheckBox { Content = "Allows NULL", IsChecked = existing?.IsNullable ?? true };
        var defaultValue = new TextBox { Header = "Default expression", Text = existing?.DefaultExpression ?? string.Empty, PlaceholderText = "for example 0, 'text' or now()" };
        var comment = new TextBox { Header = "Comment", Text = existing?.Comment ?? string.Empty };
        var panel = new StackPanel { Spacing = 12, MinWidth = 380 };
        panel.Children.Add(name);
        panel.Children.Add(type);
        panel.Children.Add(nullable);
        panel.Children.Add(defaultValue);
        panel.Children.Add(comment);
        var dialogs = ViewModel.Context.Dialogs;
        if (await dialogs.ShowAsync(dialogs.Create(existing is null ? "Add Column" : "Edit Column", panel, existing is null ? "Add" : "Save", "Cancel")) != ContentDialogResult.Primary
            || string.IsNullOrWhiteSpace(name.Text))
        {
            return null;
        }

        var column = new ColumnDefinition(
            name.Text.Trim(),
            string.IsNullOrWhiteSpace(type.Text) ? type.SelectedItem as string ?? "text" : type.Text.Trim(),
            nullable.IsChecked == true,
            string.IsNullOrWhiteSpace(defaultValue.Text) ? null : defaultValue.Text.Trim(),
            existing?.IsPrimaryKey ?? false,
            existing?.IsIdentity ?? false,
            string.IsNullOrWhiteSpace(comment.Text) ? null : comment.Text.Trim());
        return existing is null ? new AddColumn(column) : new AlterColumn(existing, column);
    }

    private async Task<SchemaChange?> IndexDialogAsync()
    {
        if (ViewModel.Structure is not { } structure)
        {
            return null;
        }

        var name = new TextBox { Header = "Name", Text = $"idx_{ViewModel.Table.Name.Name}_" };
        var columns = new ListView { SelectionMode = ListViewSelectionMode.Multiple, ItemsSource = structure.Columns.Select(c => c.Name).ToList(), MaxHeight = 240, Header = "Columns, in key order" };
        var unique = new CheckBox { Content = "Unique" };
        var panel = new StackPanel { Spacing = 12, MinWidth = 380 };
        panel.Children.Add(name);
        panel.Children.Add(columns);
        panel.Children.Add(unique);
        var dialogs = ViewModel.Context.Dialogs;
        if (await dialogs.ShowAsync(dialogs.Create("Add Index", panel, "Add", "Cancel")) != ContentDialogResult.Primary || columns.SelectedItems.Count == 0)
        {
            return null;
        }

        return new CreateIndex(new IndexDefinition(name.Text.Trim(), columns.SelectedItems.Cast<string>().ToArray(), unique.IsChecked == true));
    }

    private async Task<SchemaChange?> ForeignKeyDialogAsync()
    {
        if (ViewModel.Structure is not { } structure)
        {
            return null;
        }

        var session = ViewModel.Context.Session;
        var tables = session.Objects.Where(o => o.Kind == ObjectKind.Table).Select(o => o.Name).ToList();
        var name = new TextBox { Header = "Name", Text = $"fk_{ViewModel.Table.Name.Name}_" };
        var column = new ComboBox { Header = "Column", ItemsSource = structure.Columns.Select(c => c.Name).ToList(), HorizontalAlignment = HorizontalAlignment.Stretch };
        var target = new ComboBox { Header = "References table", ItemsSource = tables.Select(t => t.ToString()).ToList(), HorizontalAlignment = HorizontalAlignment.Stretch };
        var targetColumn = new ComboBox { Header = "References column", HorizontalAlignment = HorizontalAlignment.Stretch };
        target.SelectionChanged += async (_, _) =>
        {
            if (target.SelectedIndex >= 0)
            {
                var referenced = await session.GetStructureAsync(tables[target.SelectedIndex], CancellationToken.None);
                targetColumn.ItemsSource = referenced.Columns.Select(c => c.Name).ToList();
                targetColumn.SelectedItem = referenced.PrimaryKey.Count > 0 ? referenced.PrimaryKey[0] : null;
            }
        };
        var onDelete = new ComboBox { Header = "On delete", ItemsSource = new[] { "NO ACTION", "CASCADE", "SET NULL", "RESTRICT" }, SelectedIndex = 0 };
        var panel = new StackPanel { Spacing = 12, MinWidth = 380 };
        panel.Children.Add(name);
        panel.Children.Add(column);
        panel.Children.Add(target);
        panel.Children.Add(targetColumn);
        panel.Children.Add(onDelete);
        var dialogs = ViewModel.Context.Dialogs;
        if (await dialogs.ShowAsync(dialogs.Create("Add Foreign Key", panel, "Add", "Cancel")) != ContentDialogResult.Primary
            || column.SelectedItem is not string from || target.SelectedIndex < 0 || targetColumn.SelectedItem is not string to)
        {
            return null;
        }

        return new AddForeignKey(new ForeignKeyDefinition(name.Text.Trim(), [from], tables[target.SelectedIndex], [to], onDelete.SelectedItem as string));
    }
}
