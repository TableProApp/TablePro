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

        UpdateStructureCommands();
        if (viewModel.KeyBrowse is { } keys)
        {
            KeySearchHost.Content = new KeySearchBar(viewModel, keys);
            KeySearchHost.Visibility = Visibility.Visible;
        }

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
            case nameof(TableTabViewModel.ColumnsGrid) or nameof(TableTabViewModel.IndexesGrid) or nameof(TableTabViewModel.ForeignKeysGrid) or nameof(TableTabViewModel.TriggersGrid)
                or nameof(TableTabViewModel.ChecksGrid) or nameof(TableTabViewModel.PartitionsGrid) or nameof(TableTabViewModel.OptionsGrid):
                ShowStructureGrid();
                break;
            case nameof(TableTabViewModel.Structure):
                UpdateStructureSections();
                break;
            case nameof(TableTabViewModel.DetailsError):
                DetailsErrorBar.Message = ViewModel.DetailsError ?? string.Empty;
                DetailsErrorBar.IsOpen = ViewModel.DetailsError is not null;
                break;
        }
    }

    /// <summary>
    /// Checks and options are offered where the engine reads them for a table; partitions only on a partitioned table.
    /// A section that disappears on refresh hands the selection back to Columns.
    /// </summary>
    private void UpdateStructureSections()
    {
        var structure = ViewModel.Structure;
        ChecksSection.Visibility = ViewModel.HasTableDetails ? Visibility.Visible : Visibility.Collapsed;
        PartitionsSection.Visibility = structure?.Partitioning is not null ? Visibility.Visible : Visibility.Collapsed;
        OptionsSection.Visibility = ViewModel.HasTableDetails && structure?.Options.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (StructureSections.SelectedItem is { Visibility: Visibility.Collapsed })
        {
            StructureSections.SelectedItem = StructureSections.Items[0];
        }

        ShowStructureGrid();
    }

    /// <summary>
    /// Each section offers only the edits its engine can make. Structure edits need DDL, so engines without SQL or
    /// without a DDL provider show their structure read-only.
    /// </summary>
    private void UpdateStructureCommands()
    {
        var session = ViewModel.Context.Session;
        var canEdit = session.Database is ISchemaDdlProvider && session.Dialect.IsSql;
        var edits = ViewModel.SupportedEdits;
        var partitioned = ViewModel.Structure?.Partitioning is not null;
        var (add, edit, truncate, drop) = _structureSection switch
        {
            "Columns" => (true, true, false, true),
            "Indexes" or "ForeignKeys" => (true, false, false, true),
            "Checks" => (edits.HasFlag(StructureEdits.CheckConstraints), edits.HasFlag(StructureEdits.CheckConstraints), false, edits.HasFlag(StructureEdits.CheckConstraints)),
            "Partitions" => (partitioned && edits.HasFlag(StructureEdits.AddPartition), false, edits.HasFlag(StructureEdits.TruncatePartition), edits.HasFlag(StructureEdits.DropPartition)),
            "Options" => (false, edits.HasFlag(StructureEdits.TableOptions) && ViewModel.EditableTableOptions.Count > 0, false, false),
            _ => (false, false, false, false),
        };

        StructureAdd.Visibility = canEdit && add ? Visibility.Visible : Visibility.Collapsed;
        StructureEdit.Visibility = canEdit && edit ? Visibility.Visible : Visibility.Collapsed;
        StructureTruncate.Visibility = canEdit && truncate ? Visibility.Visible : Visibility.Collapsed;
        StructureDrop.Visibility = canEdit && drop ? Visibility.Visible : Visibility.Collapsed;
        StructureCaption.Text = _structureSection switch
        {
            "Partitions" when ViewModel.Structure?.Partitioning is { } p => p.Subpartitioning is { } sub
                ? Strings.Format("Table/PartitionedBySubpartitioned", p, sub)
                : Strings.Format("Table/PartitionedBy", p),
            "Checks" when !edits.HasFlag(StructureEdits.CheckConstraints) && canEdit => Strings.Get("Table/ChecksNotEditable"),
            _ => string.Empty,
        };
        StructureCaption.Visibility = StructureCaption.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
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

    private void ShowStructureGrid()
    {
        StructureGrid.Source = _structureSection switch
        {
            "Indexes" => ViewModel.IndexesGrid,
            "ForeignKeys" => ViewModel.ForeignKeysGrid,
            "Checks" => ViewModel.ChecksGrid,
            "Triggers" => ViewModel.TriggersGrid,
            "Partitions" => ViewModel.PartitionsGrid,
            "Options" => ViewModel.OptionsGrid,
            _ => ViewModel.ColumnsGrid,
        };
        UpdateStructureCommands();
    }

    private void UpdateSelectionText()
    {
        var rows = RowsGrid.SelectedRows.Count;
        SelectionText.Text = rows > 1 ? Strings.Plural("Table/RowsSelected", rows) : string.Empty;
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
        menu.Items.Add(GridCommands.Item(Strings.Get("Table/FilterByValue"),"", async () => await ViewModel.FilterByValueAsync(e.Row, e.Column, exclude: false)));
        menu.Items.Add(GridCommands.Item(Strings.Get("Table/ExcludeValue"),"", async () => await ViewModel.FilterByValueAsync(e.Row, e.Column, exclude: true)));
        if (ForeignKeyFor(e.Column) is { } foreignKey)
        {
            menu.Items.Add(GridCommands.Item(Strings.Format("Table/OpenReferencedTable", foreignKey.ReferencedTable.Name),"", () =>
                ForeignKeyRequested?.Invoke(this, (foreignKey.ReferencedTable, foreignKey.ReferencedColumns[0], RowsGrid.Source?.GetValue(e.Row, e.Column)))));
        }

        menu.Items.Add(GridCommands.Item(Strings.Get("Table/InspectValue"),"", () => Inspect(e.Row, e.Column)));
        if (ViewModel.IsEditable)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(GridCommands.Item(Strings.Get("Table/EditCell"),"", () => RowsGrid.BeginEdit(), "Enter"));
            menu.Items.Add(GridCommands.Item(Strings.Get("Table/SetToNull"),"", RowsGrid.SetActiveCellNull));
            menu.Items.Add(GridCommands.Item(Strings.Get("Table/DuplicateRow"),"", () => ViewModel.DuplicateRow(e.Row)));
            menu.Items.Add(GridCommands.Item(Strings.Get("Table/DeleteRows"),"", () => ViewModel.ToggleDeleteRows(RowsGrid.SelectedRows), "Delete"));
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
        var file = await dialogs.PickOpenFileAsync(".csv", ".tsv", ".txt", ".json", ".ndjson", ".jsonl", ".sql", ".gz");
        if (file is null || ViewModel.Structure is not { } structure)
        {
            return;
        }

        var path = file.Path;
        var format = ImportFile.DetectFormat(path);
        if (format == ImportFileFormat.Sql)
        {
            // A dump names its own tables, so it runs as a script on the connection rather than into this table.
            if (await SqlImportDialog.RunAsync(ViewModel.Context, path))
            {
                await ViewModel.LoadAsync();
            }

            return;
        }

        var csvOptions = CsvImportOptions.Default with { Delimiter = ImportFile.DelimiterFor(path) };
        Task<ImportPreview> ReadPreview(CsvImportOptions options) => Task.Run(async () =>
        {
            await using var stream = ImportFile.Open(path);
            return await ImportPreview.ReadAsync(stream, format, options);
        });

        ImportPreview preview;
        try
        {
            preview = await ReadPreview(csvOptions);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or System.Text.Json.JsonException or UnauthorizedAccessException)
        {
            await dialogs.ShowErrorAsync(Strings.Get("Import/CannotReadFileTitle"), ex.Message);
            return;
        }

        // The grid's baseline knows the provider's CLR type of each column, which values are parsed into.
        var clrTypes = ViewModel.Buffer?.Baseline.Columns.ToDictionary(c => c.Name, c => c.ClrType, StringComparer.OrdinalIgnoreCase) ?? [];
        var targets = structure.Columns.Select(c => new ImportTargetColumn(c.Name, c.DataType, clrTypes.GetValueOrDefault(c.Name) ?? typeof(string), c.IsIdentity)).ToArray();
        var session = ViewModel.Context.Session;
        var ddl = session.Database as ISchemaDdlProvider;
        var table = ViewModel.Table.Name;
        var plan = await ImportMappingDialog.ShowAsync(
            dialogs, file.Name, preview, format, csvOptions, ReadPreview, table, targets,
            canCreateTable: ddl is not null && session.Dialect.IsSql && !session.Profile.IsReadOnly,
            type => ImportTypeMapper.SqlType(type, session.Profile.Engine, session.Database.ServerVersion),
            ddl?.CommonDataTypes ?? [],
            new Storage.Import.ImportMappingScope(session.Profile.Id, session.Database.CurrentDatabase, table.Schema, table.Name),
            new ImportMatchOptions(
                ImportMatchKey.Options(structure.Columns, structure.Indexes),
                session.Database is IImportRowMatcher && session.Dialect.IsSql,
                RowImporter.CanDeleteExistingRows(session.Database) && !session.Profile.IsReadOnly));
        if (plan is null)
        {
            return;
        }

        if (plan.Destination == ImportDestination.NewTable && !await CreateImportTableAsync(plan))
        {
            return;
        }

        ViewModel.IsBusy = true;
        ViewModel.StatusText = Strings.Get("Import/Importing");
        try
        {
            var progress = new Progress<long>(rows => ViewModel.StatusText = Strings.Plural("Import/ImportingRows", rows));
            var result = await Task.Run(async () =>
            {
                await using var stream = ImportFile.Open(path);
                var records = ImportFile.ReadRecordsAsync(stream, format, plan.CsvOptions, CancellationToken.None);
                return await RowImporter.ImportAsync(session.Database, plan.Table, records, plan.Builder, plan.Writing, progress, CancellationToken.None);
            });
            var imported = plan.Writing.Mode.MatchesExistingRows()
                ? Strings.Format("Import/ImportedMatching", plan.Table.Name, result.Matched, result.Updated, result.Inserted, result.Unmatched + result.Existing)
                : Strings.Plural("Import/ImportedRows", result.Imported, plan.Table.Name);
            ViewModel.Context.Notify(result.Skipped > 0 ? Strings.Format("Import/ImportedWithSkipped", imported, Strings.Plural("Import/RecordsSkipped", result.Skipped)) : imported);
            if (plan.Destination == ImportDestination.ExistingTable)
            {
                await ViewModel.LoadAsync();
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            // Batches before the failure are already saved, each in its own transaction, unless the import emptied the
            // table first, which ran in one transaction and rolled back whole.
            await dialogs.ShowErrorAsync(
                Strings.Get("Import/ImportStoppedTitle"),
                Strings.Format(plan.Writing.DeleteExistingRows ? "Import/ImportStoppedNothingChanged" : "Import/ImportStoppedRowsKept", ex.Message));
        }
        finally
        {
            ViewModel.IsBusy = false;
            ViewModel.StatusText = null;
        }
    }

    /// <summary>Creates the table an import writes to, after the user reviews its DDL, as every structure change here is reviewed.</summary>
    private async Task<bool> CreateImportTableAsync(ImportPlan plan)
    {
        var context = ViewModel.Context;
        if (context.Session.Database is not ISchemaDdlProvider ddl)
        {
            return false;
        }

        var statements = ddl.BuildDdl(plan.Table, new CreateTable(plan.Table, plan.NewTableColumns));
        if (statements.Count == 0)
        {
            await context.Dialogs.ShowErrorAsync(Strings.Get("Table/NotSupportedTitle"), Strings.Get("Import/CannotCreateTable"));
            return false;
        }

        if (!await context.Dialogs.ReviewSqlAsync(Strings.Get("Import/CreateTableReviewTitle"), statements, Strings.Get("Import/CreateAndImport")))
        {
            return false;
        }

        await using var channel = await context.Session.Database.OpenChannelAsync(CancellationToken.None);
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(), CancellationToken.None))
        {
            context.History.Record(context.Session.Profile, context.Session.Database.CurrentDatabase, result, Core.Sql.StatementKind.Ddl, "import");
            if (!result.Succeeded)
            {
                await context.Dialogs.ShowErrorAsync(Strings.Get("Import/CreateTableFailedTitle"), result.Error!);
                return false;
            }
        }

        context.NotifySchemaChanged();
        return true;
    }
    private void OnCopyDefinition(object sender, RoutedEventArgs e) => GridCommands.SetClipboard(ViewModel.Definition);

    private void OnOpenDefinition(object sender, RoutedEventArgs e) => OpenSqlRequested?.Invoke(this, ViewModel.Definition);

    private async void OnStructureAdd(object sender, RoutedEventArgs e)
    {
        var change = _structureSection switch
        {
            "Indexes" => await IndexDialogAsync(),
            "ForeignKeys" => await ForeignKeyDialogAsync(),
            "Checks" => await CheckDialogAsync(null),
            "Partitions" => await PartitionDialogAsync(),
            "Columns" => await ColumnDialogAsync(null),
            _ => null,
        };
        if (change is not null)
        {
            await ViewModel.ApplySchemaChangeAsync(change);
        }
    }

    private async void OnStructureEdit(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Structure is not { } structure)
        {
            return;
        }

        if (_structureSection == "Options")
        {
            if (await OptionsDialogAsync(structure) is { } options)
            {
                await ViewModel.ApplySchemaChangeAsync(options);
            }

            return;
        }

        if (_structureSection == "Checks")
        {
            if (StructureGrid.ActiveCell is { } row && row.Row < structure.CheckConstraints.Count
                && await CheckDialogAsync(structure.CheckConstraints[row.Row].ToDefinition()) is { } check)
            {
                await ViewModel.ApplySchemaChangeAsync(check);
            }

            return;
        }

        if (_structureSection != "Columns" || StructureGrid.ActiveCell is not { } cell || cell.Row >= structure.Columns.Count)
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
            "Checks" when cell.Row < structure.CheckConstraints.Count => new DropCheckConstraint(structure.CheckConstraints[cell.Row].Name),
            "Partitions" when structure.Partitioning is { } partitioning && cell.Row < partitioning.Partitions.Count => new DropPartition(partitioning.Partitions[cell.Row]),
            _ => null,
        };
        if (change is not null)
        {
            await ViewModel.ApplySchemaChangeAsync(change);
        }
    }

    private async void OnStructureTruncate(object sender, RoutedEventArgs e)
    {
        if (_structureSection == "Partitions" && ViewModel.Structure?.Partitioning is { } partitioning
            && StructureGrid.ActiveCell is { } cell && cell.Row < partitioning.Partitions.Count)
        {
            await ViewModel.ApplySchemaChangeAsync(new TruncatePartition(partitioning.Partitions[cell.Row]));
        }
    }

    /// <summary>The name and expression of a check; editing one that exists produces the change from it to the new one.</summary>
    private async Task<SchemaChange?> CheckDialogAsync(CheckConstraintDefinition? existing)
    {
        var name = new TextBox { Header = Strings.Get("Common/Name"), Text = existing?.Name ?? $"ck_{ViewModel.Table.Name.Name}_" };
        var expression = new TextBox
        {
            Header = Strings.Get("Table/CheckExpressionHeader"),
            Text = existing?.Expression ?? string.Empty,
            PlaceholderText = Strings.Get("Table/CheckExpressionPlaceholder"),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 96,
            FontFamily = (Microsoft.UI.Xaml.Media.FontFamily)Application.Current.Resources["CodeFontFamily"],
        };
        var panel = new StackPanel { Spacing = 12, MinWidth = 420 };
        panel.Children.Add(name);
        panel.Children.Add(expression);
        panel.Children.Add(new TextBlock
        {
            Style = (Style)Application.Current.Resources["StatusTextStyle"],
            TextWrapping = TextWrapping.Wrap,
            Text = existing is null
                ? Strings.Get("Table/AddCheckNote")
                : Strings.Get("Table/EditCheckNote"),
        });

        var dialogs = ViewModel.Context.Dialogs;
        if (await dialogs.ShowAsync(dialogs.Create(
                existing is null ? Strings.Get("Table/AddCheckTitle") : Strings.Get("Table/EditCheckTitle"),
                panel,
                existing is null ? Strings.Get("Common/Add") : Strings.Get("Common/Save"),
                Strings.Get("Common/Cancel")))
            != ContentDialogResult.Primary)
        {
            return null;
        }

        var check = new CheckConstraintDefinition(name.Text.Trim(), expression.Text.Trim());
        if (!check.IsComplete)
        {
            await dialogs.ShowErrorAsync(Strings.Get("Table/CheckNotSavedTitle"), Strings.Get("Table/CheckIncomplete"));
            return null;
        }

        if (existing is null)
        {
            return new AddCheckConstraint(check);
        }

        return check == existing ? null : new AlterCheckConstraint(existing, check);
    }

    /// <summary>
    /// A new partition and its bound. The bound starts as the last partition's, which is already in the engine's own
    /// syntax, so the user edits a value rather than recalling how the engine spells a range.
    /// </summary>
    private async Task<SchemaChange?> PartitionDialogAsync()
    {
        if (ViewModel.Structure?.Partitioning is not { } partitioning)
        {
            return null;
        }

        var last = partitioning.Partitions.LastOrDefault(p => !p.IsSubpartition && !string.IsNullOrEmpty(p.Bound) && !string.Equals(p.Bound, "DEFAULT", StringComparison.OrdinalIgnoreCase));
        var name = new TextBox { Header = Strings.Get("Common/Name"), Text = $"{ViewModel.Table.Name.Name}_" };
        var bound = new TextBox
        {
            Header = Strings.Get("Table/PartitionBoundHeader"),
            Text = last?.Bound ?? string.Empty,
            PlaceholderText = Strings.Get("Table/PartitionBoundPlaceholder"),
            FontFamily = (Microsoft.UI.Xaml.Media.FontFamily)Application.Current.Resources["CodeFontFamily"],
        };
        var panel = new StackPanel { Spacing = 12, MinWidth = 460 };
        panel.Children.Add(new TextBlock { Text = Strings.Format("Table/PartitionedBy", partitioning), TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(name);
        panel.Children.Add(bound);
        panel.Children.Add(new TextBlock
        {
            Style = (Style)Application.Current.Resources["StatusTextStyle"],
            TextWrapping = TextWrapping.Wrap,
            Text = Strings.Get("Table/PartitionBoundNote"),
        });

        var dialogs = ViewModel.Context.Dialogs;
        if (await dialogs.ShowAsync(dialogs.Create(Strings.Get("Table/AddPartitionTitle"), panel, Strings.Get("Common/Add"), Strings.Get("Common/Cancel"))) != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(name.Text))
        {
            return null;
        }

        return new AddPartition(new PartitionDefinition(name.Text.Trim(), bound.Text.Trim()));
    }

    /// <summary>One field per option the engine can change, filled with the current values; only the ones edited become DDL.</summary>
    private async Task<SchemaChange?> OptionsDialogAsync(TableStructure structure)
    {
        var specs = ViewModel.EditableTableOptions;
        if (specs.Count == 0)
        {
            return null;
        }

        var fields = new List<(string Name, Func<string?> Read)>(specs.Count);
        var panel = new StackPanel { Spacing = 12, MinWidth = 420 };
        foreach (var spec in specs)
        {
            var current = structure.Option(spec.Name);
            if (spec.Kind == TableOptionKind.Choice)
            {
                var box = new ComboBox
                {
                    Header = spec.Name,
                    IsEditable = true,
                    ItemsSource = spec.ChoiceList.ToList(),
                    Text = current ?? string.Empty,
                    PlaceholderText = spec.Placeholder ?? string.Empty,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                };
                panel.Children.Add(box);
                fields.Add((spec.Name, () => string.IsNullOrWhiteSpace(box.Text) ? box.SelectedItem as string : box.Text));
            }
            else
            {
                var box = new TextBox { Header = spec.Name, Text = current ?? string.Empty, PlaceholderText = spec.Placeholder ?? string.Empty };
                if (spec.Kind == TableOptionKind.Number)
                {
                    box.InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Number) } };
                }

                panel.Children.Add(box);
                fields.Add((spec.Name, () => box.Text));
            }
        }

        var dialogs = ViewModel.Context.Dialogs;
        var content = new ScrollViewer { Content = panel, MaxHeight = 520 };
        if (await dialogs.ShowAsync(dialogs.Create(Strings.Get("Table/TableOptionsTitle"), content, Strings.Get("Common/Save"), Strings.Get("Common/Cancel"))) != ContentDialogResult.Primary)
        {
            return null;
        }

        var edited = fields.ToDictionary(f => f.Name, f => f.Read(), StringComparer.OrdinalIgnoreCase);
        var changes = TableOptionChange.Diff(structure.Options, edited);
        return changes.Count == 0 ? null : new SetTableOptions(changes);
    }

    private async Task<SchemaChange?> ColumnDialogAsync(ColumnDefinition? existing)
    {
        var types = (ViewModel.Context.Session.Database as ISchemaDdlProvider)?.CommonDataTypes ?? [];
        var name = new TextBox { Header = Strings.Get("Common/Name"), Text = existing?.Name ?? string.Empty };
        var type = new ComboBox { Header = Strings.Get("Common/Type"), IsEditable = true, ItemsSource = types.ToList(), Text = existing?.DataType ?? (types.Count > 0 ? types[0] : "text"), HorizontalAlignment = HorizontalAlignment.Stretch };
        var nullable = new CheckBox { Content = Strings.Get("Table/AllowsNull"), IsChecked = existing?.IsNullable ?? true };
        var defaultValue = new TextBox { Header = Strings.Get("Table/DefaultExpressionHeader"), Text = existing?.DefaultExpression ?? string.Empty, PlaceholderText = Strings.Get("Table/DefaultExpressionPlaceholder") };
        var comment = new TextBox { Header = Strings.Get("Table/CommentHeader"), Text = existing?.Comment ?? string.Empty };
        var panel = new StackPanel { Spacing = 12, MinWidth = 380 };
        panel.Children.Add(name);
        panel.Children.Add(type);
        panel.Children.Add(nullable);
        panel.Children.Add(defaultValue);
        panel.Children.Add(comment);
        var dialogs = ViewModel.Context.Dialogs;
        if (await dialogs.ShowAsync(dialogs.Create(
                existing is null ? Strings.Get("Table/AddColumnTitle") : Strings.Get("Table/EditColumnTitle"),
                panel,
                existing is null ? Strings.Get("Common/Add") : Strings.Get("Common/Save"),
                Strings.Get("Common/Cancel"))) != ContentDialogResult.Primary
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

        var name = new TextBox { Header = Strings.Get("Common/Name"), Text = $"idx_{ViewModel.Table.Name.Name}_" };
        var columns = new ListView { SelectionMode = ListViewSelectionMode.Multiple, ItemsSource = structure.Columns.Select(c => c.Name).ToList(), MaxHeight = 240, Header = Strings.Get("Table/IndexColumnsHeader") };
        var unique = new CheckBox { Content = Strings.Get("Table/IndexUnique") };
        var panel = new StackPanel { Spacing = 12, MinWidth = 380 };
        panel.Children.Add(name);
        panel.Children.Add(columns);
        panel.Children.Add(unique);
        var dialogs = ViewModel.Context.Dialogs;
        if (await dialogs.ShowAsync(dialogs.Create(Strings.Get("Table/AddIndexTitle"), panel, Strings.Get("Common/Add"), Strings.Get("Common/Cancel"))) != ContentDialogResult.Primary || columns.SelectedItems.Count == 0)
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
        var name = new TextBox { Header = Strings.Get("Common/Name"), Text = $"fk_{ViewModel.Table.Name.Name}_" };
        var column = new ComboBox { Header = Strings.Get("Table/ForeignKeyColumnHeader"), ItemsSource = structure.Columns.Select(c => c.Name).ToList(), HorizontalAlignment = HorizontalAlignment.Stretch };
        var target = new ComboBox { Header = Strings.Get("Table/ForeignKeyTargetTableHeader"), ItemsSource = tables.Select(t => t.ToString()).ToList(), HorizontalAlignment = HorizontalAlignment.Stretch };
        var targetColumn = new ComboBox { Header = Strings.Get("Table/ForeignKeyTargetColumnHeader"), HorizontalAlignment = HorizontalAlignment.Stretch };
        target.SelectionChanged += async (_, _) =>
        {
            if (target.SelectedIndex >= 0)
            {
                var referenced = await session.GetStructureAsync(tables[target.SelectedIndex], CancellationToken.None);
                targetColumn.ItemsSource = referenced.Columns.Select(c => c.Name).ToList();
                targetColumn.SelectedItem = referenced.PrimaryKey.Count > 0 ? referenced.PrimaryKey[0] : null;
            }
        };
        var onDelete = new ComboBox { Header = Strings.Get("Table/ForeignKeyOnDeleteHeader"), ItemsSource = new[] { "NO ACTION", "CASCADE", "SET NULL", "RESTRICT" }, SelectedIndex = 0 };
        var panel = new StackPanel { Spacing = 12, MinWidth = 380 };
        panel.Children.Add(name);
        panel.Children.Add(column);
        panel.Children.Add(target);
        panel.Children.Add(targetColumn);
        panel.Children.Add(onDelete);
        var dialogs = ViewModel.Context.Dialogs;
        if (await dialogs.ShowAsync(dialogs.Create(Strings.Get("Table/AddForeignKeyTitle"), panel, Strings.Get("Common/Add"), Strings.Get("Common/Cancel"))) != ContentDialogResult.Primary
            || column.SelectedItem is not string from || target.SelectedIndex < 0 || targetColumn.SelectedItem is not string to)
        {
            return null;
        }

        return new AddForeignKey(new ForeignKeyDefinition(name.Text.Trim(), [from], tables[target.SelectedIndex], [to], onDelete.SelectedItem as string));
    }
}
